local util = require("gha-pin.util")

local M = {}

---@class GhaPinUsesRef
---@field lnum integer 0-based
---@field col_start integer 0-based (inclusive)
---@field col_end integer 0-based (exclusive)
---@field raw string
---@field uses string
---@field owner string
---@field repo string
---@field path string|nil
---@field sha string

local SHA40 = "%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x"

---@param line string
---@return integer|nil col_start
---@return integer|nil col_end
---@return string|nil uses_token
local function extract_uses_token(line)
  -- best-effort: find `uses:` and take the next token until whitespace/comment
  -- supports quoted values (single/double) in a simple way
  local match_start, match_end = line:find("%f[%w]uses:%s*")
  if not match_start or not match_end then
    return nil, nil, nil
  end

  local after = line:sub(match_start)
  local m = after:match("^uses:%s*(.+)$")
  if not m then
    return nil, nil, nil
  end

  -- strip inline comment (naive; ok for MVP)
  local without_comment = m:gsub("%s+#.*$", "")
  local raw_token = util.trim(without_comment)
  if raw_token == "" then
    return nil, nil, nil
  end

  local token = raw_token
  local col_start = match_end -- 0-based: (match_end+1)-1
  local first = raw_token:sub(1, 1)
  local last = raw_token:sub(-1)
  if (first == "'" and last == "'") or (first == '"' and last == '"') then
    token = raw_token:sub(2, -2)
    col_start = col_start + 1 -- skip the opening quote
  end

  local col_end = col_start + #token
  return col_start, col_end, token
end

---@param uses string
---@return string|nil owner
---@return string|nil repo
---@return string|nil path
---@return string|nil sha
local function parse_uses(uses)
  if uses:match("^%./") then
    return nil, nil, nil, nil
  end
  if uses:match("^docker://") then
    return nil, nil, nil, nil
  end
  if util.contains_expr(uses) then
    return nil, nil, nil, nil
  end

  -- owner/repo/path@sha40 OR owner/repo@sha40
  local left, sha = uses:match("^(.-)@(" .. SHA40 .. ")$")
  if not left or not sha then
    return nil, nil, nil, nil
  end

  local owner, rest = left:match("^([^/]+)/(.+)$")
  if not owner or not rest then
    return nil, nil, nil, nil
  end

  local repo, path = rest:match("^([^/]+)/(.+)$")
  if not repo then
    -- no path
    repo = rest
    path = nil
  end

  return owner, repo, path, sha
end

---@param lines string[]
---@return GhaPinUsesRef[]
function M.parse_lines(lines)
  ---@type GhaPinUsesRef[]
  local out = {}
  for i, line in ipairs(lines) do
    local col_start, col_end, token = extract_uses_token(line)
    if token then
      local owner, repo, path, sha = parse_uses(token)
      if owner and repo and sha then
        table.insert(out, {
          lnum = i - 1,
          col_start = col_start or 0,
          col_end = col_end or 0,
          raw = line,
          uses = token,
          owner = owner,
          repo = repo,
          path = path,
          sha = sha,
        })
      end
    end
  end
  return out
end

---@param bufnr integer
---@return GhaPinUsesRef[]
function M.parse_buf(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return M.parse_lines(lines)
end

return M
