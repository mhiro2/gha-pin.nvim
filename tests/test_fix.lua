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
    ("- uses: actions/checkout@%s"):format(OLD),
    "  - name: noop",
    ("  - uses: my-org/my-repo/path/to/action@%s"):format(OLD),
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
  expect.equality(got[1], ("- uses: actions/checkout@%s"):format(NEW))
  expect.equality(got[3], ("  - uses: my-org/my-repo/path/to/action@%s"):format(NEW))
end

T["apply_edits: replaces '# v...' comment when tag is available"] = function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    ("- uses: actions/checkout@%s # v0.0.1"):format(OLD),
    ("- uses: actions/checkout@%s # v 0.0.1"):format(OLD),
    ("- uses: actions/checkout@%s # v0.0.1 extra"):format(OLD),
  })

  local refs = parser.parse_buf(bufnr)
  expect.equality(#refs, 3)

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

  fix.apply_edits(bufnr, edits)

  local got = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  expect.equality(got[1], ("- uses: actions/checkout@%s # v1.2.3"):format(NEW))
  expect.equality(got[2], ("- uses: actions/checkout@%s # v1.2.3"):format(NEW))
  expect.equality(got[3], ("- uses: actions/checkout@%s # v1.2.3 extra"):format(NEW))
end

T["edit_for_ref: no-op when sha and version comment already match (including whitespace)"] = function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    ("- uses: actions/checkout@%s # v1.2.3"):format(NEW),
    ("- uses: actions/checkout@%s # v 1.2.3"):format(NEW),
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
    ("- uses: actions/checkout@%s # v0.0.1"):format(NEW),
  })

  local refs = parser.parse_buf(bufnr)
  expect.equality(#refs, 1)

  local edits = fix.edit_for_ref(refs[1], NEW, "v1.2.3")
  expect.equality(#edits, 1)
  fix.apply_edits(bufnr, edits)

  local got = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  expect.equality(got[1], ("- uses: actions/checkout@%s # v1.2.3"):format(NEW))
end

T["apply_edits: when version is newer but sha is old, both are corrected to resolved latest"] = function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    ("- uses: actions/checkout@%s # v9.9.9"):format(OLD),
  })

  local refs = parser.parse_buf(bufnr)
  expect.equality(#refs, 1)

  local edits = fix.edit_for_ref(refs[1], NEW, "v1.2.3")
  -- sha + comment
  expect.equality(#edits, 2)
  fix.apply_edits(bufnr, edits)

  local got = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  expect.equality(got[1], ("- uses: actions/checkout@%s # v1.2.3"):format(NEW))
end

return T
