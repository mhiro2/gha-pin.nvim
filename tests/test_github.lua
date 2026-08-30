local MiniTest = require("mini.test")
local expect = MiniTest.expect

local github = require("gha-pin.github")
local system = require("gha-pin.system")
local util = require("gha-pin.util")

local T = MiniTest.new_set()

local function hex40(c)
  return string.rep(c, 40)
end

local function with_stubs(opts, fn)
  local orig_run = system.run
  local orig_executable = vim.fn.executable
  github._test_reset_request_state()

  vim.fn.executable = function(name)
    if opts.executable and opts.executable[name] ~= nil then
      return opts.executable[name]
    end
    return orig_executable(name)
  end

  system.run = function(cmd, cb)
    local res = opts.route(cmd)
    cb(res)
  end

  local ok, err = pcall(fn)

  system.run = orig_run
  vim.fn.executable = orig_executable
  github._test_reset_request_state()

  if not ok then
    error(err)
  end
end

---@param opts { max_concurrent?: integer, max_retries?: integer, retry_base_delay_ms?: integer }
---@param fn fun()
local function with_request_limits(opts, fn)
  github._test_set_request_limits(opts)
  local ok, err = pcall(fn)
  github._test_reset_request_state()
  if not ok then
    error(err)
  end
end

---@param cmd any[]
---@param needle string
---@return boolean
local function cmd_has(cmd, needle)
  for _, v in ipairs(cmd) do
    if type(v) == "string" and v:find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

T["resolve_latest: release -> tag ref commit"] = function()
  local sha = hex40("a")
  local cfg = { api_base_url = "https://api.github.com", prefer_gh = false, token_env = "GITHUB_TOKEN" }

  with_stubs({
    executable = { curl = 1, gh = 0 },
    route = function(cmd)
      if cmd_has(cmd, "repos/o/r/releases/latest") then
        return {
          code = 0,
          stdout = '{"tag_name":"v1.2.3","published_at":"2024-01-15T10:30:00Z"}',
          stderr = "",
        }
      end
      if cmd_has(cmd, "repos/o/r/git/ref/tags/v1.2.3") then
        return { code = 0, stdout = ('{"object":{"type":"commit","sha":"%s"}}'):format(sha), stderr = "" }
      end
      return { code = 1, stdout = "", stderr = "unexpected endpoint" }
    end,
  }, function()
    local got_res, got_err
    github.resolve_latest(cfg, 0, "o", "r", function(res, err)
      got_res, got_err = res, err
    end)
    vim.wait(100, function()
      return got_res ~= nil or got_err ~= nil
    end)

    expect.equality(got_err, nil)
    expect.equality(got_res.latest_tag, "v1.2.3")
    expect.equality(got_res.latest_sha, sha)
    expect.equality(got_res.source, "release")
    expect.equality(got_res.published_at, "2024-01-15T10:30:00Z")
  end)
end

T["resolve_latest: releases/latest 404 -> tags fallback"] = function()
  local sha = hex40("b")
  local cfg = { api_base_url = "https://api.github.com", prefer_gh = false, token_env = "GITHUB_TOKEN" }

  with_stubs({
    executable = { curl = 1, gh = 0 },
    route = function(cmd)
      if cmd_has(cmd, "repos/o/r/releases/latest") then
        return { code = 22, stdout = "", stderr = "HTTP 404 Not Found" }
      end
      if cmd_has(cmd, "repos/o/r/tags?per_page=1") then
        return {
          code = 0,
          stdout = ('[{"name":"v9.9.9","commit":{"sha":"%s"}}]'):format(sha),
          stderr = "",
        }
      end
      return { code = 1, stdout = "", stderr = "unexpected endpoint" }
    end,
  }, function()
    local got_res, got_err
    github.resolve_latest(cfg, 0, "o", "r", function(res, err)
      got_res, got_err = res, err
    end)
    vim.wait(100, function()
      return got_res ~= nil or got_err ~= nil
    end)

    expect.equality(got_err, nil)
    expect.equality(got_res.latest_tag, "v9.9.9")
    expect.equality(got_res.latest_sha, sha)
    expect.equality(got_res.source, "tags")
  end)
end

T["resolve_latest: non-HTTP errors containing 404 or Not Found do not use tags fallback"] = function()
  local cfg = { api_base_url = "https://api-404.example", prefer_gh = false, token_env = "GITHUB_TOKEN" }

  for _, release_error in ipairs({
    "curl: (6) Could not resolve host: api-404.example",
    "transport Not Found before receiving HTTP response",
  }) do
    local tag_list_requests = 0
    with_stubs({
      executable = { curl = 1, gh = 0 },
      route = function(cmd)
        if cmd_has(cmd, "repos/o/r/releases/latest") then
          return { code = 6, stdout = "", stderr = release_error }
        end
        if cmd_has(cmd, "repos/o/r/tags?per_page=1") then
          tag_list_requests = tag_list_requests + 1
        end
        return { code = 1, stdout = "", stderr = "unexpected endpoint" }
      end,
    }, function()
      local got_res, got_err
      github.resolve_latest(cfg, 0, "o", "r", function(res, err)
        got_res, got_err = res, err
      end)
      vim.wait(100, function()
        return got_res ~= nil or got_err ~= nil
      end)

      expect.equality(got_res, nil)
      expect.equality(got_err, release_error)
      expect.equality(tag_list_requests, 0)
    end)
  end
end

T["resolve_latest: annotated tag -> git/tags -> commit"] = function()
  local tag_sha = hex40("c")
  local commit_sha = hex40("d")
  local cfg = { api_base_url = "https://api.github.com", prefer_gh = false, token_env = "GITHUB_TOKEN" }

  with_stubs({
    executable = { curl = 1, gh = 0 },
    route = function(cmd)
      if cmd_has(cmd, "repos/o/r/releases/latest") then
        return { code = 0, stdout = '{"tag_name":"v0.1.0"}', stderr = "" }
      end
      if cmd_has(cmd, "repos/o/r/git/ref/tags/v0.1.0") then
        return { code = 0, stdout = ('{"object":{"type":"tag","sha":"%s"}}'):format(tag_sha), stderr = "" }
      end
      if cmd_has(cmd, "repos/o/r/git/tags/" .. tag_sha) then
        return {
          code = 0,
          stdout = ('{"object":{"type":"commit","sha":"%s"}}'):format(commit_sha),
          stderr = "",
        }
      end
      return { code = 1, stdout = "", stderr = "unexpected endpoint" }
    end,
  }, function()
    local got_res, got_err
    github.resolve_latest(cfg, 0, "o", "r", function(res, err)
      got_res, got_err = res, err
    end)
    vim.wait(100, function()
      return got_res ~= nil or got_err ~= nil
    end)

    expect.equality(got_err, nil)
    expect.equality(got_res.latest_tag, "v0.1.0")
    expect.equality(got_res.latest_sha, commit_sha)
    expect.equality(got_res.source, "release")
  end)
end

T["resolve_latest: json decode failure returns error"] = function()
  local cfg = { api_base_url = "https://api.github.com", prefer_gh = false, token_env = "GITHUB_TOKEN" }

  with_stubs({
    executable = { curl = 1, gh = 0 },
    route = function(cmd)
      if cmd_has(cmd, "repos/o/r/releases/latest") then
        return { code = 0, stdout = "not json", stderr = "" }
      end
      return { code = 1, stdout = "", stderr = "unexpected endpoint" }
    end,
  }, function()
    local got_res, got_err
    github.resolve_latest(cfg, 0, "o", "r", function(res, err)
      got_res, got_err = res, err
    end)
    vim.wait(100, function()
      return got_res ~= nil or got_err ~= nil
    end)

    expect.equality(got_res, nil)
    expect.equality(type(got_err), "string")
  end)
end

T["resolve_latest: retries transient 5xx and succeeds"] = function()
  local sha = hex40("9")
  local cfg = { api_base_url = "https://api.github.com", prefer_gh = false, token_env = "GITHUB_TOKEN" }
  local release_attempts = 0

  with_stubs({
    executable = { curl = 1, gh = 0 },
    route = function(cmd)
      if cmd_has(cmd, "repos/o/r/releases/latest") then
        release_attempts = release_attempts + 1
        if release_attempts == 1 then
          return { code = 22, stdout = "", stderr = "HTTP 502 Bad Gateway" }
        end
        return { code = 0, stdout = '{"tag_name":"v3.0.0"}', stderr = "" }
      end
      if cmd_has(cmd, "repos/o/r/git/ref/tags/v3.0.0") then
        return { code = 0, stdout = ('{"object":{"type":"commit","sha":"%s"}}'):format(sha), stderr = "" }
      end
      return { code = 1, stdout = "", stderr = "unexpected endpoint" }
    end,
  }, function()
    with_request_limits({ max_retries = 2, retry_base_delay_ms = 0 }, function()
      local got_res, got_err
      github.resolve_latest(cfg, 0, "o", "r", function(res, err)
        got_res, got_err = res, err
      end)
      vim.wait(300, function()
        return got_res ~= nil or got_err ~= nil
      end)

      expect.equality(got_err, nil)
      expect.equality(got_res.latest_tag, "v3.0.0")
      expect.equality(got_res.latest_sha, sha)
      expect.equality(release_attempts, 2)
    end)
  end)
end

T["resolve_latest: caps concurrent outbound requests"] = function()
  local cfg = { api_base_url = "https://api.github.com", prefer_gh = false, token_env = "GITHUB_TOKEN" }
  local sha = hex40("a")
  local total = 6
  local completed = 0
  local failed = 0
  local running = 0
  local max_running = 0

  local orig_run = system.run
  local orig_executable = vim.fn.executable
  github._test_reset_request_state()
  github._test_set_request_limits({ max_concurrent = 2, max_retries = 0, retry_base_delay_ms = 0 })

  vim.fn.executable = function(name)
    if name == "curl" then
      return 1
    end
    if name == "gh" then
      return 0
    end
    return orig_executable(name)
  end

  system.run = function(cmd, cb)
    running = running + 1
    max_running = math.max(max_running, running)
    vim.defer_fn(function()
      running = running - 1
      if cmd_has(cmd, "releases/latest") then
        cb({ code = 0, stdout = '{"tag_name":"v1.0.0"}', stderr = "" })
        return
      end
      if cmd_has(cmd, "git/ref/tags/v1.0.0") then
        cb({ code = 0, stdout = ('{"object":{"type":"commit","sha":"%s"}}'):format(sha), stderr = "" })
        return
      end
      cb({ code = 1, stdout = "", stderr = "unexpected endpoint" })
    end, 20)
  end

  local ok, err = pcall(function()
    for i = 1, total do
      github.resolve_latest(cfg, 0, "o", ("repo-%d"):format(i), function(res, resolve_err)
        if resolve_err or not res then
          failed = failed + 1
        end
        completed = completed + 1
      end)
    end

    local done = vim.wait(5000, function()
      return completed == total
    end, 10)
    expect.equality(done, true)
    expect.equality(failed, 0)
    expect.equality(max_running <= 2, true)
  end)

  system.run = orig_run
  vim.fn.executable = orig_executable
  github._test_reset_request_state()

  if not ok then
    error(err)
  end
end

T["resolve_latest: cooldown disabled (0) allows all releases"] = function()
  local sha = hex40("a")
  local cfg = { api_base_url = "https://api.github.com", prefer_gh = false, token_env = "GITHUB_TOKEN" }

  with_stubs({
    executable = { curl = 1, gh = 0 },
    route = function(cmd)
      if cmd_has(cmd, "repos/o/r/releases/latest") then
        return { code = 0, stdout = '{"tag_name":"v1.2.3"}', stderr = "" }
      end
      if cmd_has(cmd, "repos/o/r/git/ref/tags/v1.2.3") then
        return { code = 0, stdout = ('{"object":{"type":"commit","sha":"%s"}}'):format(sha), stderr = "" }
      end
      return { code = 1, stdout = "", stderr = "unexpected endpoint" }
    end,
  }, function()
    local got_res
    github.resolve_latest(cfg, 0, "o", "r", function(res, _err)
      got_res = res
    end)
    vim.wait(100, function()
      return got_res ~= nil
    end)

    expect.equality(got_res.latest_sha, sha) -- Should return SHA even with cooldown=0
  end)
end

T["resolve_latest: tags fallback skips cooldown (no timestamp fetch)"] = function()
  local sha = hex40("b")
  local cfg = { api_base_url = "https://api.github.com", prefer_gh = false, token_env = "GITHUB_TOKEN" }

  with_stubs({
    executable = { curl = 1, gh = 0 },
    route = function(cmd)
      if cmd_has(cmd, "repos/o/r/releases/latest") then
        return { code = 22, stdout = "", stderr = "HTTP 404 Not Found" }
      end
      if cmd_has(cmd, "repos/o/r/tags?per_page=1") then
        return { code = 0, stdout = ('[{"name":"v9.9.9","commit":{"sha":"%s"}}]'):format(sha), stderr = "" }
      end
      return { code = 1, stdout = "", stderr = "unexpected endpoint" }
    end,
  }, function()
    local got_res
    github.resolve_latest(cfg, 3600, "o", "r", function(res, _err)
      got_res = res
    end)
    vim.wait(100, function()
      return got_res ~= nil
    end)

    expect.equality(got_res.latest_sha, sha) -- Tags should skip cooldown
    expect.equality(got_res.published_at, nil) -- No timestamp for tags
  end)
end

T["resolve_latest: lightweight tag within cooldown returns empty SHA"] = function()
  local sha = hex40("c")
  local cfg = { api_base_url = "https://api.github.com", prefer_gh = false, token_env = "GITHUB_TOKEN" }
  local commit_requests = 0

  -- Mock timestamp_age_seconds to return a value within cooldown period
  local orig_timestamp_age_seconds = util.timestamp_age_seconds
  util.timestamp_age_seconds = function(_timestamp)
    return 1800 -- 30 minutes ago, within 1 hour cooldown
  end

  with_stubs({
    executable = { curl = 1, gh = 0 },
    route = function(cmd)
      if cmd_has(cmd, "repos/o/r/releases/latest") then
        return {
          code = 0,
          stdout = '{"tag_name":"v1.0.0","published_at":"2024-01-15T10:30:00Z"}',
          stderr = "",
        }
      end
      if cmd_has(cmd, "repos/o/r/git/ref/tags/v1.0.0") then
        -- Lightweight tag: object.type is "commit"
        return { code = 0, stdout = ('{"object":{"type":"commit","sha":"%s"}}'):format(sha), stderr = "" }
      end
      if cmd_has(cmd, "repos/o/r/commits/" .. sha) then
        commit_requests = commit_requests + 1
        return {
          code = 0,
          stdout = '{"commit":{"committer":{"date":"2024-01-15T10:30:00Z"}}}',
          stderr = "",
        }
      end
      return { code = 1, stdout = "", stderr = "unexpected endpoint" }
    end,
  }, function()
    local got_res
    github.resolve_latest(cfg, 3600, "o", "r", function(res, _err)
      got_res = res
    end)
    vim.wait(100, function()
      return got_res ~= nil
    end)

    expect.equality(got_res.latest_sha, "")
    expect.equality(got_res.resolved_sha, sha)
    assert(got_res.published_at ~= nil, "Should have timestamp")
    expect.equality(commit_requests, 0)
  end)

  util.timestamp_age_seconds = orig_timestamp_age_seconds
end

T["resolve_latest: lightweight tag past cooldown returns actual SHA"] = function()
  local sha = hex40("d")
  local cfg = { api_base_url = "https://api.github.com", prefer_gh = false, token_env = "GITHUB_TOKEN" }

  -- Mock timestamp_age_seconds to return a value past cooldown period
  local orig_timestamp_age_seconds = util.timestamp_age_seconds
  util.timestamp_age_seconds = function(_timestamp)
    return 7200 -- 2 hours ago, past 1 hour cooldown
  end

  with_stubs({
    executable = { curl = 1, gh = 0 },
    route = function(cmd)
      if cmd_has(cmd, "repos/o/r/releases/latest") then
        return {
          code = 0,
          stdout = '{"tag_name":"v1.0.0","published_at":"2024-01-15T10:30:00Z"}',
          stderr = "",
        }
      end
      if cmd_has(cmd, "repos/o/r/git/ref/tags/v1.0.0") then
        -- Lightweight tag: object.type is "commit"
        return { code = 0, stdout = ('{"object":{"type":"commit","sha":"%s"}}'):format(sha), stderr = "" }
      end
      if cmd_has(cmd, "repos/o/r/commits/" .. sha) then
        return {
          code = 0,
          stdout = '{"commit":{"committer":{"date":"2024-01-15T10:30:00Z"}}}',
          stderr = "",
        }
      end
      return { code = 1, stdout = "", stderr = "unexpected endpoint" }
    end,
  }, function()
    local got_res
    github.resolve_latest(cfg, 3600, "o", "r", function(res, _err)
      got_res = res
    end)
    vim.wait(100, function()
      return got_res ~= nil
    end)

    expect.equality(got_res.latest_sha, sha)
    assert(got_res.published_at ~= nil, "Should have timestamp")
  end)

  util.timestamp_age_seconds = orig_timestamp_age_seconds
end

T["resolve_latest: annotated tag within cooldown returns empty SHA"] = function()
  local tag_sha = hex40("e")
  local commit_sha = hex40("f")
  local cfg = { api_base_url = "https://api.github.com", prefer_gh = false, token_env = "GITHUB_TOKEN" }
  local tag_object_requests = 0

  -- Mock timestamp_age_seconds to return a value within cooldown period
  local orig_timestamp_age_seconds = util.timestamp_age_seconds
  util.timestamp_age_seconds = function(_timestamp)
    return 1800 -- 30 minutes ago, within 1 hour cooldown
  end

  with_stubs({
    executable = { curl = 1, gh = 0 },
    route = function(cmd)
      if cmd_has(cmd, "repos/o/r/releases/latest") then
        return {
          code = 0,
          stdout = '{"tag_name":"v2.0.0","published_at":"2024-01-15T10:30:00Z"}',
          stderr = "",
        }
      end
      if cmd_has(cmd, "repos/o/r/git/ref/tags/v2.0.0") then
        -- Annotated tag
        return { code = 0, stdout = ('{"object":{"type":"tag","sha":"%s"}}'):format(tag_sha), stderr = "" }
      end
      if cmd_has(cmd, "repos/o/r/git/tags/" .. tag_sha) then
        tag_object_requests = tag_object_requests + 1
        return {
          code = 0,
          stdout = ('{"object":{"type":"commit","sha":"%s"},"tagger":{"date":"2024-01-15T10:30:00Z"}}'):format(
            commit_sha
          ),
          stderr = "",
        }
      end
      return { code = 1, stdout = "", stderr = "unexpected endpoint" }
    end,
  }, function()
    local got_res
    github.resolve_latest(cfg, 3600, "o", "r", function(res, _err)
      got_res = res
    end)
    vim.wait(100, function()
      return got_res ~= nil
    end)

    -- Within cooldown: empty SHA indicates not eligible yet
    expect.equality(got_res.latest_sha, "")
    expect.equality(got_res.resolved_sha, commit_sha)
    expect.equality(got_res.latest_tag, "v2.0.0")
    expect.equality(got_res.source, "release")
    assert(got_res.published_at ~= nil, "Should have timestamp")
    expect.equality(tag_object_requests, 1)
  end)

  util.timestamp_age_seconds = orig_timestamp_age_seconds
end

T["resolve_latest: annotated tag past cooldown returns actual SHA"] = function()
  local tag_sha = hex40("0")
  local commit_sha = hex40("1")
  local cfg = { api_base_url = "https://api.github.com", prefer_gh = false, token_env = "GITHUB_TOKEN" }

  -- Mock timestamp_age_seconds to return a value past cooldown period
  local orig_timestamp_age_seconds = util.timestamp_age_seconds
  util.timestamp_age_seconds = function(_timestamp)
    return 7200 -- 2 hours ago, past 1 hour cooldown
  end

  with_stubs({
    executable = { curl = 1, gh = 0 },
    route = function(cmd)
      if cmd_has(cmd, "repos/o/r/releases/latest") then
        return {
          code = 0,
          stdout = '{"tag_name":"v2.0.0","published_at":"2024-01-15T10:30:00Z"}',
          stderr = "",
        }
      end
      if cmd_has(cmd, "repos/o/r/git/ref/tags/v2.0.0") then
        -- Annotated tag
        return { code = 0, stdout = ('{"object":{"type":"tag","sha":"%s"}}'):format(tag_sha), stderr = "" }
      end
      if cmd_has(cmd, "repos/o/r/git/tags/" .. tag_sha) then
        return {
          code = 0,
          stdout = ('{"object":{"type":"commit","sha":"%s"},"tagger":{"date":"2024-01-15T10:30:00Z"}}'):format(
            commit_sha
          ),
          stderr = "",
        }
      end
      return { code = 1, stdout = "", stderr = "unexpected endpoint" }
    end,
  }, function()
    local got_res
    github.resolve_latest(cfg, 3600, "o", "r", function(res, _err)
      got_res = res
    end)
    vim.wait(100, function()
      return got_res ~= nil
    end)

    -- Past cooldown: actual SHA should be returned
    expect.equality(got_res.latest_sha, commit_sha)
    expect.equality(got_res.latest_tag, "v2.0.0")
    expect.equality(got_res.source, "release")
    assert(got_res.published_at ~= nil, "Should have timestamp")
  end)

  util.timestamp_age_seconds = orig_timestamp_age_seconds
end

T["resolve_latest: cooldown fails closed for missing or invalid published_at"] = function()
  local cfg = { api_base_url = "https://api.github.com", prefer_gh = false, token_env = "GITHUB_TOKEN" }

  for _, release_json in ipairs({
    '{"tag_name":"v1.0.0"}',
    '{"tag_name":"v1.0.0","published_at":"not-a-date"}',
    '{"tag_name":"v1.0.0","published_at":"2000.999-01-01T00:00:00Z"}',
    '{"tag_name":"v1.0.0","published_at":"2024-01-15T10:30:00.123.456Z"}',
  }) do
    local ref_requests = 0
    with_stubs({
      executable = { curl = 1, gh = 0 },
      route = function(cmd)
        if cmd_has(cmd, "repos/o/r/releases/latest") then
          return { code = 0, stdout = release_json, stderr = "" }
        end
        if cmd_has(cmd, "repos/o/r/git/ref/tags/v1.0.0") then
          ref_requests = ref_requests + 1
        end
        return { code = 1, stdout = "", stderr = "unexpected endpoint" }
      end,
    }, function()
      local got_res, got_err
      github.resolve_latest(cfg, 3600, "o", "r", function(res, err)
        got_res, got_err = res, err
      end)
      vim.wait(100, function()
        return got_res ~= nil or got_err ~= nil
      end)

      expect.equality(got_res, nil)
      expect.equality(got_err, "Latest release has missing or invalid published_at")
      expect.equality(ref_requests, 0)
    end)
  end
end

T["resolve_latest: release tag resolution errors never select another tag"] = function()
  local cfg = { api_base_url = "https://api.github.com", prefer_gh = false, token_env = "GITHUB_TOKEN" }

  for _, ref_error in ipairs({ "HTTP 403 Forbidden", "HTTP 404 Not Found", "HTTP 500 Internal Server Error" }) do
    local tag_list_requests = 0
    with_stubs({
      executable = { curl = 1, gh = 0 },
      route = function(cmd)
        if cmd_has(cmd, "repos/o/r/releases/latest") then
          return {
            code = 0,
            stdout = '{"tag_name":"v1.0.0","published_at":"2024-01-15T10:30:00Z"}',
            stderr = "",
          }
        end
        if cmd_has(cmd, "repos/o/r/git/ref/tags/v1.0.0") then
          return { code = 22, stdout = "", stderr = ref_error }
        end
        if cmd_has(cmd, "repos/o/r/tags?per_page=1") then
          tag_list_requests = tag_list_requests + 1
        end
        return { code = 1, stdout = "", stderr = "unexpected endpoint" }
      end,
    }, function()
      github._test_set_request_limits({ max_retries = 0 })
      local got_res, got_err
      github.resolve_latest(cfg, 0, "o", "r", function(res, err)
        got_res, got_err = res, err
      end)
      vim.wait(100, function()
        return got_res ~= nil or got_err ~= nil
      end)

      expect.equality(got_res, nil)
      expect.equality(got_err, ref_error)
      expect.equality(tag_list_requests, 0)
    end)
  end
end

return T
