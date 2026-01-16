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
    return { version = 1, entries = {} }
  end

  decoded.version = decoded.version or 1
  decoded.entries = decoded.entries or {}
  return decoded
end

---@param cache GhaPinCache
function M.save(cache)
  local path = cache_file()
  local encoded = json_encode(cache)
  vim.fn.writefile({ encoded }, path)
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
