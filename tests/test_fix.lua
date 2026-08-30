local MiniTest = require("mini.test")
local expect = MiniTest.expect

local fix = require("gha-pin.fix")
local parser = require("gha-pin.parser")

local T = MiniTest.new_set()

local OLD = "0123456789abcdef0123456789abcdef01234567"
local NEW = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

local function prepare_sha_edit(lines)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local col_start = assert(lines[1]:find("@", 1, true))
  local edits = {
    {
      lnum = 0,
      col_start = col_start,
      col_end = col_start + 40,
      old_text = OLD,
      new_text = NEW,
      kind = "sha",
    },
  }
  local plan, err = fix._test.prepare_edits(bufnr, edits)
  expect.equality(err, nil)
  expect.equality(type(plan), "table")
  return bufnr, plan
end

T["apply_edits: replaces sha portion"] = function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "runs:",
    "  using: composite",
    "  steps:",
    ("    - uses: actions/checkout@%s"):format(OLD),
    "    - name: noop",
    ("    - uses: my-org/my-repo/path/to/action@%s"):format(OLD),
  })

  local refs = parser.parse_buf(bufnr)
  expect.equality(#refs, 2)

  local edits = {}
  for _, r in ipairs(refs) do
    local ref_edits = fix.edit_for_ref(r, NEW, nil)
    for _, e in ipairs(ref_edits) do
      table.insert(edits, e)
    end
  end

  fix.apply_edits(bufnr, edits)

  local got = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  expect.equality(got[4], ("    - uses: actions/checkout@%s"):format(NEW))
  expect.equality(got[6], ("    - uses: my-org/my-repo/path/to/action@%s"):format(NEW))
end

T["apply_edits: handles a quoted key in an indentationless composite sequence"] = function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "runs:",
    "  using: composite",
    "  steps:",
    ('  - "uses": "actions/checkout@%s" # v2. keep punctuation'):format(OLD),
  })

  local refs = parser.parse_buf(bufnr)
  expect.equality(#refs, 1)
  fix.apply_edits(bufnr, fix.edit_for_ref(refs[1], NEW, "v3.1.4"))

  expect.equality(
    vim.api.nvim_buf_get_lines(bufnr, 3, 4, false)[1],
    ('  - "uses": "actions/checkout@%s" # v3.1.4. keep punctuation'):format(NEW)
  )
end

T["apply_edits: replaces '# v...' comment when tag is available"] = function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "runs:",
    "  using: composite",
    "  steps:",
    ("    - uses: actions/checkout@%s # v0.0.1"):format(OLD),
    ("    - uses: actions/checkout@%s # v 0.0.1"):format(OLD),
    ("    - uses: actions/checkout@%s # v0.0.1 extra"):format(OLD),
    ('    - uses: "actions/checkout@%s" # v0.0.1'):format(OLD),
  })

  local refs = parser.parse_buf(bufnr)
  expect.equality(#refs, 4)

  local edits = {}
  -- latest_tag includes leading 'v'
  do
    local ref_edits = fix.edit_for_ref(refs[1], NEW, "v1.2.3")
    for _, e in ipairs(ref_edits) do
      table.insert(edits, e)
    end
  end
  -- latest_tag without leading 'v'
  do
    local ref_edits = fix.edit_for_ref(refs[2], NEW, "1.2.3")
    for _, e in ipairs(ref_edits) do
      table.insert(edits, e)
    end
  end
  -- keep trailing text after matched chunk
  do
    local ref_edits = fix.edit_for_ref(refs[3], NEW, "v1.2.3")
    for _, e in ipairs(ref_edits) do
      table.insert(edits, e)
    end
  end
  -- quoted uses values keep their quotes and update the following marker
  do
    local ref_edits = fix.edit_for_ref(refs[4], NEW, "v1.2.3")
    for _, e in ipairs(ref_edits) do
      table.insert(edits, e)
    end
  end

  fix.apply_edits(bufnr, edits)

  local got = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  expect.equality(got[4], ("    - uses: actions/checkout@%s # v1.2.3"):format(NEW))
  expect.equality(got[5], ("    - uses: actions/checkout@%s # v1.2.3"):format(NEW))
  expect.equality(got[6], ("    - uses: actions/checkout@%s # v1.2.3 extra"):format(NEW))
  expect.equality(got[7], ('    - uses: "actions/checkout@%s" # v1.2.3'):format(NEW))
end

T["edit_for_ref: no-op when sha and version comment already match (including whitespace)"] = function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "runs:",
    "  using: composite",
    "  steps:",
    ("    - uses: actions/checkout@%s # v1.2.3"):format(NEW),
    ("    - uses: actions/checkout@%s # v 1.2.3"):format(NEW),
  })

  local refs = parser.parse_buf(bufnr)
  expect.equality(#refs, 2)

  local e1 = fix.edit_for_ref(refs[1], NEW, "v1.2.3")
  local e2 = fix.edit_for_ref(refs[2], NEW, "1.2.3")
  expect.equality(#e1, 0)
  expect.equality(#e2, 0)
end

T["apply_edits: updates version comment even when sha is already latest"] = function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "runs:",
    "  using: composite",
    "  steps:",
    ("    - uses: actions/checkout@%s # v0.0.1"):format(NEW),
  })

  local refs = parser.parse_buf(bufnr)
  expect.equality(#refs, 1)

  local edits = fix.edit_for_ref(refs[1], NEW, "v1.2.3")
  expect.equality(#edits, 1)
  fix.apply_edits(bufnr, edits)

  local got = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  expect.equality(got[4], ("    - uses: actions/checkout@%s # v1.2.3"):format(NEW))
end

T["apply_edits: when version is newer but sha is old, both are corrected to resolved latest"] = function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "runs:",
    "  using: composite",
    "  steps:",
    ("    - uses: actions/checkout@%s # v9.9.9"):format(OLD),
  })

  local refs = parser.parse_buf(bufnr)
  expect.equality(#refs, 1)

  local edits = fix.edit_for_ref(refs[1], NEW, "v1.2.3")
  -- sha + comment
  expect.equality(#edits, 2)
  fix.apply_edits(bufnr, edits)

  local got = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  expect.equality(got[4], ("    - uses: actions/checkout@%s # v1.2.3"):format(NEW))
end

T["edit_for_ref: preserves ordinary comments beginning with v"] = function()
  local comments = {
    "# verify provenance",
    "# version is managed elsewhere",
    "# validated manually",
    "# vNext is intentionally tracked",
    "# v2-factor authentication",
    "# v2FA is required",
  }

  for _, comment in ipairs(comments) do
    local bufnr = vim.api.nvim_create_buf(false, true)
    local lines = {
      "runs:",
      "  using: composite",
      "  steps:",
      ("    - uses: actions/checkout@%s %s"):format(OLD, comment),
    }
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    local refs = parser.parse_buf(bufnr)
    expect.equality(#refs, 1)

    local edits = fix.edit_for_ref(refs[1], NEW, "v1.2.3")
    expect.equality(#edits, 1)
    expect.equality(edits[1].kind, "sha")
    fix.apply_edits(bufnr, edits)

    local got = vim.api.nvim_buf_get_lines(bufnr, 3, 4, false)[1]
    expect.equality(got, ("    - uses: actions/checkout@%s %s"):format(NEW, comment))
  end
end

T["edit_for_ref: updates only an unambiguous version marker"] = function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "runs:",
    "  using: composite",
    "  steps:",
    ("    - uses: actions/checkout@%s # v1.2.3-beta.1 keep this note"):format(OLD),
  })

  local ref = parser.parse_buf(bufnr)[1]
  fix.apply_edits(bufnr, fix.edit_for_ref(ref, NEW, "v2.0.0-rc.1"))

  local got = vim.api.nvim_buf_get_lines(bufnr, 3, 4, false)[1]
  expect.equality(got, ("    - uses: actions/checkout@%s # v2.0.0-rc.1 keep this note"):format(NEW))
end

T["edit_for_ref: preserves trailing separators, punctuation, and prose"] = function()
  local cases = {
    { before = "# v2. release notes", after = "# v3.1.4. release notes" },
    { before = "# v2- do not remove", after = "# v3.1.4- do not remove" },
    { before = "# v2+ build policy", after = "# v3.1.4+ build policy" },
    { before = "# v2_ internal note", after = "# v3.1.4_ internal note" },
    { before = "# v2, pinned manually", after = "# v3.1.4, pinned manually" },
  }

  for _, case in ipairs(cases) do
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "runs:",
      "  using: composite",
      "  steps:",
      ("    - uses: actions/checkout@%s %s"):format(OLD, case.before),
    })

    local ref = parser.parse_buf(bufnr)[1]
    local edits = fix.edit_for_ref(ref, NEW, "v3.1.4")
    expect.equality(#edits, 2)
    fix.apply_edits(bufnr, edits)

    local got = vim.api.nvim_buf_get_lines(bufnr, 3, 4, false)[1]
    expect.equality(got, ("    - uses: actions/checkout@%s %s"):format(NEW, case.after))
  end
end

T["version_tag: rejects release tags ending in a separator"] = function()
  for _, tag in ipairs({ "v2.", "2-", "v2+", "2_", "v2-factor", "v2FA" }) do
    expect.equality(fix.version_tag(tag), nil)
  end
end

T["version_tag: accepts numeric markers and extended full SemVer"] = function()
  for _, tag in ipairs({ "v4", "4.2", "v4.2.1", "4.2.1-rc.1", "v4.2.1+build.5" }) do
    expect.equality(type(fix.version_tag(tag)), "table")
  end
end

T["edit_for_ref: leaves version comments unchanged for non-version-shaped release tags"] = function()
  local ref = parser.parse_lines({
    "runs:",
    "  using: composite",
    "  steps:",
    ("    - uses: actions/checkout@%s # v1.2.3"):format(OLD),
  })[1]

  for _, tag in ipairs({ "release-next", "v2-factor", "v2FA" }) do
    local edits = fix.edit_for_ref(ref, NEW, tag)
    expect.equality(#edits, 1)
    expect.equality(edits[1].kind, "sha")
  end
end

T["apply_edits: preserves extmarks outside a same-line SHA and comment fragment"] = function()
  local line = ("    - uses: actions/checkout@%s # v0.0.1 trailing"):format(OLD)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "runs:",
    "  using: composite",
    "  steps:",
    line,
  })

  local refs = parser.parse_buf(bufnr)
  local edits = fix.edit_for_ref(refs[1], NEW, "v1.2.3")
  expect.equality(#edits, 2)

  local namespace = vim.api.nvim_create_namespace("gha-pin-test-fragment-extmarks")
  local before_col = 2
  local after_col = assert(line:find("trailing", 1, true)) - 1
  local before = vim.api.nvim_buf_set_extmark(bufnr, namespace, 3, before_col, {})
  local after = vim.api.nvim_buf_set_extmark(bufnr, namespace, 3, after_col, {})

  local applied, err = fix.apply_edits(bufnr, edits)
  expect.equality(applied, true)
  expect.equality(err, nil)
  expect.equality(vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, before, {}), { 3, before_col })
  expect.equality(vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, after, {}), { 3, after_col })
  expect.equality(
    vim.api.nvim_buf_get_lines(bufnr, 3, 4, false)[1],
    ("    - uses: actions/checkout@%s # v1.2.3 trailing"):format(NEW)
  )
end

T["apply_prepared_edits: rejects a buffer wiped after preparation"] = function()
  local original = ("- uses: actions/checkout@%s"):format(OLD)
  local bufnr, plan = prepare_sha_edit({ original })

  vim.api.nvim_buf_delete(bufnr, { force = true })
  local applied, err = fix._test.apply_prepared_edits(bufnr, plan)
  expect.equality(applied, false)
  expect.equality(err:find("valid", 1, true) ~= nil, true)
end

T["apply_prepared_edits: rejects a buffer unloaded after preparation"] = function()
  local original = ("- uses: actions/checkout@%s"):format(OLD)
  local bufnr, plan = prepare_sha_edit({ original })

  vim.api.nvim_buf_delete(bufnr, { force = true, unload = true })
  expect.equality(vim.api.nvim_buf_is_valid(bufnr), true)
  expect.equality(vim.api.nvim_buf_is_loaded(bufnr), false)
  local applied, err = fix._test.apply_prepared_edits(bufnr, plan)
  expect.equality(applied, false)
  expect.equality(err:find("loaded", 1, true) ~= nil, true)
end

T["apply_prepared_edits: rejects an unmodifiable buffer after preparation"] = function()
  local original = ("- uses: actions/checkout@%s"):format(OLD)
  local bufnr, plan = prepare_sha_edit({ original })

  vim.bo[bufnr].modifiable = false
  local applied, err = fix._test.apply_prepared_edits(bufnr, plan)
  expect.equality(applied, false)
  expect.equality(err:find("modifiable", 1, true) ~= nil, true)
  expect.equality(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], original)
  vim.bo[bufnr].modifiable = true
end

T["apply_prepared_edits: rejects an unrelated changedtick after preparation"] = function()
  local original = ("- uses: actions/checkout@%s"):format(OLD)
  local bufnr, plan = prepare_sha_edit({ original, "unrelated: before" })

  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "unrelated: user edit" })
  local applied, err = fix._test.apply_prepared_edits(bufnr, plan)
  expect.equality(applied, false)
  expect.equality(err:find("buffer changed", 1, true) ~= nil, true)
  expect.equality(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { original, "unrelated: user edit" })
end

T["apply_prepared_edits: rejects a changed target slice after preparation"] = function()
  local original = ("- uses: actions/checkout@%s"):format(OLD)
  local bufnr, plan = prepare_sha_edit({ original })
  local user_line = ("- uses: actions/checkout@b%s"):format(OLD:sub(2))

  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { user_line })
  local applied, err = fix._test.apply_prepared_edits(bufnr, plan)
  expect.equality(applied, false)
  expect.equality(err:find("contents changed", 1, true) ~= nil, true)
  expect.equality(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], user_line)
end

T["apply_edits: validates every original slice before changing the buffer"] = function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "runs:",
    "  using: composite",
    "  steps:",
    ("    - uses: actions/checkout@%s"):format(OLD),
    ("    - uses: actions/setup-node@%s"):format(OLD),
  })

  local refs = parser.parse_buf(bufnr)
  local edits = {}
  for _, ref in ipairs(refs) do
    local ref_edits = fix.edit_for_ref(ref, NEW, nil)
    for _, edit in ipairs(ref_edits) do
      table.insert(edits, edit)
    end
  end

  -- Make only the last edit stale. The first edit must not be applied before
  -- the stale range is discovered.
  local user_line = ("    - uses: actions/setup-node@b%s"):format(OLD:sub(2))
  vim.api.nvim_buf_set_lines(bufnr, 4, 5, false, {
    user_line,
  })

  local ok, err = fix.apply_edits(bufnr, edits)
  expect.equality(ok, false)
  expect.equality(type(err), "string")

  local got = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  expect.equality(got[4], ("    - uses: actions/checkout@%s"):format(OLD))
  expect.equality(got[5], user_line)
end

T["apply_edits: one multi-line mutation cannot produce a mixed update"] = function()
  for _, observer in ipairs({ "error", "unmodifiable" }) do
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "runs:",
      "  using: composite",
      "  steps:",
      ("    - uses: actions/checkout@%s"):format(OLD),
      ("    - uses: actions/setup-node@%s"):format(OLD),
    })

    local edits = {}
    for _, ref in ipairs(parser.parse_buf(bufnr)) do
      vim.list_extend(edits, fix.edit_for_ref(ref, NEW, nil))
    end

    local notifications = 0
    vim.api.nvim_buf_attach(bufnr, false, {
      on_lines = function()
        notifications = notifications + 1
        if observer == "error" then
          error("observer boom")
        end
        vim.bo[bufnr].modifiable = false
      end,
    })

    local call_ok, applied, apply_err = pcall(fix.apply_edits, bufnr, edits)
    expect.equality(call_ok, true)
    expect.equality(notifications, 1)

    local got = vim.api.nvim_buf_get_lines(bufnr, 3, 5, false)
    local original = {
      ("    - uses: actions/checkout@%s"):format(OLD),
      ("    - uses: actions/setup-node@%s"):format(OLD),
    }
    local updated = {
      ("    - uses: actions/checkout@%s"):format(NEW),
      ("    - uses: actions/setup-node@%s"):format(NEW),
    }
    local all_original = vim.deep_equal(got, original)
    local all_updated = vim.deep_equal(got, updated)

    -- Either outcome is safe if Neovim reports an observer error before or
    -- after committing the single mutation. A mixed post-image is forbidden.
    expect.equality(all_original or all_updated, true)
    expect.equality(applied, all_updated)
    if applied then
      expect.equality(apply_err, nil)
    else
      expect.equality(type(apply_err), "string")
    end
    vim.bo[bufnr].modifiable = true
  end
end

return T
