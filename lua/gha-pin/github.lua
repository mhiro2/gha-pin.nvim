local system = require("gha-pin.system")
local util = require("gha-pin.util")

local M = {}

---@class GhaPinGithubConfig
---@field api_base_url string
---@field prefer_gh boolean
---@field token_env string

---@class GhaPinGithubResult
---@field latest_tag string|nil Latest tag name (e.g., "v1.2.3")
---@field latest_sha string|nil Full 40-char commit SHA, or "" if within cooldown period (not eligible yet)
---@field source string|nil Source: "release", "tags", or "cache"
---@field published_at string|nil ISO 8601 timestamp from tagger.date (annotated) or commit date (lightweight)

---@param s string
---@return boolean
local function is_hex40(s)
  return type(s) == "string"
    and s:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

---@param base_url string
---@return boolean
local function is_github_com(base_url)
  return base_url == "https://api.github.com" or base_url == "https://api.github.com/"
end

---@param body string
---@return any|nil
---@return string|nil
local function decode_json(body)
  local ok, decoded = pcall(function()
    if vim.json and vim.json.decode then
      return vim.json.decode(body)
    end
    return vim.fn.json_decode(body)
  end)
  if not ok then
    return nil, "Failed to decode JSON"
  end
  return decoded, nil
end

---@param res any
---@return string
local function best_error_from_res(res)
  local parts = {}
  if res.stderr and res.stderr ~= "" then
    table.insert(parts, res.stderr)
  end
  if res.stdout and res.stdout ~= "" then
    table.insert(parts, res.stdout)
  end
  if #parts == 0 then
    return "Request failed"
  end
  return util.trim(table.concat(parts, "\n"))
end

---@param err string
---@return boolean
local function is_not_found(err)
  if not err or err == "" then
    return false
  end
  return err:find("404", 1, true) ~= nil or err:find("Not Found", 1, true) ~= nil
end

---@param cfg GhaPinGithubConfig
---@param endpoint string e.g. "repos/owner/repo/releas..."
---@param cb fun(data: any|nil, err: string|nil)
local function request_json(cfg, endpoint, cb)
  local prefer_gh = cfg.prefer_gh and is_github_com(cfg.api_base_url) and vim.fn.executable("gh") == 1
  if prefer_gh then
    system.run({ "gh", "api", endpoint }, function(res)
      if res.code ~= 0 then
        cb(nil, best_error_from_res(res))
        return
      end
      local data, err = decode_json(res.stdout)
      cb(data, err)
    end)
    return
  end

  if vim.fn.executable("curl") ~= 1 then
    cb(nil, "Neither `gh` nor `curl` is available")
    return
  end

  local url = cfg.api_base_url:gsub("/$", "") .. "/" .. endpoint
  local cmd = { "curl", "-sS", "-f", "-H", "Accept: application/vnd.github+json" }
  local token = vim.env[cfg.token_env]
  if token and token ~= "" then
    table.insert(cmd, "-H")
    table.insert(cmd, "Authorization: Bearer " .. token)
  end
  table.insert(cmd, url)

  system.run(cmd, function(res)
    if res.code ~= 0 then
      cb(nil, best_error_from_res(res))
      return
    end
    local data, err = decode_json(res.stdout)
    cb(data, err)
  end)
end

---@param cfg GhaPinGithubConfig
---@param owner string
---@param repo string
---@param cb fun(tag: string|nil, err: string|nil)
local function get_latest_release_tag(cfg, owner, repo, cb)
  request_json(cfg, ("repos/%s/%s/releases/latest"):format(owner, repo), function(data, err)
    if err then
      cb(nil, err)
      return
    end
    if type(data) ~= "table" then
      cb(nil, "Unexpected response for releases/latest")
      return
    end
    local tag = data.tag_name
    if type(tag) ~= "string" or tag == "" then
      cb(nil, "Latest release has no tag_name")
      return
    end
    cb(tag, nil)
  end)
end

---@param cfg GhaPinGithubConfig
---@param owner string
---@param repo string
---@param tag_sha string
---@param cb fun(timestamp: string|nil, err: string|nil)
local function get_tag_timestamp(cfg, owner, repo, tag_sha, cb)
  request_json(cfg, ("repos/%s/%s/git/tags/%s"):format(owner, repo, tag_sha), function(data, err)
    if err then
      cb(nil, err)
      return
    end
    if type(data) ~= "table" then
      cb(nil, "Unexpected response for git/tags")
      return
    end
    -- Annotated tags have 'tagger.date', lightweight tags don't
    if type(data.tagger) == "table" and type(data.tagger.date) == "string" then
      cb(data.tagger.date, nil)
    else
      -- Missing tagger info - return nil so caller can decide fallback
      cb(nil, nil)
    end
  end)
end

---@param cfg GhaPinGithubConfig
---@param owner string
---@param repo string
---@param commit_sha string
---@param cb fun(timestamp: string|nil, err: string|nil)
local function get_commit_timestamp(cfg, owner, repo, commit_sha, cb)
  request_json(cfg, ("repos/%s/%s/commits/%s"):format(owner, repo, commit_sha), function(data, err)
    if err then
      cb(nil, err)
      return
    end
    if type(data) ~= "table" or type(data.commit) ~= "table" then
      cb(nil, "Unexpected response for commits")
      return
    end
    local commit = data.commit
    local committer = type(commit.committer) == "table" and commit.committer or nil
    local author = type(commit.author) == "table" and commit.author or nil
    if committer and type(committer.date) == "string" then
      cb(committer.date, nil)
      return
    end
    if author and type(author.date) == "string" then
      cb(author.date, nil)
      return
    end
    cb(nil, nil)
  end)
end

---@param cfg GhaPinGithubConfig
---@param owner string
---@param repo string
---@param tag string
---@param cb fun(commit_sha: string|nil, tag_sha: string|nil, err: string|nil)
local function resolve_tag_to_commit_sha(cfg, owner, repo, tag, cb)
  local tag_enc = util.uri_encode_path_segment(tag)
  request_json(cfg, ("repos/%s/%s/git/ref/tags/%s"):format(owner, repo, tag_enc), function(data, err)
    if err then
      cb(nil, nil, err)
      return
    end
    if type(data) ~= "table" or type(data.object) ~= "table" then
      cb(nil, nil, "Unexpected response for git ref tag")
      return
    end

    local obj = data.object
    local obj_type = obj.type
    local sha = obj.sha
    if type(obj_type) ~= "string" or type(sha) ~= "string" then
      cb(nil, nil, "Tag ref missing object.type/object.sha")
      return
    end

    if obj_type == "commit" then
      if not is_hex40(sha) then
        cb(nil, nil, "Invalid commit SHA in tag ref")
        return
      end
      -- Lightweight tag: commit SHA is the tag SHA, no tagger.date
      cb(sha, nil, nil)
      return
    end

    -- annotated tag: resolve to commit via /git/tags/{sha}
    if obj_type == "tag" then
      local function step(tag_sha, depth)
        if depth > 3 then
          cb(nil, nil, "Tag resolution exceeded max depth")
          return
        end
        request_json(cfg, ("repos/%s/%s/git/tags/%s"):format(owner, repo, tag_sha), function(tag_obj, err2)
          if err2 then
            cb(nil, nil, err2)
            return
          end
          if type(tag_obj) ~= "table" or type(tag_obj.object) ~= "table" then
            cb(nil, nil, "Unexpected response for git tag object")
            return
          end
          local inner = tag_obj.object
          local t = inner.type
          local s = inner.sha
          if type(t) ~= "string" or type(s) ~= "string" then
            cb(nil, nil, "Tag object missing inner object")
            return
          end
          if t == "commit" then
            if not is_hex40(s) then
              cb(nil, nil, "Invalid commit SHA in tag object")
              return
            end
            -- Return commit SHA and the first tag SHA (for timestamp lookup)
            cb(s, sha, nil)
            return
          end
          if t == "tag" then
            step(s, depth + 1)
            return
          end
          cb(nil, nil, "Unsupported tag object type: " .. t)
        end)
      end

      step(sha, 1)
      return
    end

    cb(nil, nil, "Unsupported ref object.type: " .. obj_type)
  end)
end

---@param cfg GhaPinGithubConfig
---@param owner string
---@param repo string
---@param cb fun(tag: string|nil, sha: string|nil, err: string|nil)
local function fallback_latest_tag(cfg, owner, repo, cb)
  request_json(cfg, ("repos/%s/%s/tags?per_page=1"):format(owner, repo), function(data, err)
    if err then
      cb(nil, nil, err)
      return
    end
    if type(data) ~= "table" or type(data[1]) ~= "table" then
      cb(nil, nil, "No tags found")
      return
    end
    local first = data[1]
    local tag = first.name
    local commit = type(first.commit) == "table" and first.commit or nil
    local sha = commit and commit.sha or nil
    if type(tag) ~= "string" or tag == "" then
      cb(nil, nil, "Tag list item missing name")
      return
    end
    if type(sha) ~= "string" or not is_hex40(sha) then
      cb(nil, nil, "Tag list item missing commit sha")
      return
    end
    cb(tag, sha, nil)
  end)
end

---@param cfg GhaPinGithubConfig
---@param minimum_age_seconds integer
---@param owner string
---@param repo string
---@param cb fun(result: GhaPinGithubResult|nil, err: string|nil)
function M.resolve_latest(cfg, minimum_age_seconds, owner, repo, cb)
  get_latest_release_tag(cfg, owner, repo, function(tag, err)
    if err then
      if is_not_found(err) then
        -- Tags fallback: no cooldown per user preference
        fallback_latest_tag(cfg, owner, repo, function(tag2, sha2, err2)
          if err2 then
            cb(nil, err2)
            return
          end
          cb({ latest_tag = tag2, latest_sha = sha2, source = "tags", published_at = nil }, nil)
        end)
        return
      end
      cb(nil, err)
      return
    end

    resolve_tag_to_commit_sha(cfg, owner, repo, tag, function(sha, tag_sha, err2)
      if err2 then
        -- if release exists but tag ref can't be resolved, try tags list as last resort
        fallback_latest_tag(cfg, owner, repo, function(tag2, sha2, err3)
          if err3 then
            cb(nil, err2)
            return
          end
          cb({ latest_tag = tag2, latest_sha = sha2, source = "tags", published_at = nil }, nil)
        end)
        return
      end

      local function apply_cooldown(timestamp)
        if minimum_age_seconds > 0 and timestamp then
          local age = util.timestamp_age_seconds(timestamp)
          if age < minimum_age_seconds then
            -- Within cooldown period - return empty sha to indicate not eligible
            cb({ latest_tag = tag, latest_sha = "", source = "release", published_at = timestamp }, nil)
            return
          end
        end
        cb({ latest_tag = tag, latest_sha = sha, source = "release", published_at = timestamp }, nil)
      end

      if minimum_age_seconds > 0 then
        if tag_sha then
          get_tag_timestamp(cfg, owner, repo, tag_sha, function(timestamp, _ts_err)
            if timestamp then
              apply_cooldown(timestamp)
              return
            end
            -- Fallback to commit timestamp when tagger.date is unavailable
            get_commit_timestamp(cfg, owner, repo, sha, function(commit_ts, _commit_err)
              apply_cooldown(commit_ts)
            end)
          end)
          return
        end

        -- Lightweight tag: use commit timestamp for cooldown
        get_commit_timestamp(cfg, owner, repo, sha, function(commit_ts, _commit_err)
          apply_cooldown(commit_ts)
        end)
        return
      end

      -- No cooldown requested
      cb({ latest_tag = tag, latest_sha = sha, source = "release", published_at = nil }, nil)
    end)
  end)
end

return M
