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

  -- Edit comment portion if latest_tag is available
  if latest_tag and ref.raw then
    -- Look for comment after the uses token (after ref.col_end)
    local after_token = ref.raw:sub(ref.col_end + 1)
    -- Match "# v<ver>" and "# v <ver>" (consume the version token so we replace it)
    local comment_match_start, comment_match_end = after_token:find("#%s*v%s*[^%s]+")
    if comment_match_start then
      -- Found a comment like "# v1.2.3" or "# v 1.2.3"
      -- NOTE: comment_match_start/end are 1-based (inclusive) indices inside `after_token`.
      -- `after_token` starts at 1-based index (ref.col_end + 1) in `ref.raw`.
      -- Convert to 0-based (for nvim_buf_set_text):
      --   start0 = (ref.col_end + 1 + comment_match_start) - 1
      --         = ref.col_end + comment_match_start - 1
      -- And end0 (exclusive):
      --   end0 = (ref.col_end + 1 + comment_match_end)
      --        = ref.col_end + comment_match_end
      local line_len = #ref.raw
      local comment_start = ref.col_end + comment_match_start - 1
      local comment_end = math.min(ref.col_end + comment_match_end, line_len)

      -- Normalize tag so we don't end up with "# vv1.2.3"
      local tag = tostring(latest_tag)
      local tag_with_v = tag:match("^v") and tag or ("v" .. tag)
      local want_version = tag_with_v:match("^v(.+)$") or tag_with_v

      -- Update only the matched "# v..." chunk
      local matched = after_token:sub(comment_match_start, comment_match_end)
      local have_version = matched:match("#%s*v%s*([^%s]+)")
      if have_version ~= want_version then
        table.insert(edits, {
          lnum = ref.lnum,
          col_start = comment_start,
          col_end = comment_end,
          new_text = ("# %s"):format(tag_with_v),
          kind = "comment",
        })
      end
    end
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
