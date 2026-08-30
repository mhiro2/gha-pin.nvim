local MiniTest = require("mini.test")
local expect = MiniTest.expect

local cache = require("gha-pin.cache")
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

T["setup: rerun closes existing auto-check timers"] = function()
  local orig_new_timer = vim.uv.new_timer

  ---@type { stopped: integer, closed: integer, started: integer }[]
  local created = {}
  vim.uv.new_timer = function()
    local timer = { stopped = 0, closed = 0, started = 0 }
    function timer:start(_ms, _repeat_ms, _cb)
      self.started = self.started + 1
    end
    function timer:stop()
      self.stopped = self.stopped + 1
    end
    function timer:close()
      self.closed = self.closed + 1
    end
    table.insert(created, timer)
    return timer
  end

  local ok, err = pcall(function()
    gha_pin.setup({
      auto_check = { enabled = true, debounce_ms = 10 },
    })

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, "/tmp/repo/.github/workflows/ci.yml")
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = bufnr })
    expect.equality(#created, 1)
    expect.equality(created[1].started, 1)

    gha_pin.setup({
      auto_check = { enabled = true, debounce_ms = 10 },
    })

    expect.equality(created[1].stopped >= 1, true)
    expect.equality(created[1].closed >= 1, true)
  end)

  vim.uv.new_timer = orig_new_timer
  if not ok then
    error(err)
  end
end

T["check: cooldown ignores fresh release cache with invalid publication time"] = function()
  local sha = hex40("a")
  local key = cache.key("https://api.github.com", "o", "r")
  local orig_resolve_latest = github.resolve_latest

  local ok, err = pcall(function()
    for _, value in ipairs({
      false,
      "2000.999-01-01T00:00:00Z",
      "2024-01-15T10:30:00.123.456Z",
    }) do
      cache.clear()
      local data = { version = cache.VERSION, entries = {} }
      cache.put(data, key, "v1.0.0", sha, value or nil, "release", sha)

      local saved = false
      cache.save(data, function(save_ok)
        saved = save_ok
      end)
      expect.equality(
        vim.wait(3000, function()
          return saved
        end, 10),
        true
      )

      local network_calls = 0
      github.resolve_latest = function(_cfg, _minimum_age, _owner, _repo, cb)
        network_calls = network_calls + 1
        cb(nil, "network reached")
      end

      gha_pin.setup({
        auto_check = { enabled = false },
        minimum_release_age_seconds = 3600,
      })

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        ("- uses: o/r@%s"):format(hex40("b")),
      })
      gha_pin.check(bufnr)
      expect.equality(
        vim.wait(100, function()
          return network_calls == 1
        end),
        true
      )
    end
  end)

  github.resolve_latest = orig_resolve_latest
  cache.clear()
  if not ok then
    error(err)
  end
end

return T
