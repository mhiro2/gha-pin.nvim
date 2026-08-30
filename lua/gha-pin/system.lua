local M = {}

local uv = vim.uv or vim.loop

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
  local finished = false
  local timeout_requested = false
  local jobid = nil

  local function close_timer()
    local current = timer
    timer = nil
    if current then
      pcall(current.stop, current)
      pcall(current.close, current)
    end
  end

  local function finish(code, out, err)
    if finished then
      return
    end
    finished = true
    close_timer()
    vim.schedule(function()
      cb({ code = code, stdout = out, stderr = err })
    end)
  end

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
      if timeout_requested then
        return
      end
      finish(code or 0, table.concat(stdout, "\n"), table.concat(stderr, "\n"))
    end,
  })

  if type(jobid) ~= "number" or jobid <= 0 then
    finish(1, "", "Failed to start job")
    return
  end

  timer = uv.new_timer()
  if not timer then
    pcall(vim.fn.jobstop, jobid)
    finish(1, "", "Failed to create timeout timer")
    return
  end

  timer:start(timeout, 0, function()
    if finished or timeout_requested then
      return
    end

    -- libuv timer callbacks run in a fast-event context. Reserve the timeout
    -- result here, then schedule all vim.fn calls back onto the main loop.
    timeout_requested = true
    vim.schedule(function()
      if finished then
        return
      end
      if type(jobid) == "number" and jobid > 0 then
        pcall(vim.fn.jobstop, jobid)
      end
      finish(124, "", string.format("Command timed out after %d ms", timeout))
    end)
  end)
end

return M
