local MiniTest = require("mini.test")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      -- ensure plugin loads cleanly
      require("gha-pin").setup({
        auto_check = { enabled = false },
      })
    end,
  },
})

T["parser"] = require("tests.test_parser")
T["cache"] = require("tests.test_cache")
T["fix"] = require("tests.test_fix")
T["command_range"] = require("tests.test_command_range")
T["github"] = require("tests.test_github")
T["init"] = require("tests.test_init")
T["util"] = require("tests.test_util")

local M = {}

function M.run()
  MiniTest.run({ tests = T })
end

return M
