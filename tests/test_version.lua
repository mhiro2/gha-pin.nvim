local MiniTest = require("mini.test")
local expect = MiniTest.expect

local gha_pin = require("gha-pin")
local version = require("gha-pin.version")

local T = MiniTest.new_set()

T["is_supported: accepts Neovim 0.10 and newer"] = function()
  expect.equality(version.is_supported({ major = 0, minor = 9, patch = 5 }), false)
  expect.equality(version.is_supported({ major = 0, minor = 10, patch = 0 }), true)
  expect.equality(version.is_supported({ major = 0, minor = 10, patch = 4 }), true)
  expect.equality(version.is_supported({ major = 1, minor = 0, patch = 0 }), true)
end

T["setup: rejects unsupported Neovim versions with an actionable error"] = function()
  local original_version = vim.version
  vim.version = function()
    return { major = 0, minor = 9, patch = 5 }
  end

  local ok, err = pcall(gha_pin.setup, { auto_check = { enabled = false } })
  vim.version = original_version

  expect.equality(ok, false)
  expect.equality(tostring(err):find("gha-pin.nvim requires Neovim >= 0.10.0 (current: 0.9.5)", 1, true) ~= nil, true)
end

return T
