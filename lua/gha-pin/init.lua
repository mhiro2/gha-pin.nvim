local cache = require("gha-pin.cache")
local diagnostic = require("gha-pin.diagnostic")
local fix = require("gha-pin.fix")
local github = require("gha-pin.github")
local parser = require("gha-pin.parser")
local ui = require("gha-pin.ui")
local util = require("gha-pin.util")

---@class GhaPin
---@field setup fun(cfg: GhaPinConfig|nil)
---@field check fun(bufnr: integer)
---@field fix fun(bufnr: integer, line1: integer, line2: integer)
---@field explain fun(bufnr: integer)
---@field cache_clear fun()
local M = {}

---@class GhaPinConfig
---@field enabled boolean
---@field virtual_text boolean
---@field ttl_seconds integer
---@field minimum_release_age_seconds integer
---@field github GhaPinGithubConfig
---@field auto_check { enabled: boolean, debounce_ms: integer }

local defaults = {
  enabled = true,
  virtual_text = true,
  ttl_seconds = 6 * 60 * 60,
  minimum_release_age_seconds = 0,
  github = {
    api_base_url = "https://api.github.com",
    prefer_gh = true,
    token_env = "GITHUB_TOKEN",
  },
  auto_check = {
    enabled = false,
    debounce_ms = 700,
  },
}

local state = {
  did_setup = false,
  ---@type GhaPinConfig
  cfg = nil,
  ---@type GhaPinCache
  cache = nil,
  ---@type table<integer, {gen: integer, refs: GhaPinUsesRef[]|nil, repo: table<string, GhaPinGithubResult>|nil, err: table<string, string>|nil}>
  by_buf = {},
  ---@type table<string, {cbs: fun(res: GhaPinGithubResult|nil, err: string|nil)[]}>
  inflight = {},
  timers = {},
}

---@param base any
---@param ext any
---@return any
local function deep_merge(base, ext)
  return vim.tbl_deep_extend("force", base, ext or {})
end

---@param v any
---@param fallback boolean
---@return boolean
local function as_bool(v, fallback)
  if type(v) == "boolean" then
    return v
  end
  return fallback
end

---@param v any
---@param fallback integer
---@return integer
local function as_nonneg_int(v, fallback)
  if type(v) == "number" and v >= 0 then
    return math.floor(v)
  end
  return fallback
end

---@param seconds integer
---@return string
local function format_duration(seconds)
  local s = math.max(0, math.floor(seconds or 0))
  local days = math.floor(s / 86400)
  s = s % 86400
  local hours = math.floor(s / 3600)
  s = s % 3600
  local mins = math.floor(s / 60)

  local parts = {}
  if days > 0 then
    table.insert(parts, days .. "d")
  end
  if hours > 0 and #parts < 2 then
    table.insert(parts, hours .. "h")
  end
  if mins > 0 and #parts < 2 then
    table.insert(parts, mins .. "m")
  end
  if #parts == 0 then
    table.insert(parts, "0m")
  end
  return table.concat(parts, " ")
end

---@param published_at string|nil
---@param minimum_age_seconds integer
---@return string
local function cooldown_suffix(published_at, minimum_age_seconds)
  if not published_at or minimum_age_seconds <= 0 then
    return " (cooldown)"
  end
  local age = util.timestamp_age_seconds(published_at)
  local remaining = minimum_age_seconds - age
  if remaining <= 0 then
    return " (cooldown)"
  end
  return (" (cooldown %s left)"):format(format_duration(remaining))
end

---@param v any
---@param fallback string
---@return string
local function as_string(v, fallback)
  if type(v) == "string" and v ~= "" then
    return v
  end
  return fallback
end

---@param owner_or_repo string
---@return boolean
local function is_valid_owner_or_repo(owner_or_repo)
  -- GitHub owner/repo names can only contain: alphanumeric, hyphen, underscore, dot
  -- Reject special characters that could be used for injection attacks
  return type(owner_or_repo) == "string"
    and owner_or_repo:match("^[a-zA-Z0-9._-]+$") ~= nil
    and owner_or_repo:match("%.%.") == nil -- Reject ".." (path traversal attempt)
end

---@param url string
---@param fallback string
---@return string
local function as_https_url(url, fallback)
  local validated = as_string(url, fallback)
  -- Ensure URL starts with https:// to prevent insecure HTTP usage
  if validated:match("^https://") then
    return validated
  end
  util.notify(("api_base_url must use HTTPS, falling back to %s"):format(fallback), vim.log.levels.WARN)
  return fallback
end

---@param user_cfg any
---@return table
local function normalize_user_cfg(user_cfg)
  if user_cfg == nil then
    return {}
  end
  if type(user_cfg) ~= "table" then
    util.notify("setup(): cfg must be a table; falling back to defaults", vim.log.levels.WARN)
    return {}
  end
  return user_cfg
end

---@param cfg any
---@return GhaPinConfig
local function validate_cfg(cfg)
  cfg.enabled = as_bool(cfg.enabled, defaults.enabled)
  cfg.virtual_text = as_bool(cfg.virtual_text, defaults.virtual_text)
  cfg.ttl_seconds = as_nonneg_int(cfg.ttl_seconds, defaults.ttl_seconds)
  cfg.minimum_release_age_seconds = as_nonneg_int(cfg.minimum_release_age_seconds, defaults.minimum_release_age_seconds)

  if type(cfg.github) ~= "table" then
    cfg.github = vim.deepcopy(defaults.github)
  end
  cfg.github.api_base_url = as_https_url(cfg.github.api_base_url, defaults.github.api_base_url)
  cfg.github.prefer_gh = as_bool(cfg.github.prefer_gh, defaults.github.prefer_gh)
  cfg.github.token_env = as_string(cfg.github.token_env, defaults.github.token_env)

  if type(cfg.auto_check) ~= "table" then
    cfg.auto_check = vim.deepcopy(defaults.auto_check)
  end
  cfg.auto_check.enabled = as_bool(cfg.auto_check.enabled, defaults.auto_check.enabled)
  cfg.auto_check.debounce_ms = as_nonneg_int(cfg.auto_check.debounce_ms, defaults.auto_check.debounce_ms)

  return cfg
end

local function ensure_setup()
  if state.did_setup then
    return
  end
  M.setup()
end

---@param path string|nil
---@return boolean
local function is_workflow_file(path)
  if not path or path == "" then
    return false
  end
  if path:find("/.github/workflows/", 1, true) ~= nil and (path:match("%.ya?ml$") ~= nil) then
    return true
  end
  -- Composite action metadata under .github/actions/**/action.yml|yaml
  if path:match("/%.github/actions/.+/action%.ya?ml$") ~= nil then
    return true
  end
  return false
end

-- internal: expose for tests
---@param path string|nil
---@return boolean
function M._is_target_file(path)
  return is_workflow_file(path)
end

---@param key string
---@param owner string
---@param repo string
---@param cb fun(res: GhaPinGithubResult|nil, err: string|nil)
local function resolve_repo(key, owner, repo, cb)
  -- Validate owner/repo to prevent command injection
  if not is_valid_owner_or_repo(owner) then
    cb(nil, ("Invalid owner name: %s"):format(owner))
    return
  end
  if not is_valid_owner_or_repo(repo) then
    cb(nil, ("Invalid repo name: %s"):format(repo))
    return
  end
  local entry = cache.get_if_fresh(state.cache, key, state.cfg.ttl_seconds)
  if entry and entry.latest_sha and entry.latest_sha ~= "" then
    -- Check cooldown for cached releases
    if state.cfg.minimum_release_age_seconds > 0 and entry.published_at then
      local age = util.timestamp_age_seconds(entry.published_at)
      if age < state.cfg.minimum_release_age_seconds then
        -- Within cooldown period - treat as not eligible yet
        cb({ latest_tag = entry.latest_tag, latest_sha = "", source = "cache", published_at = entry.published_at }, nil)
        return
      end
    end
    cb({
      latest_tag = entry.latest_tag,
      latest_sha = entry.latest_sha,
      source = "cache",
      published_at = entry.published_at,
    }, nil)
    return
  end

  if state.inflight[key] then
    table.insert(state.inflight[key].cbs, cb)
    return
  end

  state.inflight[key] = { cbs = { cb } }
  github.resolve_latest(state.cfg.github, state.cfg.minimum_release_age_seconds, owner, repo, function(res, err)
    -- Store result including published_at (even if latest_sha is empty due to cooldown)
    if res then
      cache.put(state.cache, key, res.latest_tag, res.latest_sha, res.published_at)
      cache.save(state.cache)
    end

    local cbs = state.inflight[key] and state.inflight[key].cbs or {}
    state.inflight[key] = nil
    for _, f in ipairs(cbs) do
      f(res, err)
    end
  end)
end

---@param refs GhaPinUsesRef[]
---@param cb fun(repo_result: table<string, GhaPinGithubResult>, repo_err: table<string, string>)
local function resolve_for_refs(refs, cb)
  ---@type table<string, {owner: string, repo: string}>
  local uniq = {}
  for _, r in ipairs(refs) do
    local key = cache.key(state.cfg.github.api_base_url, r.owner, r.repo)
    uniq[key] = { owner = r.owner, repo = r.repo }
  end

  local keys = vim.tbl_keys(uniq)
  ---@type table<string, GhaPinGithubResult>
  local repo_result = {}
  ---@type table<string, string>
  local repo_err = {}
  if #keys == 0 then
    cb(repo_result, repo_err)
    return
  end

  local pending = #keys
  for _, key in ipairs(keys) do
    local o = uniq[key]
    resolve_repo(key, o.owner, o.repo, function(res, err)
      if res then
        repo_result[key] = res
      end
      if err then
        repo_err[key] = err
      end
      pending = pending - 1
      if pending == 0 then
        cb(repo_result, repo_err)
      end
    end)
  end
end

---@param bufnr integer
---@param refs GhaPinUsesRef[]
---@param repo_result table<string, GhaPinGithubResult>
---@param repo_err table<string, string>
local function render(bufnr, refs, repo_result, repo_err)
  ---@type GhaPinOutdatedDiag[]
  local outdated = {}
  local virt_by_lnum = {}

  for _, r in ipairs(refs) do
    local key = cache.key(state.cfg.github.api_base_url, r.owner, r.repo)
    local latest = repo_result[key]
    local err = repo_err[key]

    if latest and latest.latest_sha == "" then
      if not virt_by_lnum[r.lnum] then
        local text = ""
        if latest.latest_tag then
          text = ("# Latest: %s%s"):format(
            latest.latest_tag,
            cooldown_suffix(latest.published_at, state.cfg.minimum_release_age_seconds)
          )
        else
          text = "# Latest: (cooldown)"
        end
        virt_by_lnum[r.lnum] = text
      end
    elseif latest and latest.latest_sha and latest.latest_sha ~= "" then
      -- SHA mismatch diagnostic
      if r.sha ~= latest.latest_sha then
        table.insert(outdated, {
          lnum = r.lnum,
          col_start = r.col_start,
          col_end = r.col_end,
          latest_tag = latest.latest_tag,
          latest_sha = latest.latest_sha,
          kind = "sha",
        })
      end

      -- Version comment mismatch diagnostic (only if line has a "# v..." comment)
      if latest.latest_tag and r.raw then
        local want_version = tostring(latest.latest_tag):match("^v(.+)$") or tostring(latest.latest_tag)
        local after_token = r.raw:sub(r.col_end + 1)
        local s1, e1 = after_token:find("#%s*v%s*[^%s]+")
        if s1 and e1 then
          local have_version = after_token:sub(s1, e1):match("#%s*v%s*([^%s]+)")
          if have_version and have_version ~= want_version then
            local line_len = #r.raw
            local start0 = r.col_end + s1 - 1
            local end0 = math.min(r.col_end + e1, line_len)
            table.insert(outdated, {
              lnum = r.lnum,
              col_start = start0,
              col_end = end0,
              latest_tag = latest.latest_tag,
              latest_sha = latest.latest_sha,
              kind = "comment",
            })
          end
        end
      end

      if not virt_by_lnum[r.lnum] then
        local text = ""
        if latest.latest_tag then
          text = ("# Latest: %s %s"):format(latest.latest_tag, util.sha7(latest.latest_sha))
        else
          text = ("# Latest: %s"):format(util.sha7(latest.latest_sha))
        end
        virt_by_lnum[r.lnum] = text
      end
    elseif err then
      if not virt_by_lnum[r.lnum] then
        virt_by_lnum[r.lnum] = "# Latest: (resolve failed)"
      end
    end
  end

  diagnostic.set_outdated(bufnr, outdated)

  local virt = {}
  for lnum, text in pairs(virt_by_lnum) do
    table.insert(virt, { lnum = lnum, text = text })
  end
  table.sort(virt, function(a, b)
    return a.lnum < b.lnum
  end)
  ui.set_virtual_text(bufnr, virt, state.cfg.virtual_text)
end

---@param bufnr integer
---@return nil
function M.check(bufnr)
  ensure_setup()
  if not state.cfg.enabled then
    return
  end

  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local b = state.by_buf[bufnr] or { gen = 0 }
  b.gen = (b.gen or 0) + 1
  state.by_buf[bufnr] = b
  local gen = b.gen

  local refs = parser.parse_buf(bufnr)
  b.refs = refs

  diagnostic.clear(bufnr)
  ui.clear(bufnr)

  if #refs == 0 then
    b.repo = {}
    b.err = {}
    return
  end

  resolve_for_refs(refs, function(repo_result, repo_err)
    if not state.by_buf[bufnr] or state.by_buf[bufnr].gen ~= gen then
      return
    end
    b.repo = repo_result
    b.err = repo_err
    render(bufnr, refs, repo_result, repo_err)
  end)
end

---@param bufnr integer
---@param line1 integer 1-based
---@param line2 integer 1-based
---@return nil
function M.fix(bufnr, line1, line2)
  ensure_setup()
  if not state.cfg.enabled then
    return
  end

  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local refs = parser.parse_buf(bufnr)
  if #refs == 0 then
    util.notify("No pinned `uses:` found in buffer", vim.log.levels.INFO)
    return
  end

  local from0 = (line1 or 1) - 1
  local to0 = (line2 or vim.api.nvim_buf_line_count(bufnr)) - 1
  local filtered = {}
  for _, r in ipairs(refs) do
    if r.lnum >= from0 and r.lnum <= to0 then
      table.insert(filtered, r)
    end
  end
  if #filtered == 0 then
    util.notify("No pinned `uses:` in range", vim.log.levels.INFO)
    return
  end

  resolve_for_refs(filtered, function(repo_result, repo_err)
    local edits = {}
    local sha_edit_count = 0
    local comment_edit_count = 0
    for _, r in ipairs(filtered) do
      local key = cache.key(state.cfg.github.api_base_url, r.owner, r.repo)
      local latest = repo_result[key]
      if latest and latest.latest_sha and latest.latest_sha ~= "" then
        local ref_edits = fix.edit_for_ref(r, latest.latest_sha, latest.latest_tag)
        for _, e in ipairs(ref_edits) do
          table.insert(edits, e)
          if e.kind == "sha" then
            sha_edit_count = sha_edit_count + 1
          elseif e.kind == "comment" then
            comment_edit_count = comment_edit_count + 1
          end
        end
      end
    end

    local failed_repo_count = 0
    if repo_err then
      for _k, _v in pairs(repo_err) do
        failed_repo_count = failed_repo_count + 1
      end
    end

    if #edits == 0 then
      if failed_repo_count > 0 then
        util.notify(
          ("Nothing to fix (failed to resolve latest for %d repo(s))"):format(failed_repo_count),
          vim.log.levels.INFO
        )
      else
        util.notify("Nothing to fix (already latest)", vim.log.levels.INFO)
      end
      M.check(bufnr)
      return
    end

    fix.apply_edits(bufnr, edits)
    if failed_repo_count > 0 then
      if sha_edit_count == 0 and comment_edit_count > 0 then
        util.notify(
          ("Updated %d version comment(s) (failed to resolve: %d repo(s))"):format(
            comment_edit_count,
            failed_repo_count
          ),
          vim.log.levels.INFO
        )
      elseif comment_edit_count > 0 then
        util.notify(
          ("Updated %d pinned SHA(s) (+%d version comment(s)) (failed to resolve: %d repo(s))"):format(
            sha_edit_count,
            comment_edit_count,
            failed_repo_count
          ),
          vim.log.levels.INFO
        )
      else
        util.notify(
          ("Updated %d pinned SHA(s) (failed to resolve: %d repo(s))"):format(sha_edit_count, failed_repo_count),
          vim.log.levels.INFO
        )
      end
    else
      if sha_edit_count == 0 and comment_edit_count > 0 then
        util.notify(("Updated %d version comment(s)"):format(comment_edit_count), vim.log.levels.INFO)
      elseif comment_edit_count > 0 then
        util.notify(
          ("Updated %d pinned SHA(s) (+%d version comment(s))"):format(sha_edit_count, comment_edit_count),
          vim.log.levels.INFO
        )
      else
        util.notify(("Updated %d pinned SHA(s)"):format(sha_edit_count), vim.log.levels.INFO)
      end
    end
    M.check(bufnr)
  end)
end

---@param bufnr integer
---@return nil
function M.explain(bufnr)
  ensure_setup()
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1

  local b = state.by_buf[bufnr]
  local ref = nil
  if b and b.refs then
    for _, r in ipairs(b.refs) do
      if r.lnum == row then
        ref = r
        break
      end
    end
  end

  if not ref then
    -- best-effort: parse current buffer and try again
    local refs = parser.parse_buf(bufnr)
    for _, r in ipairs(refs) do
      if r.lnum == row then
        ref = r
        break
      end
    end
  end

  if not ref then
    util.notify("No pinned `uses:` under cursor", vim.log.levels.INFO)
    return
  end

  local key = cache.key(state.cfg.github.api_base_url, ref.owner, ref.repo)
  local latest = b and b.repo and b.repo[key] or nil
  local err = b and b.err and b.err[key] or nil

  local lines = {
    ("Uses:   %s"):format(ref.uses),
    ("Repo:   %s/%s"):format(ref.owner, ref.repo),
    ("Pinned: %s"):format(util.sha7(ref.sha)),
  }
  if latest and latest.latest_sha and latest.latest_sha ~= "" then
    if latest.latest_tag then
      table.insert(lines, ("Latest:  %s %s"):format(latest.latest_tag, util.sha7(latest.latest_sha)))
    else
      table.insert(lines, ("Latest:  %s"):format(util.sha7(latest.latest_sha)))
    end
    if latest.source then
      table.insert(lines, ("Source: %s"):format(latest.source))
    end
  elseif latest and latest.latest_sha == "" then
    if latest.latest_tag then
      table.insert(
        lines,
        ("Latest:  %s%s"):format(
          latest.latest_tag,
          cooldown_suffix(latest.published_at, state.cfg.minimum_release_age_seconds)
        )
      )
    else
      table.insert(lines, "Latest:  (cooldown)")
    end
    if latest.source then
      table.insert(lines, ("Source: %s"):format(latest.source))
    end
  elseif err then
    table.insert(lines, "Latest:  (resolve failed)")
    table.insert(lines, ("Error:   %s"):format(util.trim(err)))
  else
    table.insert(lines, "Latest:  (not resolved yet)")
    table.insert(lines, "Hint:    run :GhaPinCheck")
  end
  table.insert(lines, ("URL:    https://github.com/%s/%s"):format(ref.owner, ref.repo))

  ui.echo(lines)
end

---@return nil
function M.cache_clear()
  ensure_setup()
  cache.clear()
  state.cache = cache.load()
end

---@param cfg GhaPinConfig|nil
---@return nil
function M.setup(cfg)
  local user_cfg = normalize_user_cfg(cfg)
  local ok, merged = pcall(deep_merge, vim.deepcopy(defaults), user_cfg)
  if not ok or type(merged) ~= "table" then
    util.notify("setup(): invalid cfg; falling back to defaults", vim.log.levels.WARN)
    merged = vim.deepcopy(defaults)
  end
  state.cfg = validate_cfg(merged)
  state.cache = cache.load()
  state.did_setup = true

  local group = vim.api.nvim_create_augroup("GhaPinNvim", { clear = true })

  -- Cleanup per-buffer state/timers to avoid leaks in long sessions.
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(args)
      local id = state.timers[args.buf]
      if id then
        pcall(vim.fn.timer_stop, id)
        state.timers[args.buf] = nil
      end
      state.by_buf[args.buf] = nil
    end,
  })

  if state.cfg.auto_check and state.cfg.auto_check.enabled then
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
      group = group,
      callback = function(args)
        local name = vim.api.nvim_buf_get_name(args.buf)
        if not is_workflow_file(name) then
          return
        end
        local ms = state.cfg.auto_check.debounce_ms or 700
        if state.timers[args.buf] then
          pcall(vim.fn.timer_stop, state.timers[args.buf])
          state.timers[args.buf] = nil
        end
        state.timers[args.buf] = vim.fn.timer_start(ms, function()
          util.schedule(function()
            if vim.api.nvim_buf_is_valid(args.buf) then
              M.check(args.buf)
            end
          end)
        end)
      end,
    })
  end
end

return M
