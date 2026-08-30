local MiniTest = require("mini.test")
local expect = MiniTest.expect

local function load_util_fresh()
  package.loaded["gha-pin.util"] = nil
  return require("gha-pin.util")
end

local T = MiniTest.new_set()

---@param epoch integer
---@return string
local function iso8601_utc(epoch)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end

---@param tz string
---@param fn fun()
local function with_tz(tz, fn)
  local original_tz = vim.env.TZ
  vim.env.TZ = tz
  local ok, err = pcall(fn)
  vim.env.TZ = original_tz
  if not ok then
    error(err)
  end
end

T["timestamp_age_seconds: handles Z and timezone offsets as UTC"] = function()
  local util = load_util_fresh()
  local now = os.time()
  local target = now - 3600
  local age_from_z = util.timestamp_age_seconds(iso8601_utc(target))
  expect.equality(math.abs(age_from_z - 3600) <= 2, true)

  -- Build an equivalent +09:00 timestamp for the same target epoch.
  local jst = os.date("!*t", target + (9 * 60 * 60))
  local plus_0900 = ("%04d-%02d-%02dT%02d:%02d:%02d+09:00"):format(
    jst.year,
    jst.month,
    jst.day,
    jst.hour,
    jst.min,
    jst.sec
  )
  local age_from_offset = util.timestamp_age_seconds(plus_0900)
  expect.equality(math.abs(age_from_offset - 3600) <= 2, true)

  local z_with_fraction = iso8601_utc(target):gsub("Z$", ".999Z")
  local age_from_fraction = util.timestamp_age_seconds(z_with_fraction)
  expect.equality(math.abs(age_from_fraction - 3600) <= 2, true)
end

T["timestamp_age_seconds: invalid formats return 0"] = function()
  local util = load_util_fresh()
  expect.equality(util.timestamp_age_seconds(""), 0)
  expect.equality(util.timestamp_age_seconds("2024-01-01T00:00:00"), 0)
  expect.equality(util.timestamp_age_seconds("not-a-timestamp"), 0)
  expect.equality(util.timestamp_age_seconds("2000.999-01-01T00:00:00Z"), 0)
  expect.equality(util.timestamp_age_seconds("2024-01-15T10:30:00.123.456Z"), 0)
end

T["is_iso8601_timestamp: validates release timestamps"] = function()
  local util = load_util_fresh()
  expect.equality(util.is_iso8601_timestamp("2024-02-29T10:30:00Z"), true)
  expect.equality(util.is_iso8601_timestamp("2024-01-15T10:30:00.123+09:00"), true)
  expect.equality(util.is_iso8601_timestamp("2023-02-29T10:30:00Z"), false)
  expect.equality(util.is_iso8601_timestamp("2024-13-15T10:30:00Z"), false)
  expect.equality(util.is_iso8601_timestamp("not-a-timestamp"), false)
  expect.equality(util.is_iso8601_timestamp("2000.999-01-01T00:00:00Z"), false)
  expect.equality(util.is_iso8601_timestamp("2024-01-15T10:30:00.123.456Z"), false)
  expect.equality(util.is_iso8601_timestamp(nil), false)
end

T["timestamp_age_seconds: returns negative age for future timestamps"] = function()
  local util = load_util_fresh()
  local future = iso8601_utc(os.time() + 3600)
  local age = util.timestamp_age_seconds(future)
  expect.equality(age <= -3598 and age >= -3602, true)
end

T["timestamp_age_seconds: handles historical timezone offset changes"] = function()
  local util = load_util_fresh()
  local timestamp = "2012-01-15T12:00:00Z"
  local expected_epoch

  with_tz("UTC", function()
    expected_epoch = os.time({
      year = 2012,
      month = 1,
      day = 15,
      hour = 12,
      min = 0,
      sec = 0,
      isdst = false,
    })
  end)

  with_tz("Europe/Moscow", function()
    local age = util.timestamp_age_seconds(timestamp)
    local parsed_epoch = os.time() - age
    expect.equality(math.abs(parsed_epoch - expected_epoch) <= 2, true)
  end)
end

return T
