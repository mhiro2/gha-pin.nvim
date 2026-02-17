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
--                      Supports: Z and +/-HH:MM offsets. Fractional seconds are ignored.
---@return integer age in seconds (0 for invalid timestamps)
function M.timestamp_age_seconds(timestamp)
  if type(timestamp) ~= "string" or timestamp == "" then
    return 0
  end

  local normalized = M.trim(timestamp)
  -- Drop fractional seconds
  normalized = normalized:gsub("%.%d+", "")

  -- Extract and strip timezone offset
  local tz_sign, tz_hour, tz_min
  local is_z = normalized:sub(-1) == "Z"
  if is_z then
    tz_sign, tz_hour, tz_min = "+", "00", "00"
    normalized = normalized:sub(1, -2)
  else
    -- Match timezone offset: +HH:MM or +HHMM or -HH:MM or -HHMM
    local tz_match = normalized:match("[+-]%d%d:?%d%d$")
    if not tz_match then
      return 0 -- No valid timezone info
    end
    -- Parse the timezone components
    tz_sign = tz_match:sub(1, 1)
    tz_hour = tz_match:sub(2, 3)
    tz_min = tz_match:sub(-2)
    normalized = normalized:sub(1, -(#tz_match + 1))
  end

  -- Parse the datetime part
  local year, month, day, hour, min, sec = normalized:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)$")
  if not year then
    return 0
  end

  -- Build a time table and get epoch (os.time interprets as local time)
  local dt = {
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
    isdst = false,
  }
  local local_epoch = os.time(dt)

  -- Get local timezone offset from UTC (in seconds) at the parsed timestamp.
  -- This avoids historical timezone/DST drift caused by using "now".
  local utc_table = os.date("!*t", local_epoch)
  local local_offset = os.difftime(local_epoch, os.time(utc_table))

  -- Convert local_epoch to epoch as if dt were UTC (not local)
  local utc_epoch = local_epoch + local_offset

  -- Apply the timestamp's timezone offset to convert to UTC
  -- e.g., 18:00+09:00 means 18:00 in JST, which is 09:00 UTC
  -- So we subtract the offset from the UTC-adjusted epoch
  local offset_seconds = tonumber(tz_hour) * 3600 + tonumber(tz_min) * 60
  if tz_sign == "+" then
    utc_epoch = utc_epoch - offset_seconds
  else
    utc_epoch = utc_epoch + offset_seconds
  end

  return os.time() - utc_epoch
end

---@param msg string
---@param level? integer
function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "gha-pin.nvim" })
end

return M
