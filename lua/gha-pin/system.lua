local M = {}

---@class GhaPinSystemResult
---@field code integer
---@field stdout string
---@field stderr string

---@class GhaPinSystemOpts
---@field timeout? integer Timeout in milliseconds (default: 30000)

---@param cmd string[]
---@param cb fun(res: GhaPinSystemResult)
---@param opts? GhaPinSystemOpts
function M.run(cmd, cb, opts)
  opts = opts or {}
  local timeout = opts.timeout or 30000 -- 30 second default

  vim.system(cmd, { text = true, timeout = timeout }, function(obj)
    vim.schedule(function()
      cb({
        code = obj.code or 0,
        stdout = obj.stdout or "",
        stderr = obj.stderr or "",
      })
    end)
  end)
end

return M
