local MiniTest = require("mini.test")
local expect = MiniTest.expect

local gha_pin = require("gha-pin")
local github = require("gha-pin.github")

local T = MiniTest.new_set()

local OLD_SHA = "0123456789abcdef0123456789abcdef01234567"
local NEW_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

T["fix: with range only updates specified lines"] = function()
  -- Mock github.resolve_latest
  local orig_resolve_latest = github.resolve_latest
  github.resolve_latest = function(_cfg, _min_age, _owner, _repo, cb)
    cb({
      latest_tag = "v2.0.0",
      latest_sha = NEW_SHA,
      source = "release",
      published_at = nil,
    }, nil)
  end

  gha_pin.setup({
    auto_check = { enabled = false },
  })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    ("    - uses: actions/checkout@%s"):format(OLD_SHA), -- line 1
    ("    - uses: actions/setup-node@%s"):format(OLD_SHA), -- line 2 (in range)
    ("    - uses: actions/upload-artifact@%s"):format(OLD_SHA), -- line 3 (in range)
    ("    - uses: actions/checkout@%s"):format(OLD_SHA), -- line 4
  })

  -- Fix only lines 2-3 (1-based)
  gha_pin.fix(bufnr, 2, 3)

  vim.wait(500, function()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return lines[2]:find(NEW_SHA, 1, true) ~= nil
  end)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Line 1: NOT updated (outside range)
  expect.equality(lines[1]:find(OLD_SHA, 1, true) ~= nil, true)

  -- Lines 2-3: updated (within range)
  expect.equality(lines[2]:find(NEW_SHA, 1, true) ~= nil, true)
  expect.equality(lines[3]:find(NEW_SHA, 1, true) ~= nil, true)

  -- Line 4: NOT updated (outside range)
  expect.equality(lines[4]:find(OLD_SHA, 1, true) ~= nil, true)

  github.resolve_latest = orig_resolve_latest
end

T["fix: with nil range updates all lines"] = function()
  local orig_resolve_latest = github.resolve_latest
  github.resolve_latest = function(_cfg, _min_age, _owner, _repo, cb)
    cb({
      latest_tag = "v2.0.0",
      latest_sha = NEW_SHA,
      source = "release",
      published_at = nil,
    }, nil)
  end

  gha_pin.setup({
    auto_check = { enabled = false },
  })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    ("    - uses: actions/checkout@%s"):format(OLD_SHA),
    ("    - uses: actions/setup-node@%s"):format(OLD_SHA),
  })

  -- Fix with nil range (all lines)
  gha_pin.fix(bufnr, nil, nil)

  vim.wait(500, function()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return lines[1]:find(NEW_SHA, 1, true) ~= nil and lines[2]:find(NEW_SHA, 1, true) ~= nil
  end)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  expect.equality(lines[1]:find(NEW_SHA, 1, true) ~= nil, true)
  expect.equality(lines[2]:find(NEW_SHA, 1, true) ~= nil, true)

  github.resolve_latest = orig_resolve_latest
end

return T
