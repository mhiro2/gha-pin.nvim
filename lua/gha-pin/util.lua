local M = {}

---@param s string
---@return string
function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param s string
---@return string
function M.strip_quotes(s)
  local first = s:sub(1, 1)
  local last = s:sub(-1)
  if (first == "'" and last == "'") or (first == '"' and last == '"') then
    return s:sub(2, -2)
  end
  return s
end

---@param s string
---@return boolean
function M.contains_expr(s)
  return s:find("%${{%s*.-%s*}}") ~= nil
end

---@param s string
---@return string
function M.uri_encode_path_segment(s)
  -- Encode only what matters for GitHub path segments.
  -- We keep [A-Za-z0-9-_.~] and encode everything else.
  return (s:gsub("([^%w%-%._~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

---@param ms integer
---@param fn fun()
---@return integer timer_id
function M.defer(ms, fn)
  return vim.defer_fn(fn, ms)
end

---@param s string
---@return string
function M.sha7(s)
  if not s or s == "" then
    return ""
  end
  return s:sub(1, 7)
end

---@param timestamp string ISO 8601 timestamp from GitHub API (e.g., "2024-01-15T10:30:00Z").
--                      Supports format: YYYY-MM-DDTHH:MM:SS (milliseconds and timezone offset ignored).
---@return integer age in seconds (0 for invalid timestamps)
function M.timestamp_age_seconds(timestamp)
  -- Parse ISO 8601 timestamp
  local pattern = "^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)"
  local year, month, day, hour, min, sec = timestamp:match(pattern)
  if not year then
    return 0 -- Invalid timestamp, treat as old
  end

  local dt = {
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
  }

  local published_epoch = os.time(dt)
  local now = os.time()
  return now - published_epoch
end

---@param msg string
---@param level? integer
function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "gha-pin.nvim" })
end

return M
