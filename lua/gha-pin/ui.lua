local util = require("gha-pin.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("gha-pin.nvim.ui")

---@class GhaPinVirtItem
---@field lnum integer
---@field text string

---@param bufnr integer
function M.clear(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns, 0, -1)
end

---@param bufnr integer
---@param items GhaPinVirtItem[]
---@param enabled boolean
function M.set_virtual_text(bufnr, items, enabled)
  if not enabled then
    M.clear(bufnr)
    return
  end

  M.clear(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, it in ipairs(items) do
    if it.text and it.text ~= "" and it.lnum >= 0 and it.lnum < line_count then
      local line = vim.api.nvim_buf_get_lines(bufnr, it.lnum, it.lnum + 1, false)[1] or ""
      -- Span the extmark across the whole line and mark it `invalidate`-able
      -- so that deleting the `uses:` line drops the extmark instead of
      -- pulling it onto the following line (e.g. a `with:` line below).
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, it.lnum, 0, {
        end_row = it.lnum,
        end_col = #line,
        virt_text = { { it.text, "Comment" } },
        virt_text_pos = "eol",
        hl_mode = "combine",
        invalidate = true,
        undo_restore = false,
      })
    end
  end
end

---@param lines string[]
function M.echo(lines)
  util.notify(table.concat(lines, "\n"))
end

return M
