local MiniTest = require("mini.test")
local expect = MiniTest.expect

local ui = require("gha-pin.ui")

local T = MiniTest.new_set()

T["set_virtual_text: creates an extmark on every supported Neovim version"] = function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "target line" })

  ui.set_virtual_text(bufnr, { { lnum = 0, text = "# Latest: v2 abcdef0" } }, true)

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ui.ns, 0, -1, { details = true })
  expect.equality(#marks, 1)
  expect.equality(marks[1][2], 0)
  expect.equality(marks[1][4].virt_text[1][1], "# Latest: v2 abcdef0")
end

T["set_virtual_text: invalidates a mark with the supported extmark API"] = function()
  if vim.fn.has("nvim-0.10") == 0 then
    return
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "target line", "next line" })
  ui.set_virtual_text(bufnr, { { lnum = 0, text = "# Latest: v2 abcdef0" } }, true)

  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ui.ns, 0, -1, { details = true })
  expect.equality(#marks, 0)
end

return T
