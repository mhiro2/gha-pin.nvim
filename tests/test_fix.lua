local MiniTest = require("mini.test")
local expect = MiniTest.expect

local fix = require("gha-pin.fix")
local parser = require("gha-pin.parser")

local T = MiniTest.new_set()

local OLD = "0123456789abcdef0123456789abcdef01234567"
local NEW = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

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

return T
