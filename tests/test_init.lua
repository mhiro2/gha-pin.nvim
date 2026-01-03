local MiniTest = require("mini.test")
local expect = MiniTest.expect

local gha_pin = require("gha-pin")

local T = MiniTest.new_set()

T["_is_target_file: matches workflow files"] = function()
  expect.equality(gha_pin._is_target_file("/repo/.github/workflows/ci.yml"), true)
  expect.equality(gha_pin._is_target_file("/repo/.github/workflows/build.yaml"), true)
  expect.equality(gha_pin._is_target_file("/repo/.github/workflows/notes.txt"), false)
end

T["_is_target_file: matches action.yml for composite actions"] = function()
  expect.equality(gha_pin._is_target_file("/repo/.github/actions/foo/action.yml"), true)
  expect.equality(gha_pin._is_target_file("/repo/.github/actions/foo/action.yaml"), true)
  expect.equality(gha_pin._is_target_file("/repo/.github/actions/foo/other.yml"), false)
  expect.equality(gha_pin._is_target_file("/repo/action.yml"), false)
  expect.equality(gha_pin._is_target_file("/repo/.github/action.yml"), false)
end

T["_is_target_file: handles empty/nil"] = function()
  expect.equality(gha_pin._is_target_file(""), false)
  expect.equality(gha_pin._is_target_file(nil), false)
end

return T
