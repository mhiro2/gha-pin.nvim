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
T["health"] = require("tests.test_health")
T["init"] = require("tests.test_init")
T["system"] = require("tests.test_system")
T["util"] = require("tests.test_util")
T["version"] = require("tests.test_version")

local M = {}

function M.run()
  MiniTest.run({ tests = T })
end

return M
