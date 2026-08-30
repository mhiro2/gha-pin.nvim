local MiniTest = require("mini.test")
local expect = MiniTest.expect

local health = require("gha-pin.health")

local T = MiniTest.new_set()

T["check: reports Neovim versions below 0.10 as unsupported"] = function()
  local original_version = vim.version
  local original_executable = vim.fn.executable
  local original_health = {}
  local messages = {}

  for _, name in ipairs({ "start", "ok", "error", "warn", "info" }) do
    local method = name
    original_health[name] = vim.health[name]
    vim.health[name] = function(message)
      if method == "error" then
        table.insert(messages, message)
      end
    end
  end

  vim.version = function()
    return { major = 0, minor = 9, patch = 5 }
  end
  vim.fn.executable = function()
    return 0
  end

  local ok, err = pcall(health.check)

  vim.version = original_version
  vim.fn.executable = original_executable
  for name, fn in pairs(original_health) do
    vim.health[name] = fn
  end

  if not ok then
    error(err)
  end

  local version_error = nil
  for _, message in ipairs(messages) do
    if message:find("Required: >= 0.10.0", 1, true) then
      version_error = message
      break
    end
  end
  expect.equality(version_error, "Neovim 0.9.5 is not supported. Required: >= 0.10.0")
end

return T
