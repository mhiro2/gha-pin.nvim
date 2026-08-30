local MiniTest = require("mini.test")
local expect = MiniTest.expect

local cache = require("gha-pin.cache")
local fix = require("gha-pin.fix")
local gha_pin = require("gha-pin")
local diagnostic = require("gha-pin.diagnostic")
local github = require("gha-pin.github")
local ui = require("gha-pin.ui")
local util = require("gha-pin.util")

local function hex40(ch)
  return string.rep(ch, 40)
end

local COMPOSITE_STEP_LNUM = 4
local COMPOSITE_STEP_ROW = 3

local function composite_lines(...)
  return vim.list_extend({ "runs:", "  using: composite", "  steps:" }, { ... })
end

local delayed_test_id = 0

---@param fn fun(pending: {owner: string, repo: string, cb: fun(res: GhaPinGithubResult|nil, err: string|nil)}[])
local function with_delayed_resolve_latest(fn)
  local orig_resolve_latest = github.resolve_latest
  local pending = {}
  github.resolve_latest = function(_cfg, _min_age, owner, repo, cb)
    table.insert(pending, { owner = owner, repo = repo, cb = cb })
  end

  delayed_test_id = delayed_test_id + 1
  gha_pin.setup({
    auto_check = { enabled = false },
    github = {
      api_base_url = ("https://delayed-%d.example.test"):format(delayed_test_id),
      prefer_gh = false,
    },
  })

  local ok, err = pcall(fn, pending)
  github.resolve_latest = orig_resolve_latest
  if not ok then
    error(err)
  end
end

---@param pending {cb: fun(res: GhaPinGithubResult|nil, err: string|nil)}
---@param tag? string
local function complete_resolve(pending, tag)
  pending.cb({
    latest_tag = tag or "v2.0.0",
    latest_sha = hex40("b"),
    source = "release",
    published_at = nil,
  }, nil)
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
    "runs:",
    "  using: composite",
    "  steps:",
    ("    - uses: astral-sh/setup-uv@%s # v7.1.6"):format(hex40("a")),
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
        "runs:",
        "  using: composite",
        "  steps:",
        ("    - uses: o/r@%s"):format(hex40("b")),
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

T["check: ordinary and ambiguous prose comments do not produce version diagnostics"] = function()
  local orig_resolve_latest = github.resolve_latest
  local latest_sha = hex40("b")
  github.resolve_latest = function(_cfg, _min_age, _owner, _repo, cb)
    cb({ latest_tag = "v4.2.0", latest_sha = latest_sha, source = "release", published_at = nil }, nil)
  end

  local ok, err = pcall(function()
    gha_pin.setup({
      auto_check = { enabled = false },
      github = { api_base_url = "https://ambiguous-diagnostic.example.test" },
    })

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "runs:",
      "  using: composite",
      "  steps:",
      ("    - uses: ordinary-comment/action@%s # verify provenance"):format(latest_sha),
      ("    - uses: ordinary-comment/action@%s # v2-factor authentication"):format(latest_sha),
      ("    - uses: ordinary-comment/action@%s # v2FA is required"):format(latest_sha),
    })

    gha_pin.check(bufnr)
    expect.equality(#vim.diagnostic.get(bufnr, { namespace = diagnostic.ns }), 0)
  end)

  github.resolve_latest = orig_resolve_latest
  if not ok then
    error(err)
  end
end

T["fix: updates SHAs without changing ambiguous version prose"] = function()
  local orig_resolve_latest = github.resolve_latest
  local latest_sha = hex40("b")
  github.resolve_latest = function(_cfg, _min_age, _owner, _repo, cb)
    cb({ latest_tag = "v4.2.0", latest_sha = latest_sha, source = "release", published_at = nil }, nil)
  end

  local ok, err = pcall(function()
    gha_pin.setup({
      auto_check = { enabled = false },
      github = { api_base_url = "https://ambiguous-fix.example.test" },
    })

    local old_sha = hex40("a")
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "runs:",
      "  using: composite",
      "  steps:",
      ("    - uses: ambiguous-prose/action@%s # v2-factor authentication"):format(old_sha),
      ("    - uses: ambiguous-prose/action@%s # v2FA is required"):format(old_sha),
    })

    gha_pin.fix(bufnr, 1, 5)

    expect.equality(vim.api.nvim_buf_get_lines(bufnr, 3, 5, false), {
      ("    - uses: ambiguous-prose/action@%s # v2-factor authentication"):format(latest_sha),
      ("    - uses: ambiguous-prose/action@%s # v2FA is required"):format(latest_sha),
    })
  end)

  github.resolve_latest = orig_resolve_latest
  if not ok then
    error(err)
  end
end

T["fix: leaves uses-looking scalar content unchanged and does not resolve it"] = function()
  local orig_resolve_latest = github.resolve_latest
  local resolve_calls = 0
  github.resolve_latest = function()
    resolve_calls = resolve_calls + 1
    error("scalar content must not be resolved")
  end

  local ok, err = pcall(function()
    gha_pin.setup({ auto_check = { enabled = false } })

    local sha = hex40("a")
    local original = {
      "runs:",
      "  using: composite",
      "  steps:",
      '    - run: "echo start',
      ("      uses: actions/checkout@%s"):format(sha),
      '      echo end"',
      "    - run: !!str |",
      ("        uses: actions/setup-node@%s"):format(sha),
      "    - run: &script |",
      ("        - uses: actions/cache@%s"):format(sha),
      "    - run: !custom >-",
      ("        uses: actions/upload-artifact@%s"):format(sha),
      "    - {",
      ("        uses: actions/github-script@%s"):format(sha),
      "      }",
    }
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, original)

    gha_pin.fix(bufnr, 1, #original)

    expect.equality(resolve_calls, 0)
    expect.equality(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), original)
  end)

  github.resolve_latest = orig_resolve_latest
  if not ok then
    error(err)
  end
end

T["fix: delayed callback applies only after resolution completes"] = function()
  with_delayed_resolve_latest(function(pending)
    local old_sha = hex40("a")
    local original = ("    - uses: actions/checkout@%s # v1.0.0"):format(old_sha)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, composite_lines(original))

    gha_pin.fix(bufnr, COMPOSITE_STEP_LNUM, COMPOSITE_STEP_LNUM)
    expect.equality(#pending, 1)
    expect.equality(
      vim.api.nvim_buf_get_lines(bufnr, COMPOSITE_STEP_ROW, COMPOSITE_STEP_ROW + 1, false)[1]:find(old_sha, 1, true)
        ~= nil,
      true
    )

    complete_resolve(pending[1])
    expect.equality(
      vim.api.nvim_buf_get_lines(bufnr, COMPOSITE_STEP_ROW, COMPOSITE_STEP_ROW + 1, false)[1],
      ("    - uses: actions/checkout@%s # v2.0.0"):format(hex40("b"))
    )
  end)
end

T["fix: a second invocation supersedes the older operation"] = function()
  with_delayed_resolve_latest(function(pending)
    local first_original = ("    - uses: actions/checkout@%s # v1.0.0"):format(hex40("a"))
    local second_original = ("    - uses: actions/checkout@%s # v1.0.0"):format(hex40("a"))
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, composite_lines(first_original, second_original))

    gha_pin.fix(bufnr, COMPOSITE_STEP_LNUM, COMPOSITE_STEP_LNUM)
    gha_pin.fix(bufnr, COMPOSITE_STEP_LNUM + 1, COMPOSITE_STEP_LNUM + 1)
    -- Both Fix operations share the same in-flight repository request.
    expect.equality(#pending, 1)

    complete_resolve(pending[1])
    local got = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    expect.equality(got[COMPOSITE_STEP_LNUM], first_original)
    expect.equality(got[COMPOSITE_STEP_LNUM + 1], ("    - uses: actions/checkout@%s # v2.0.0"):format(hex40("b")))
  end)
end

T["fix: an unrelated changedtick while resolving cancels every edit"] = function()
  with_delayed_resolve_latest(function(pending)
    local target = ("    - uses: actions/checkout@%s # v1.0.0"):format(hex40("a"))
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, composite_lines(target, "unrelated: before"))

    gha_pin.fix(bufnr, COMPOSITE_STEP_LNUM, COMPOSITE_STEP_LNUM)
    -- Keep the target slice byte-for-byte identical. This must be rejected by
    -- the operation-level changedtick guard, not by apply_edits' slice guard.
    vim.api.nvim_buf_set_lines(bufnr, COMPOSITE_STEP_ROW + 1, COMPOSITE_STEP_ROW + 2, false, {
      "unrelated: user edit",
    })
    complete_resolve(pending[1])

    expect.equality(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), composite_lines(target, "unrelated: user edit"))
  end)
end

T["fix: an unmodifiable buffer cancels a delayed edit"] = function()
  with_delayed_resolve_latest(function(pending)
    local original = ("    - uses: actions/checkout@%s"):format(hex40("a"))
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, composite_lines(original))

    gha_pin.fix(bufnr, COMPOSITE_STEP_LNUM, COMPOSITE_STEP_LNUM)
    vim.bo[bufnr].modifiable = false
    local ok = pcall(complete_resolve, pending[1])

    expect.equality(ok, true)
    expect.equality(vim.api.nvim_buf_get_lines(bufnr, COMPOSITE_STEP_ROW, COMPOSITE_STEP_ROW + 1, false)[1], original)
    vim.bo[bufnr].modifiable = true
  end)
end

T["fix: wiping a buffer before resolution is safe"] = function()
  with_delayed_resolve_latest(function(pending)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(
      bufnr,
      0,
      -1,
      false,
      composite_lines(("    - uses: actions/checkout@%s"):format(hex40("a")))
    )

    gha_pin.fix(bufnr, COMPOSITE_STEP_LNUM, COMPOSITE_STEP_LNUM)
    expect.equality(gha_pin._has_buffer_state(bufnr), true)
    vim.api.nvim_buf_delete(bufnr, { force = true })
    expect.equality(vim.api.nvim_buf_is_valid(bufnr), false)
    expect.equality(gha_pin._has_buffer_state(bufnr), false)
    expect.equality(pcall(complete_resolve, pending[1]), true)
  end)
end

T["fix: unloading a buffer before resolution is safe"] = function()
  with_delayed_resolve_latest(function(pending)
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(
      bufnr,
      0,
      -1,
      false,
      composite_lines(("    - uses: actions/checkout@%s"):format(hex40("a")))
    )

    gha_pin.fix(bufnr, COMPOSITE_STEP_LNUM, COMPOSITE_STEP_LNUM)
    expect.equality(gha_pin._has_buffer_state(bufnr), true)
    vim.api.nvim_buf_delete(bufnr, { force = true, unload = true })
    expect.equality(vim.api.nvim_buf_is_valid(bufnr), true)
    expect.equality(vim.api.nvim_buf_is_loaded(bufnr), false)
    expect.equality(gha_pin._has_buffer_state(bufnr), false)
    expect.equality(pcall(complete_resolve, pending[1]), true)
  end)
end

T["resolve callbacks: cache miss fan-out and cache hit both isolate exceptions"] = function()
  with_delayed_resolve_latest(function(pending)
    local first = vim.api.nvim_create_buf(false, true)
    local second = vim.api.nvim_create_buf(false, true)
    local original = ("    - uses: actions/checkout@%s"):format(hex40("a"))
    vim.api.nvim_buf_set_lines(first, 0, -1, false, composite_lines(original))
    vim.api.nvim_buf_set_lines(second, 0, -1, false, composite_lines(original))

    gha_pin.fix(first, COMPOSITE_STEP_LNUM, COMPOSITE_STEP_LNUM)
    gha_pin.fix(second, COMPOSITE_STEP_LNUM, COMPOSITE_STEP_LNUM)
    expect.equality(#pending, 1)

    local orig_edit_for_ref = fix.edit_for_ref
    local calls = 0
    fix.edit_for_ref = function(...)
      calls = calls + 1
      if calls == 1 then
        error("intentional callback failure")
      end
      return orig_edit_for_ref(...)
    end

    local ok, err = pcall(complete_resolve, pending[1])
    fix.edit_for_ref = orig_edit_for_ref
    if not ok then
      error(err)
    end

    expect.equality(calls, 2)
    expect.equality(vim.api.nvim_buf_get_lines(first, COMPOSITE_STEP_ROW, COMPOSITE_STEP_ROW + 1, false)[1], original)
    expect.equality(
      vim.api.nvim_buf_get_lines(second, COMPOSITE_STEP_ROW, COMPOSITE_STEP_ROW + 1, false)[1],
      ("    - uses: actions/checkout@%s"):format(hex40("b"))
    )

    -- The completed miss populated the cache. Exercise the synchronous hit
    -- path with the same failing consumer and ensure it cannot escape M.fix.
    local cached = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(cached, 0, -1, false, composite_lines(original))
    local cache_hit_calls = 0
    fix.edit_for_ref = function()
      cache_hit_calls = cache_hit_calls + 1
      error("intentional cache-hit callback failure")
    end
    local cache_hit_ok, cache_hit_err = pcall(gha_pin.fix, cached, COMPOSITE_STEP_LNUM, COMPOSITE_STEP_LNUM)
    fix.edit_for_ref = orig_edit_for_ref

    expect.equality(cache_hit_ok, true)
    expect.equality(cache_hit_err, nil)
    expect.equality(cache_hit_calls, 1)
    expect.equality(#pending, 1)
    expect.equality(vim.api.nvim_buf_get_lines(cached, COMPOSITE_STEP_ROW, COMPOSITE_STEP_ROW + 1, false)[1], original)
  end)
end

return T
