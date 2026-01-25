local MiniTest = require("mini.test")
local expect = MiniTest.expect

local gha_pin = require("gha-pin")
local github = require("gha-pin.github")

local T = MiniTest.new_set()

local OLD_SHA = "0123456789abcdef0123456789abcdef01234567"
local NEW_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

---@param fn fun()
local function with_resolve_latest_stub(fn)
  local orig_resolve_latest = github.resolve_latest
  github.resolve_latest = function(_cfg, _min_age, _owner, _repo, cb)
    cb({
      latest_tag = "v2.0.0",
      latest_sha = NEW_SHA,
      source = "release",
      published_at = nil,
    }, nil)
  end

  local ok, err = pcall(fn)
  github.resolve_latest = orig_resolve_latest
  if not ok then
    error(err)
  end
end

T["command: with range only updates specified lines"] = function()
  with_resolve_latest_stub(function()
    gha_pin.setup({
      auto_check = { enabled = false },
    })
    gha_pin.cache_clear()

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      ("    - uses: actions/checkout@%s"):format(OLD_SHA), -- line 1
      ("    - uses: actions/setup-node@%s"):format(OLD_SHA), -- line 2 (in range)
      ("    - uses: actions/upload-artifact@%s"):format(OLD_SHA), -- line 3 (in range)
      ("    - uses: actions/checkout@%s"):format(OLD_SHA), -- line 4
    })
    vim.api.nvim_set_current_buf(bufnr)

    -- Fix only lines 2-3 (1-based)
    vim.api.nvim_command("2,3GhaPinFix")

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    -- Line 1: NOT updated (outside range)
    expect.equality(lines[1]:find(OLD_SHA, 1, true) ~= nil, true)

    -- Lines 2-3: updated (within range)
    expect.equality(lines[2]:find(NEW_SHA, 1, true) ~= nil, true)
    expect.equality(lines[3]:find(NEW_SHA, 1, true) ~= nil, true)

    -- Line 4: NOT updated (outside range)
    expect.equality(lines[4]:find(OLD_SHA, 1, true) ~= nil, true)
  end)
end

T["command: without range updates all lines"] = function()
  with_resolve_latest_stub(function()
    gha_pin.setup({
      auto_check = { enabled = false },
    })
    gha_pin.cache_clear()

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      ("    - uses: actions/checkout@%s"):format(OLD_SHA),
      ("    - uses: actions/setup-node@%s"):format(OLD_SHA),
    })
    vim.api.nvim_set_current_buf(bufnr)

    -- Fix without range (all lines)
    vim.api.nvim_command("GhaPinFix")

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    expect.equality(lines[1]:find(NEW_SHA, 1, true) ~= nil, true)
    expect.equality(lines[2]:find(NEW_SHA, 1, true) ~= nil, true)
  end)
end

return T
