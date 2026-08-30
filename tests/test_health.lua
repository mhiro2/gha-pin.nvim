local MiniTest = require("mini.test")
local expect = MiniTest.expect

local health_module = require("gha-pin.health")

local T = MiniTest.new_set()

T["check: health API works on the minimum Neovim version"] = function()
  local health = vim.health
  local orig_start = health.start
  local orig_ok = health.ok
  local orig_warn = health.warn
  local orig_error = health.error
  local orig_info = health.info
  local orig_executable = vim.fn.executable
  local sections = {}

  health.start = function(name)
    table.insert(sections, name)
  end
  health.ok = function() end
  health.warn = function() end
  health.error = function() end
  health.info = function() end
  vim.fn.executable = function()
    return 0
  end

  local ok, err = pcall(health_module.check)

  health.start = orig_start
  health.ok = orig_ok
  health.warn = orig_warn
  health.error = orig_error
  health.info = orig_info
  vim.fn.executable = orig_executable

  if not ok then
    error(err)
  end
  expect.equality(sections[1], "gha-pin.nvim")
  expect.equality(sections[2], "Neovim version")
end

return T
