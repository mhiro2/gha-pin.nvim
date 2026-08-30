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

---@param timestamp any
---@return { year: integer, month: integer, day: integer, hour: integer, min: integer, sec: integer, tz_sign: string, tz_hour: integer, tz_min: integer }|nil
local function parse_iso8601_timestamp(timestamp)
  if type(timestamp) ~= "string" or timestamp == "" then
    return nil
  end

  local normalized = M.trim(timestamp)
  local datetime, timezone = normalized:match("^(.-)(Z)$")
  if not datetime then
    datetime, timezone = normalized:match("^(.-)([+-]%d%d:?%d%d)$")
  end
  if not datetime or not timezone then
    return nil
  end

  local base = datetime:match("^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)$")
  if not base then
    base = datetime:match("^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)%.%d+$")
  end
  if not base then
    return nil
  end

  local year, month, day, hour, min, sec = base:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)$")
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  hour, min, sec = tonumber(hour), tonumber(min), tonumber(sec)

  local tz_sign, tz_hour, tz_min
  if timezone == "Z" then
    tz_sign, tz_hour, tz_min = "+", 0, 0
  else
    tz_sign = timezone:sub(1, 1)
    tz_hour = tonumber(timezone:sub(2, 3))
    tz_min = tonumber(timezone:sub(-2))
  end

  if year < 1 or month < 1 or month > 12 or hour > 23 or min > 59 or sec > 59 or tz_hour > 23 or tz_min > 59 then
    return nil
  end

  local month_days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
  if leap then
    month_days[2] = 29
  end
  if day < 1 or day > month_days[month] then
    return nil
  end

  return {
    year = year,
    month = month,
    day = day,
    hour = hour,
    min = min,
    sec = sec,
    tz_sign = tz_sign,
    tz_hour = tz_hour,
    tz_min = tz_min,
  }
end

---@param timestamp string ISO 8601 timestamp from GitHub API (e.g., "2024-01-15T10:30:00Z").
--                      Supports: Z and +/-HH:MM offsets. Fractional seconds are ignored.
---@return integer age in seconds (0 for invalid timestamps)
function M.timestamp_age_seconds(timestamp)
  local parsed = parse_iso8601_timestamp(timestamp)
  if not parsed then
    return 0
  end

  -- Build a time table and get epoch (os.time interprets as local time)
  local local_epoch = os.time({
    year = parsed.year,
    month = parsed.month,
    day = parsed.day,
    hour = parsed.hour,
    min = parsed.min,
    sec = parsed.sec,
    isdst = false,
  })
  if type(local_epoch) ~= "number" then
    return 0
  end

  -- Get local timezone offset from UTC (in seconds) at the parsed timestamp.
  -- This avoids historical timezone/DST drift caused by using "now".
  local utc_table = os.date("!*t", local_epoch)
  local local_offset = os.difftime(local_epoch, os.time(utc_table))

  -- Convert local_epoch to epoch as if dt were UTC (not local)
  local utc_epoch = local_epoch + local_offset

  -- Apply the timestamp's timezone offset to convert to UTC
  -- e.g., 18:00+09:00 means 18:00 in JST, which is 09:00 UTC
  -- So we subtract the offset from the UTC-adjusted epoch
  local offset_seconds = parsed.tz_hour * 3600 + parsed.tz_min * 60
  if parsed.tz_sign == "+" then
    utc_epoch = utc_epoch - offset_seconds
  else
    utc_epoch = utc_epoch + offset_seconds
  end

  return os.time() - utc_epoch
end

---@param timestamp any
---@return boolean
function M.is_iso8601_timestamp(timestamp)
  return parse_iso8601_timestamp(timestamp) ~= nil
end

---@param msg string
---@param level? integer
function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "gha-pin.nvim" })
end

return M
