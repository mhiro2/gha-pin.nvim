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

  if vim.system then
    vim.system(cmd, { text = true, timeout = timeout }, function(obj)
      vim.schedule(function()
        cb({
          code = obj.code or 0,
          stdout = obj.stdout or "",
          stderr = obj.stderr or "",
        })
      end)
    end)
    return
  end

  -- Fallback: vim.fn.jobstart with timeout
  local stdout = {}
  local stderr = {}
  local timer = nil
  local timed_out = false
  local jobid = nil

  local function cleanup()
    if timer then
      timer:close()
      timer = nil
    end
  end

  local function schedule_result(code, out, err)
    cleanup()
    vim.schedule(function()
      cb({ code = code, stdout = out, stderr = err })
    end)
  end

  timer = vim.loop.new_timer()
  timer:start(timeout, 0, function()
    timed_out = true
    if type(jobid) == "number" and jobid > 0 then
      vim.fn.jobstop(jobid)
    end
    schedule_result(124, "", string.format("Command timed out after %d ms", timeout))
  end)

  jobid = vim.fn.jobstart(cmd, {
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
      if timed_out then
        return
      end
      schedule_result(code or 0, table.concat(stdout, "\n"), table.concat(stderr, "\n"))
    end,
  })

  if type(jobid) ~= "number" or jobid <= 0 then
    cleanup()
    vim.schedule(function()
      cb({ code = 1, stdout = "", stderr = "Failed to start job" })
    end)
  end
end

return M
