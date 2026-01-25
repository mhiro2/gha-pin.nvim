local util = require("gha-pin.util")

local M = {}

---@class GhaPinCacheEntry
---@field checked_at integer
---@field latest_tag string|nil
---@field latest_sha string|nil
---@field pinned_map table<string, string>|nil
---@field published_at string|nil

---@class GhaPinCache
---@field version integer
---@field entries table<string, GhaPinCacheEntry>

local function cache_file()
  local dir = vim.fn.stdpath("cache") .. "/gha-pin.nvim"
  vim.fn.mkdir(dir, "p")
  return dir .. "/cache.json"
end

---@param s string
---@return any
local function json_decode(s)
  if vim.json and vim.json.decode then
    return vim.json.decode(s)
  end
  return vim.fn.json_decode(s)
end

---@param t any
---@return string
local function json_encode(t)
  if vim.json and vim.json.encode then
    return vim.json.encode(t)
  end
  return vim.fn.json_encode(t)
end

---@return GhaPinCache
function M.load()
  local path = cache_file()
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then
    return { version = 1, entries = {} }
  end

  local ok2, decoded = pcall(json_decode, table.concat(lines, "\n"))
  if not ok2 or type(decoded) ~= "table" then
    if not ok2 then
      vim.notify("gha-pin.nvim: Failed to decode cache file, using empty cache", vim.log.levels.WARN)
    end
    return { version = 1, entries = {} }
  end

  decoded.version = decoded.version or 1
  decoded.entries = decoded.entries or {}
  return decoded
end

---@param cache GhaPinCache
---@param cb? fun(ok: boolean, err?: string)
function M.save(cache, cb)
  local path = cache_file()
  local ok, encoded = pcall(json_encode, cache)
  if not ok then
    vim.notify(("gha-pin.nvim: Failed to encode cache: %s"):format(tostring(encoded)), vim.log.levels.WARN)
    if cb then
      cb(false, tostring(encoded))
    end
    return
  end

  local fs = vim.uv or vim.loop
  if not fs then
    -- Fallback to sync write if libuv is not available
    local ok2, err = pcall(vim.fn.writefile, { encoded }, path)
    if not ok2 then
      vim.notify(("gha-pin.nvim: Failed to write cache: %s"):format(tostring(err)), vim.log.levels.WARN)
    end
    if cb then
      cb(ok2, ok2 and nil or tostring(err))
    end
    return
  end

  local dir = vim.fn.stdpath("cache") .. "/gha-pin.nvim"

  -- Ensure directory exists (async mkdir)
  fs.fs_mkdir(dir, 448, function(mkdir_err)
    if mkdir_err and mkdir_err:match("EEXIST") == nil then
      vim.notify(
        ("gha-pin.nvim: Failed to create cache directory: %s"):format(tostring(mkdir_err)),
        vim.log.levels.WARN
      )
      if cb then
        cb(false, tostring(mkdir_err))
      end
      return
    end

    -- Write to temporary file first (atomic write pattern)
    local tmp_path = path .. ".tmp"
    fs.fs_open(tmp_path, "w", 438, function(open_err, fd)
      if open_err or not fd then
        vim.notify(("gha-pin.nvim: Failed to open cache file: %s"):format(tostring(open_err)), vim.log.levels.WARN)
        if cb then
          cb(false, tostring(open_err))
        end
        return
      end

      fs.fs_write(fd, encoded, -1, function(write_err)
        if write_err then
          fs.fs_close(fd, function()
            vim.notify(("gha-pin.nvim: Failed to write cache: %s"):format(tostring(write_err)), vim.log.levels.WARN)
            if cb then
              cb(false, tostring(write_err))
            end
          end)
          return
        end

        fs.fs_close(fd, function(close_err)
          if close_err then
            vim.notify(
              ("gha-pin.nvim: Failed to close cache file: %s"):format(tostring(close_err)),
              vim.log.levels.WARN
            )
            if cb then
              cb(false, tostring(close_err))
            end
            return
          end

          -- Atomic rename from temp to actual path
          fs.fs_rename(tmp_path, path, function(rename_err)
            if rename_err then
              vim.notify(
                ("gha-pin.nvim: Failed to rename cache file: %s"):format(tostring(rename_err)),
                vim.log.levels.WARN
              )
              if cb then
                cb(false, tostring(rename_err))
              end
              return
            end
            if cb then
              cb(true)
            end
          end)
        end)
      end)
    end)
  end)
end

---@param host string
---@param owner string
---@param repo string
---@return string
function M.key(host, owner, repo)
  return host .. "/" .. owner .. "/" .. repo
end

---@param cache GhaPinCache
---@param key string
---@param ttl_seconds integer
---@return GhaPinCacheEntry|nil
function M.get_if_fresh(cache, key, ttl_seconds)
  local entry = cache.entries[key]
  if not entry then
    return nil
  end
  local now = os.time()
  if not entry.checked_at then
    return nil
  end
  if now - entry.checked_at > ttl_seconds then
    return nil
  end
  return entry
end

---@param cache GhaPinCache
---@param key string
---@param latest_tag string|nil
---@param latest_sha string|nil
---@param published_at string|nil
function M.put(cache, key, latest_tag, latest_sha, published_at)
  cache.entries[key] = {
    checked_at = os.time(),
    latest_tag = latest_tag,
    latest_sha = latest_sha,
    published_at = published_at,
  }
end

function M.clear()
  local path = cache_file()
  pcall(vim.fn.delete, path)
  util.notify("Cache cleared: " .. path)
end

return M
