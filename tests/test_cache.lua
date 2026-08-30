local MiniTest = require("mini.test")
local expect = MiniTest.expect

local cache = require("gha-pin.cache")

local T = MiniTest.new_set()

---@param entries table<string, any>
---@return integer
local function count_entries(entries)
  local n = 0
  for _ in pairs(entries or {}) do
    n = n + 1
  end
  return n
end

---@param fn fun()
local function with_clean_cache(fn)
  cache.clear()
  local ok, err = pcall(fn)
  cache.clear()
  if not ok then
    error(err)
  end
end

T["save: serializes rapid writes and persists complete snapshot"] = function()
  with_clean_cache(function()
    local c = { version = cache.VERSION, entries = {} }
    local pending = 0
    local failed = 0
    local total = 30

    for i = 1, total do
      local key = ("https://api.github.com/o/repo-%d"):format(i)
      local nibble = string.format("%x", i % 16)
      local sha = string.rep(nibble, 40)
      cache.put(c, key, ("v%d"):format(i), sha, nil, "release", sha)

      pending = pending + 1
      cache.save(c, function(ok, _err)
        if not ok then
          failed = failed + 1
        end
        pending = pending - 1
      end)
    end

    local done = vim.wait(5000, function()
      return pending == 0
    end, 10)
    expect.equality(done, true)
    expect.equality(failed, 0)

    local loaded = cache.load()
    expect.equality(count_entries(loaded.entries), total)
    local last_key = ("https://api.github.com/o/repo-%d"):format(total)
    expect.equality(loaded.entries[last_key].latest_tag, ("v%d"):format(total))
  end)
end

T["save: latest requested snapshot wins"] = function()
  with_clean_cache(function()
    local c1 = { version = cache.VERSION, entries = {} }
    local c2 = { version = cache.VERSION, entries = {} }

    cache.put(c1, "https://api.github.com/o/repo-a", "v1", string.rep("a", 40), nil, "tags", string.rep("a", 40))
    cache.put(c2, "https://api.github.com/o/repo-b", "v2", string.rep("b", 40), nil, "tags", string.rep("b", 40))

    local pending = 0
    pending = pending + 1
    cache.save(c1, function()
      pending = pending - 1
    end)
    pending = pending + 1
    cache.save(c2, function()
      pending = pending - 1
    end)

    local done = vim.wait(3000, function()
      return pending == 0
    end, 10)
    expect.equality(done, true)

    local loaded = cache.load()
    expect.equality(loaded.entries["https://api.github.com/o/repo-a"], nil)
    expect.equality(loaded.entries["https://api.github.com/o/repo-b"].latest_tag, "v2")
  end)
end

T["load: invalidates entries from an older policy schema"] = function()
  with_clean_cache(function()
    local old = {
      version = 1,
      entries = {
        ["https://api.github.com/o/repo"] = {
          checked_at = os.time(),
          latest_tag = "v1",
          latest_sha = string.rep("a", 40),
        },
      },
    }

    local saved = false
    cache.save(old, function(ok)
      saved = ok
    end)
    expect.equality(
      vim.wait(3000, function()
        return saved
      end, 10),
      true
    )

    local loaded = cache.load()
    expect.equality(loaded.version, cache.VERSION)
    expect.equality(count_entries(loaded.entries), 0)
  end)
end

return T
