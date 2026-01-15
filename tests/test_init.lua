local MiniTest = require("mini.test")
local expect = MiniTest.expect

local gha_pin = require("gha-pin")
local github = require("gha-pin.github")
local ui = require("gha-pin.ui")
local util = require("gha-pin.util")

local function hex40(ch)
  return string.rep(ch, 40)
end

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

T["check: virtual text shows cooldown for latest release"] = function()
  local orig_resolve_latest = github.resolve_latest
  local orig_set_virtual_text = ui.set_virtual_text
  local orig_timestamp_age_seconds = util.timestamp_age_seconds

  local got_items = nil
  ui.set_virtual_text = function(_bufnr, items, _enabled)
    got_items = items
  end
  util.timestamp_age_seconds = function(_timestamp)
    return 1800 -- 30 minutes ago, within 1 hour cooldown
  end
  github.resolve_latest = function(_cfg, _min_age, _owner, _repo, cb)
    cb({
      latest_tag = "v7.2.0",
      latest_sha = "",
      source = "release",
      published_at = "2024-01-15T10:30:00Z",
    }, nil)
  end

  gha_pin.setup({
    auto_check = { enabled = false },
    minimum_release_age_seconds = 3600,
  })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    ("- uses: astral-sh/setup-uv@%s # v7.1.6"):format(hex40("a")),
  })

  gha_pin.check(bufnr)
  vim.wait(100, function()
    return got_items ~= nil
  end)

  expect.equality(type(got_items), "table")
  expect.equality(got_items[1].text:find("Latest: v7.2.0", 1, true) ~= nil, true)
  expect.equality(got_items[1].text:find("cooldown", 1, true) ~= nil, true)

  github.resolve_latest = orig_resolve_latest
  ui.set_virtual_text = orig_set_virtual_text
  util.timestamp_age_seconds = orig_timestamp_age_seconds
end

return T
