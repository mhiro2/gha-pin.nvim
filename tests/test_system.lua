local MiniTest = require("mini.test")
local expect = MiniTest.expect

local system = require("gha-pin.system")

local T = MiniTest.new_set()

---@param fn fun()
local function with_jobstart_fallback(fn)
  local orig_system = vim.system
  vim.system = nil
  local ok, err = pcall(fn)
  vim.system = orig_system
  if not ok then
    error(err)
  end
end

T["run: jobstart fallback returns command output"] = function()
  with_jobstart_fallback(function()
    local calls = 0
    local result = nil

    system.run({ vim.v.progpath, "--version" }, function(res)
      calls = calls + 1
      result = res
    end, { timeout = 2000 })

    local done = vim.wait(3000, function()
      return result ~= nil
    end, 10)
    expect.equality(done, true)
    expect.equality(calls, 1)
    expect.equality(result.code, 0)
    expect.equality(result.stdout:find("NVIM", 1, true) ~= nil, true)
  end)
end

T["run: jobstart timeout is scheduled, closes its timer, and calls back once"] = function()
  with_jobstart_fallback(function()
    local uv = vim.uv or vim.loop
    local orig_new_timer = uv.new_timer
    local orig_jobstop = vim.fn.jobstop
    local timer = nil
    local jobstop_in_fast_event = nil
    uv.new_timer = function(...)
      timer = orig_new_timer(...)
      return timer
    end
    vim.fn.jobstop = function(jobid)
      jobstop_in_fast_event = vim.in_fast_event()
      return orig_jobstop(jobid)
    end

    local calls = 0
    local callback_in_fast_event = nil
    local result = nil
    local ok, err = pcall(function()
      system.run({
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "-c",
        "sleep 1000m",
        "-c",
        "qa!",
      }, function(res)
        calls = calls + 1
        callback_in_fast_event = vim.in_fast_event()
        result = res
      end, { timeout = 20 })

      local done = vim.wait(3000, function()
        return result ~= nil
      end, 10)
      expect.equality(done, true)
      expect.equality(result.code, 124)
      expect.equality(result.stderr, "Command timed out after 20 ms")
      expect.equality(timer ~= nil and timer:is_closing(), true)
      expect.equality(jobstop_in_fast_event, false)
      expect.equality(callback_in_fast_event, false)

      vim.wait(200, function()
        return false
      end, 10)
      expect.equality(calls, 1)
    end)

    uv.new_timer = orig_new_timer
    vim.fn.jobstop = orig_jobstop
    if not ok then
      error(err)
    end
  end)
end

return T
