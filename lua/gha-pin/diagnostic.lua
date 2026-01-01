local util = require("gha-pin.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("gha-pin.nvim")

---@class GhaPinOutdatedDiag
---@field lnum integer
---@field col_start integer
---@field col_end integer
---@field latest_tag string|nil
---@field latest_sha string|nil
---@field kind '"sha"'|'"comment"'|nil

---@param bufnr integer
function M.clear(bufnr)
  vim.diagnostic.reset(M.ns, bufnr)
end

---@param bufnr integer
---@param items GhaPinOutdatedDiag[]
function M.set_outdated(bufnr, items)
  ---@type vim.Diagnostic[]
  local diags = {}
  for _, it in ipairs(items) do
    local msg = "Pinned SHA is not latest"
    if it.kind == "comment" then
      msg = "Version comment is not latest"
      if it.latest_tag and it.latest_sha then
        msg = ("Version comment is not latest (latest: %s %s)"):format(it.latest_tag, util.sha7(it.latest_sha))
      elseif it.latest_tag then
        msg = ("Version comment is not latest (latest: %s)"):format(it.latest_tag)
      end
    else
      if it.latest_tag and it.latest_sha then
        msg = ("Pinned SHA is not latest (latest: %s %s)"):format(it.latest_tag, util.sha7(it.latest_sha))
      elseif it.latest_sha then
        msg = ("Pinned SHA is not latest (latest: %s)"):format(util.sha7(it.latest_sha))
      end
    end
    table.insert(diags, {
      lnum = it.lnum,
      col = it.col_start,
      end_lnum = it.lnum,
      end_col = it.col_end,
      severity = vim.diagnostic.severity.WARN,
      source = "gha-pin.nvim",
      message = msg,
    })
  end
  vim.diagnostic.set(M.ns, bufnr, diags, {})
end

return M
