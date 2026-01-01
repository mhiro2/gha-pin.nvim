local util = require("gha-pin.util")

local M = {}

---@class GhaPinSystemResult
---@field code integer
---@field stdout string
---@field stderr string

---@param cmd string[]
---@param cb fun(res: GhaPinSystemResult)
function M.run(cmd, cb)
  if vim.system then
    vim.system(cmd, { text = true }, function(obj)
      util.schedule(function()
        cb({
          code = obj.code or 0,
          stdout = obj.stdout or "",
          stderr = obj.stderr or "",
        })
      end)
    end)
    return
  end

  -- Fallback: vim.fn.jobstart
  local stdout = {}
  local stderr = {}
  local jobid = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if type(data) == "table" then
        for _, v in ipairs(data) do
          if v ~= "" then
            table.insert(stdout, v)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if type(data) == "table" then
        for _, v in ipairs(data) do
          if v ~= "" then
            table.insert(stderr, v)
          end
        end
      end
    end,
    on_exit = function(_, code)
      util.schedule(function()
        cb({ code = code or 0, stdout = table.concat(stdout, "\n"), stderr = table.concat(stderr, "\n") })
      end)
    end,
  })

  if type(jobid) ~= "number" or jobid <= 0 then
    util.schedule(function()
      cb({ code = 1, stdout = "", stderr = "Failed to start job" })
    end)
  end
end

return M
