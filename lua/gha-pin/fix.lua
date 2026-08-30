local M = {}

---@class GhaPinTextEdit
---@field lnum integer 0-based
---@field col_start integer 0-based (inclusive)
---@field col_end integer 0-based (exclusive)
---@field old_text string Text expected at the edit range
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
      old_text = ref.sha,
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
      old_text = ref.raw:sub(comment.col_start + 1, comment.col_end),
      new_text = ("# %s"):format(tag.tag_with_v),
      kind = "comment",
    })
  end

  return edits
end

---@class GhaPinPreparedEdits
---@field changedtick integer
---@field edits GhaPinTextEdit[]
---@field empty boolean
---@field start_row integer|nil
---@field start_col integer|nil
---@field end_row integer|nil
---@field end_col integer|nil
---@field replacement string[]|nil

---@param bufnr integer
---@return boolean ok
---@return string|nil err
local function validate_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "buffer is no longer valid"
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return false, "buffer is no longer loaded"
  end
  if not vim.bo[bufnr].modifiable then
    return false, "buffer is not modifiable"
  end
  return true, nil
end

---@param bufnr integer
---@param edits GhaPinTextEdit[]
---@return table<integer, string>|nil lines
---@return string|nil err
local function validate_slices(bufnr, edits)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local lines = {}
  for _, edit in ipairs(edits) do
    if edit.lnum >= line_count then
      return nil, ("edit line %d is outside the buffer"):format(edit.lnum + 1)
    end
    local line = lines[edit.lnum]
    if line == nil then
      line = vim.api.nvim_buf_get_lines(bufnr, edit.lnum, edit.lnum + 1, true)[1]
      lines[edit.lnum] = line
    end
    if edit.col_end > #line then
      return nil, ("edit range on line %d is outside the buffer"):format(edit.lnum + 1)
    end
    if line:sub(edit.col_start + 1, edit.col_end) ~= edit.old_text then
      return nil, ("buffer contents changed at line %d"):format(edit.lnum + 1)
    end
  end
  return lines, nil
end

---@param bufnr integer
---@param edits GhaPinTextEdit[]
---@return GhaPinPreparedEdits|nil plan
---@return string|nil err
local function prepare_edits(bufnr, edits)
  local ready, ready_err = validate_buffer(bufnr)
  if not ready then
    return nil, ready_err
  end

  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)

  if #edits == 0 then
    return { changedtick = changedtick, edits = {}, empty = true }, nil
  end

  local ordered = {}
  for i, e in ipairs(edits) do
    if
      type(e.lnum) ~= "number"
      or e.lnum % 1 ~= 0
      or e.lnum < 0
      or type(e.col_start) ~= "number"
      or e.col_start % 1 ~= 0
      or e.col_start < 0
      or type(e.col_end) ~= "number"
      or e.col_end % 1 ~= 0
      or e.col_end < e.col_start
      or type(e.old_text) ~= "string"
      or type(e.new_text) ~= "string"
    then
      return nil, ("invalid edit at index %d"):format(i)
    end

    table.insert(ordered, {
      lnum = e.lnum,
      col_start = e.col_start,
      col_end = e.col_end,
      old_text = e.old_text,
      new_text = e.new_text,
      kind = e.kind,
    })
  end

  table.sort(ordered, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum > b.lnum
    end
    return a.col_start > b.col_start
  end)

  for i = 2, #ordered do
    local previous = ordered[i - 1]
    local current = ordered[i]
    if current.lnum == previous.lnum and current.col_end > previous.col_start then
      return nil, ("overlapping edits on line %d"):format(current.lnum + 1)
    end
  end

  local _, slice_err = validate_slices(bufnr, ordered)
  if slice_err then
    return nil, slice_err
  end

  local start_row = ordered[1].lnum
  local start_col = ordered[1].col_start
  local end_row = ordered[1].lnum
  local end_col = ordered[1].col_end
  for _, edit in ipairs(ordered) do
    if edit.lnum < start_row or (edit.lnum == start_row and edit.col_start < start_col) then
      start_row = edit.lnum
      start_col = edit.col_start
    end
    if edit.lnum > end_row or (edit.lnum == end_row and edit.col_end > end_col) then
      end_row = edit.lnum
      end_col = edit.col_end
    end
  end
  local replacement = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, true)
  if start_row == end_row then
    replacement[1] = replacement[1]:sub(start_col + 1, end_col)
  else
    replacement[1] = replacement[1]:sub(start_col + 1)
    replacement[#replacement] = replacement[#replacement]:sub(1, end_col)
  end

  for _, e in ipairs(ordered) do
    local index = e.lnum - start_row + 1
    local col_offset = index == 1 and start_col or 0
    local line = replacement[index]
    local col_start = e.col_start - col_offset
    local col_end = e.col_end - col_offset
    replacement[index] = line:sub(1, col_start) .. e.new_text .. line:sub(col_end + 1)
  end

  return {
    changedtick = changedtick,
    edits = ordered,
    empty = false,
    start_row = start_row,
    start_col = start_col,
    end_row = end_row,
    end_col = end_col,
    replacement = replacement,
  },
    nil
end

---@param bufnr integer
---@param plan GhaPinPreparedEdits
---@return boolean ok
---@return string|nil err
local function apply_prepared_edits(bufnr, plan)
  local ready, ready_err = validate_buffer(bufnr)
  if not ready then
    return false, ready_err
  end

  if plan.empty then
    return true, nil
  end

  local _, slice_err = validate_slices(bufnr, plan.edits)
  if slice_err then
    return false, slice_err
  end

  if vim.api.nvim_buf_get_changedtick(bufnr) ~= plan.changedtick then
    return false, "buffer changed before edits could be applied"
  end

  -- Mutate only the smallest fragment that contains every edit. This keeps
  -- extmarks outside the fragment stable while preserving all-or-none updates.
  local write_ok, write_err = pcall(
    vim.api.nvim_buf_set_text,
    bufnr,
    plan.start_row,
    plan.start_col,
    plan.end_row,
    plan.end_col,
    plan.replacement
  )
  if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
    local post_end_row = plan.start_row + #plan.replacement - 1
    local post_end_col = #plan.replacement == 1 and plan.start_col + #plan.replacement[1]
      or #plan.replacement[#plan.replacement]
    local actual = vim.api.nvim_buf_get_text(bufnr, plan.start_row, plan.start_col, post_end_row, post_end_col, {})
    if vim.deep_equal(actual, plan.replacement) then
      return true, nil
    end
  end
  if not write_ok then
    return false, tostring(write_err)
  end
  return false, "buffer contents did not match the requested edits"
end

---@param bufnr integer
---@param edits GhaPinTextEdit[]
---@return boolean ok
---@return string|nil err
function M.apply_edits(bufnr, edits)
  local plan, prepare_err = prepare_edits(bufnr, edits)
  if not plan then
    return false, prepare_err
  end
  return apply_prepared_edits(bufnr, plan)
end

-- Explicit test seam for state changes between preparation and mutation.
M._test = {
  prepare_edits = prepare_edits,
  apply_prepared_edits = apply_prepared_edits,
}

return M
