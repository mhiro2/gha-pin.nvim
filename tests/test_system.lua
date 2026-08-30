local MiniTest = require("mini.test")
local expect = MiniTest.expect

local system = require("gha-pin.system")

local T = MiniTest.new_set()

---@param command string[]
---@param timeout integer
---@return GhaPinSystemResult
local function run_and_wait(command, timeout)
  local result = nil
  local callback_count = 0
  local callback_error = nil
  system.run(command, function(value)
    callback_count = callback_count + 1
    local ok, err = pcall(function()
      assert(vim.in_fast_event() == false, "system callback must run on the main loop")
    end)
    if not ok then
      callback_error = err
    end
    result = value
  end, { timeout = timeout })

  local completed = vim.wait(5000, function()
    return result ~= nil
  end)
  expect.equality(completed, true)

  vim.wait(100, function()
    return callback_count > 1
  end)
  if callback_error then
    error(callback_error)
  end
  expect.equality(callback_count, 1)
  return result
end

T["run: captures process exit code and output through vim.system"] = function()
  local result = run_and_wait({
    vim.v.progpath,
    "--headless",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "-c",
    'lua io.stdout:write("stdout-marker"); io.stderr:write("stderr-marker")',
    "-c",
    "cq 7",
  }, 3000)

  expect.equality(result.code, 7)
  expect.equality(result.stdout, "stdout-marker")
  expect.equality(result.stderr, "stderr-marker")
end

T["run: returns vim.system timeout result"] = function()
  local result = run_and_wait({
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
  }, 20)

  expect.equality(result.code, 124)
end

return T
