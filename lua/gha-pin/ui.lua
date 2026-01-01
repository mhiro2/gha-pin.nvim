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
  for _, it in ipairs(items) do
    if it.text and it.text ~= "" then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, it.lnum, 0, {
        virt_text = { { it.text, "Comment" } },
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
    end
  end
end

---@param lines string[]
function M.echo(lines)
  util.notify(table.concat(lines, "\n"))
end

return M
