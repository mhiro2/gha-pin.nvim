local util = require("gha-pin.util")

local M = {}

M.VERSION = 2

local save_queue = {
  running = false,
  pending = false,
  ---@type GhaPinCache|nil
  cache = nil,
  ---@type fun(ok: boolean, err?: string)[]
  callbacks = {},
}

---@class GhaPinCacheEntry
---@field checked_at integer
---@field latest_tag string|nil
---@field latest_sha string|nil
---@field resolved_sha string|nil
---@field source string|nil
---@field pinned_map table<string, string>|nil
---@field published_at string|nil

---@class GhaPinCache
---@field version integer
---@field entries table<string, GhaPinCacheEntry>

---@return string
local function cache_dir()
  return vim.fn.stdpath("cache") .. "/gha-pin.nvim"
end

---@return string
local function cache_file()
  return cache_dir() .. "/cache.json"
end

---@param msg string
---@param level integer
local function schedule_notify(msg, level)
  -- `vim.notify` ultimately calls `nvim_echo`, which is disallowed in a fast
  -- event context (e.g. libuv callbacks). Defer to the main loop so writes
  -- triggered from `vim.uv.fs_*` callbacks do not crash on nightly Neovim.
  vim.schedule(function()
    vim.notify(msg, level)
  end)
end

---@return GhaPinCache
function M.load()
  local path = cache_file()
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then
    return { version = M.VERSION, entries = {} }
  end

  local ok2, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok2 or type(decoded) ~= "table" then
    if not ok2 then
      vim.notify("gha-pin.nvim: Failed to decode cache file, using empty cache", vim.log.levels.WARN)
    end
    return { version = M.VERSION, entries = {} }
  end

  if decoded.version ~= M.VERSION or type(decoded.entries) ~= "table" then
    return { version = M.VERSION, entries = {} }
  end
  return decoded
end

---@param cache GhaPinCache
---@param cb? fun(ok: boolean, err?: string)
local function save_once(cache, cb)
  local path = cache_file()
  local ok, encoded = pcall(vim.json.encode, cache)
  if not ok then
    vim.notify(("gha-pin.nvim: Failed to encode cache: %s"):format(tostring(encoded)), vim.log.levels.WARN)
    if cb then
      cb(false, tostring(encoded))
    end
    return
  end

  local fs = vim.uv

  -- Write to temporary file first (atomic write pattern). The cache
  -- directory is created in `M.save` on the main loop, so we do not
  -- touch the filesystem synchronously from here (this function can be
  -- re-entered from a libuv callback during queue drain, which is a
  -- fast event context where `vim.fn.*` calls are disallowed).
  local tmp_path = path .. ".tmp"
  fs.fs_open(tmp_path, "w", 438, function(open_err, fd)
    if open_err or not fd then
      schedule_notify(("gha-pin.nvim: Failed to open cache file: %s"):format(tostring(open_err)), vim.log.levels.WARN)
      if cb then
        cb(false, tostring(open_err))
      end
      return
    end

    fs.fs_write(fd, encoded, -1, function(write_err)
      if write_err then
        fs.fs_close(fd, function()
          schedule_notify(("gha-pin.nvim: Failed to write cache: %s"):format(tostring(write_err)), vim.log.levels.WARN)
          if cb then
            cb(false, tostring(write_err))
          end
        end)
        return
      end

      fs.fs_close(fd, function(close_err)
        if close_err then
          schedule_notify(
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
            schedule_notify(
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
end

---@param callbacks fun(ok: boolean, err?: string)[]
---@param ok boolean
---@param err? string
local function run_callbacks(callbacks, ok, err)
  for _, f in ipairs(callbacks) do
    pcall(f, ok, err)
  end
end

local function flush_save_queue()
  if save_queue.running or not save_queue.pending or not save_queue.cache then
    return
  end

  save_queue.running = true
  save_queue.pending = false
  local cache = save_queue.cache
  local callbacks = save_queue.callbacks
  save_queue.callbacks = {}

  save_once(cache, function(ok, err)
    save_queue.running = false
    run_callbacks(callbacks, ok, err)
    if save_queue.pending then
      flush_save_queue()
    end
  end)
end

---@param cache GhaPinCache
---@param cb? fun(ok: boolean, err?: string)
function M.save(cache, cb)
  -- Create the cache directory here on the main loop. `vim.uv.fs_mkdir`
  -- is not recursive, and `vim.fn.mkdir` cannot be called from the
  -- libuv callbacks that re-drive the queue, so doing it once up front
  -- guarantees `save_once` only has to perform async writes.
  local mkdir_ok, mkdir_err = pcall(vim.fn.mkdir, cache_dir(), "p")
  if not mkdir_ok then
    vim.notify(("gha-pin.nvim: Failed to create cache directory: %s"):format(tostring(mkdir_err)), vim.log.levels.WARN)
    if cb then
      cb(false, tostring(mkdir_err))
    end
    return
  end

  save_queue.cache = cache
  save_queue.pending = true
  if cb then
    table.insert(save_queue.callbacks, cb)
  end
  flush_save_queue()
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
---@param source string|nil
---@param resolved_sha string|nil
function M.put(cache, key, latest_tag, latest_sha, published_at, source, resolved_sha)
  cache.version = M.VERSION
  cache.entries[key] = {
    checked_at = os.time(),
    latest_tag = latest_tag,
    latest_sha = latest_sha,
    resolved_sha = resolved_sha or latest_sha,
    source = source,
    published_at = published_at,
  }
end

function M.clear()
  local path = cache_file()
  pcall(vim.fn.delete, path)
  util.notify("Cache cleared: " .. path)
end

return M
