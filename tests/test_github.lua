local MiniTest = require("mini.test")
local expect = MiniTest.expect

local github = require("gha-pin.github")
local system = require("gha-pin.system")

local T = MiniTest.new_set()

local function hex40(c)
  return string.rep(c, 40)
end

local function with_stubs(opts, fn)
  local orig_run = system.run
  local orig_executable = vim.fn.executable

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
        return { code = 0, stdout = '{"tag_name":"v1.2.3"}', stderr = "" }
      end
      if cmd_has(cmd, "repos/o/r/git/ref/tags/v1.2.3") then
        return { code = 0, stdout = ('{"object":{"type":"commit","sha":"%s"}}'):format(sha), stderr = "" }
      end
      return { code = 1, stdout = "", stderr = "unexpected endpoint" }
    end,
  }, function()
    local got_res, got_err
    github.resolve_latest(cfg, "o", "r", function(res, err)
      got_res, got_err = res, err
    end)
    vim.wait(100, function()
      return got_res ~= nil or got_err ~= nil
    end)

    expect.equality(got_err, nil)
    expect.equality(got_res.latest_tag, "v1.2.3")
    expect.equality(got_res.latest_sha, sha)
    expect.equality(got_res.source, "release")
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
    github.resolve_latest(cfg, "o", "r", function(res, err)
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
    github.resolve_latest(cfg, "o", "r", function(res, err)
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
    github.resolve_latest(cfg, "o", "r", function(res, err)
      got_res, got_err = res, err
    end)
    vim.wait(100, function()
      return got_res ~= nil or got_err ~= nil
    end)

    expect.equality(got_res, nil)
    expect.equality(type(got_err), "string")
  end)
end

return T
