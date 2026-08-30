local M = {}

---@class GhaPinTextEdit
---@field lnum integer 0-based
---@field col_start integer 0-based (inclusive)
---@field col_end integer 0-based (exclusive)
---@field new_text string
---@field kind '"sha"'|'"comment"'|nil

---@param uses string
---@return integer|nil sha_start_in_token 0-based
local function sha_start_in_token(uses)
  local at = uses:find("@", 1, true)
  if not at then
    return nil
  end
  return at -- 1-based '@' position => 0-based sha start
end

local VERSION_CANDIDATE = "[0-9][0-9A-Za-z._+%-]*"

---@param value string
---@return boolean
local function is_dotted_numeric(value)
  return value:match("^[0-9][0-9.]*$") ~= nil and value:sub(-1) ~= "." and value:find("..", 1, true) == nil
end

---@param identifiers string
---@return boolean
local function is_semver_identifier_list(identifiers)
  if identifiers == "" or identifiers:sub(1, 1) == "." or identifiers:sub(-1) == "." then
    return false
  end
  if identifiers:find("..", 1, true) then
    return false
  end

  for identifier in identifiers:gmatch("[^.]+") do
    if
      identifier:match("^[0-9A-Za-z]$") == nil
      and identifier:match("^[0-9A-Za-z][0-9A-Za-z-]*[0-9A-Za-z]$") == nil
    then
      return false
    end
  end
  return true
end

---@param version string
---@return boolean
local function is_extended_semver(version)
  local core, suffix = version:match("^([0-9]+%.[0-9]+%.[0-9]+)(.*)$")
  if not core or suffix == "" then
    return false
  end

  local prerelease = nil
  local build = nil
  if suffix:sub(1, 1) == "-" then
    local plus = suffix:find("+", 2, true)
    if plus then
      prerelease = suffix:sub(2, plus - 1)
      build = suffix:sub(plus + 1)
    else
      prerelease = suffix:sub(2)
    end
  elseif suffix:sub(1, 1) == "+" then
    build = suffix:sub(2)
  else
    return false
  end

  return (not prerelease or is_semver_identifier_list(prerelease)) and (not build or is_semver_identifier_list(build))
end

---@param version string
---@return boolean
local function is_version_token(version)
  return is_dotted_numeric(version) or is_extended_semver(version)
end

---@class GhaPinVersionTag
---@field version string Version without the leading `v`.
---@field tag_with_v string Normalized tag for a managed comment.

---@param latest_tag string|nil
---@return GhaPinVersionTag|nil
function M.version_tag(latest_tag)
  if type(latest_tag) ~= "string" or latest_tag == "" then
    return nil
  end

  local version = latest_tag:match("^v(.+)$") or latest_tag
  if not is_version_token(version) then
    return nil
  end
  return { version = version, tag_with_v = "v" .. version }
end

---@class GhaPinVersionComment
---@field col_start integer 0-based (inclusive)
---@field col_end integer 0-based (exclusive)
---@field version string Version without the leading `v`.

---@param ref GhaPinUsesRef
---@return GhaPinVersionComment|nil
function M.version_comment(ref)
  if not ref.raw then
    return nil
  end

  local after_token = ref.raw:sub(ref.col_end + 1)
  local hash = after_token:find("#", 1, true)
  if not hash then
    return nil
  end

  -- The only text allowed between the parsed scalar and its YAML comment is
  -- the closing quote (for a quoted `uses` value) plus whitespace. This keeps
  -- us from interpreting `# v...` embedded in another scalar as metadata.
  local before_hash = after_token:sub(1, hash - 1)
  if before_hash:match("^['\"]?%s*$") == nil then
    return nil
  end

  local comment = after_token:sub(hash)
  local marker_prefix, candidate = comment:match("^(#%s+v%s*)(" .. VERSION_CANDIDATE .. ")")
  if not marker_prefix or not candidate then
    return nil
  end

  -- A trailing separator belongs to the user's prose. Internal text is kept in
  -- the candidate so ambiguous comments such as `# v2-factor` fail the strict
  -- grammar instead of being treated as a managed `# v2` marker.
  local version = candidate:gsub("[._+%-]+$", "")
  if not is_version_token(version) then
    return nil
  end
  local marker_end = #marker_prefix + #version

  local col_start = ref.col_end + hash - 1
  return {
    col_start = col_start,
    col_end = col_start + marker_end,
    version = version,
  }
end

---@param ref GhaPinUsesRef
---@param latest_sha string
---@param latest_tag string|nil
---@return GhaPinTextEdit[]
function M.edit_for_ref(ref, latest_sha, latest_tag)
  local edits = {}

  -- Edit SHA portion
  local start_in_token = sha_start_in_token(ref.uses)
  if start_in_token and ref.sha ~= latest_sha then
    local col_start = ref.col_start + start_in_token
    local col_end = col_start + 40
    table.insert(edits, {
      lnum = ref.lnum,
      col_start = col_start,
      col_end = col_end,
      new_text = latest_sha,
      kind = "sha",
    })
  end

  -- Only an unambiguous, version-shaped `# v...` marker is managed. Ordinary
  -- comments such as `# verify provenance` must never be rewritten.
  local tag = M.version_tag(latest_tag)
  local comment = M.version_comment(ref)
  if tag and comment and comment.version ~= tag.version then
    table.insert(edits, {
      lnum = ref.lnum,
      col_start = comment.col_start,
      col_end = comment.col_end,
      new_text = ("# %s"):format(tag.tag_with_v),
      kind = "comment",
    })
  end

  return edits
end

---@param bufnr integer
---@param edits GhaPinTextEdit[]
function M.apply_edits(bufnr, edits)
  table.sort(edits, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum > b.lnum
    end
    return a.col_start > b.col_start
  end)

  for _, e in ipairs(edits) do
    vim.api.nvim_buf_set_text(bufnr, e.lnum, e.col_start, e.lnum, e.col_end, { e.new_text })
  end
end

return M
