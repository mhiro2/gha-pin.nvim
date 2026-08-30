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
---@return 'sequence'|'mapping'|nil kind
---@return integer|nil value_start 0-based
local function uses_mapping_value_start(line)
  local patterns = {
    { kind = "sequence", pattern = "^ *%- +uses[ \t]*:[ \t]+" },
    { kind = "sequence", pattern = '^ *%- +"uses"[ \t]*:[ \t]+' },
    { kind = "sequence", pattern = "^ *%- +'uses'[ \t]*:[ \t]+" },
    { kind = "mapping", pattern = "^ *uses[ \t]*:[ \t]+" },
    { kind = "mapping", pattern = '^ *"uses"[ \t]*:[ \t]+' },
    { kind = "mapping", pattern = "^ *'uses'[ \t]*:[ \t]+" },
  }

  for _, candidate in ipairs(patterns) do
    local _, match_end = line:find(candidate.pattern)
    if match_end then
      return candidate.kind, match_end
    end
  end
  return nil, nil
end

---@param line string
---@return integer|nil col_start
---@return integer|nil col_end
---@return string|nil uses_token
local function extract_uses_token(line)
  -- Only accept an exact, plain `uses` mapping key in block style. In
  -- particular, do not find `uses:` inside another scalar or a similar key
  -- such as `foo-uses:`.
  local _kind, value_start = uses_mapping_value_start(line)
  if not value_start then
    return nil, nil, nil
  end

  local m = line:sub(value_start + 1)

  -- strip inline comment (naive; ok for now)
  local without_comment = m:gsub("%s+#.*$", "")
  local raw_token = util.trim(without_comment)
  if raw_token == "" then
    return nil, nil, nil
  end

  local token = raw_token
  local col_start = value_start
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

---@class GhaPinYamlContext
---@field key string
---@field indent integer

---@param line string
---@return integer|nil
local function leading_indent(line)
  local whitespace = line:match("^[ \t]*") or ""
  if whitespace:find("\t", 1, true) then
    -- Tabs are not valid YAML indentation. Ignoring the line is safer than
    -- guessing a column and accidentally treating scalar content as a key.
    return nil
  end
  return #whitespace
end

---@param line string
---@return boolean
local function is_blank_or_comment(line)
  return line:match("^%s*$") ~= nil or line:match("^%s*#") ~= nil
end

---@param line string
---@param indent integer
---@return string|nil key
---@return string|nil value
---@return integer|nil key_indent
local function mapping_header(line, indent)
  local body = line:sub(indent + 1)
  local key_indent = indent
  local sequence_spaces, sequence_body = body:match("^%-( +)(.*)$")
  if sequence_body then
    key_indent = indent + 1 + #sequence_spaces
    body = sequence_body
  end

  local key, value = body:match("^([%w_.-]+)[ \t]*:[ \t]*(.*)$")
  if not key then
    key, value = body:match('^"([^"]+)"[ \t]*:[ \t]*(.*)$')
  end
  if not key then
    key, value = body:match("^'([^']+)'[ \t]*:[ \t]*(.*)$")
  end
  if not key then
    return nil, nil, nil
  end
  return key, value, key_indent
end

---@param value string
---@return string
local function without_node_properties(value)
  local trimmed = util.trim(value)

  -- YAML node properties (tags and anchors) may precede any scalar style,
  -- e.g. `!!str |`, `&script |`, or `!custom >-`. Consume only complete,
  -- whitespace-delimited property tokens. Anything uncertain remains part of
  -- the value and is handled conservatively as a scalar below.
  while trimmed:sub(1, 1) == "!" or trimmed:sub(1, 1) == "&" do
    local token = trimmed:match("^(%S+)")
    if not token then
      break
    end
    trimmed = util.trim(trimmed:sub(#token + 1))
  end
  return trimmed
end

---@param text string
---@param quote "'"|'"'
---@param from integer
---@return boolean
local function closes_quote(text, quote, from)
  local i = from
  if quote == "'" then
    while i <= #text do
      if text:sub(i, i) == "'" then
        if text:sub(i + 1, i + 1) == "'" then
          i = i + 2
        else
          return true
        end
      else
        i = i + 1
      end
    end
    return false
  end

  local escaped = false
  while i <= #text do
    local char = text:sub(i, i)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char == '"' then
      return true
    end
    i = i + 1
  end
  return false
end

---@class GhaPinYamlFlowState
---@field depth integer
---@field quote "'"|'"'|nil

---@param text string
---@param state GhaPinYamlFlowState
local function scan_flow(text, state)
  local i = 1
  local escaped = false
  while i <= #text do
    local char = text:sub(i, i)
    if state.quote == "'" then
      if char == "'" then
        if text:sub(i + 1, i + 1) == "'" then
          i = i + 1
        else
          state.quote = nil
        end
      end
    elseif state.quote == '"' then
      if escaped then
        escaped = false
      elseif char == "\\" then
        escaped = true
      elseif char == '"' then
        state.quote = nil
      end
    elseif char == "#" then
      -- Treat any unquoted `#` as the start of a comment. Being conservative
      -- here can only extend the ignored flow region; it cannot create a Fix.
      return
    elseif char == "'" or char == '"' then
      state.quote = char
    elseif char == "{" or char == "[" then
      state.depth = state.depth + 1
    elseif char == "}" or char == "]" then
      state.depth = state.depth - 1
      if state.depth <= 0 then
        state.depth = 0
        state.quote = nil
        return
      end
    end
    i = i + 1
  end
end

---@param value string
---@return GhaPinYamlFlowState|nil
local function flow_state_for_node(value)
  local content = without_node_properties(value)
  local first = content:sub(1, 1)
  if first ~= "{" and first ~= "[" then
    return nil
  end

  local state = { depth = 0, quote = nil }
  scan_flow(content, state)
  return state
end

---@alias GhaPinYamlValueKind 'nested'|'block'|'quoted'|'plain'|'flow'

---@param value string
---@return GhaPinYamlValueKind kind
---@return "'"|'"'|nil quote
---@return GhaPinYamlFlowState|nil flow
local function mapping_value_kind(value)
  local content = without_node_properties(value)
  if content == "" or content:sub(1, 1) == "#" then
    return "nested", nil, nil
  end

  local first = content:sub(1, 1)
  if first == "|" or first == ">" then
    return "block", nil, nil
  end
  local flow = flow_state_for_node(value)
  if flow then
    return "flow", nil, flow
  end
  if first == "'" or first == '"' then
    if not closes_quote(content, first, 2) then
      return "quoted", first, nil
    end
  end

  -- Even a single-line scalar makes more deeply indented following lines
  -- ambiguous. Treat them as scalar continuation until a dedent rather than
  -- guessing that a `uses:`-looking line is a nested mapping.
  return "plain", nil, nil
end

---@param stack GhaPinYamlContext[]
---@return boolean
local function is_step_context(stack)
  local n = #stack
  if n < 2 or stack[n].key ~= "steps" then
    return false
  end

  -- Composite action: runs.steps[*].uses
  if stack[n - 1].key == "runs" and stack[n - 1].indent == 0 then
    return true
  end

  -- Workflow step: jobs.<job_id>.steps[*].uses
  return n >= 3 and stack[n - 2].key == "jobs" and stack[n - 2].indent == 0
end

---@param stack GhaPinYamlContext[]
---@return boolean
local function is_reusable_workflow_job_context(stack)
  local n = #stack
  return n >= 2 and stack[n - 1].key == "jobs" and stack[n - 1].indent == 0
end

---@param stack GhaPinYamlContext[]
---@param kind 'sequence'|'mapping'
---@return boolean
local function is_action_uses_context(stack, kind)
  if is_step_context(stack) then
    return true
  end

  -- Reusable workflow calls are mapping members of jobs.<job_id>. A sequence
  -- item at this depth is not a reusable-workflow `uses` field.
  return kind == "mapping" and is_reusable_workflow_job_context(stack)
end

---@class GhaPinYamlScalar
---@field kind 'block'|'plain'|'quoted'|'flow'
---@field indent integer Effective indentation of the scalar's mapping key.
---@field quote "'"|'"'|nil
---@field depth integer|nil

---@param lines string[]
---@return GhaPinUsesRef[]
function M.parse_lines(lines)
  ---@type GhaPinUsesRef[]
  local out = {}
  ---@type GhaPinYamlContext[]
  local stack = {}
  ---@type GhaPinYamlScalar|nil
  local scalar = nil

  for i, line in ipairs(lines) do
    local indent = leading_indent(line)
    local skip_line = indent == nil

    if scalar then
      if scalar.kind == "flow" then
        -- Flow collections are intentionally unsupported. Ignore every line
        -- until the matching closing delimiter, including nested collections
        -- and quoted strings which contain delimiter characters.
        skip_line = true
        local flow = { depth = scalar.depth or 1, quote = scalar.quote }
        scan_flow(line, flow)
        if flow.depth == 0 then
          scalar = nil
        else
          scalar.depth = flow.depth
          scalar.quote = flow.quote
        end
      elseif scalar.kind == "quoted" then
        -- A quoted flow scalar may span physical lines. Do not interpret any
        -- continuation line as YAML structure, even if it dedents or contains
        -- an exact-looking `uses:` key.
        skip_line = true
        if scalar.quote and closes_quote(line, scalar.quote, 1) then
          scalar = nil
        end
      elseif is_blank_or_comment(line) or not indent or indent > scalar.indent then
        -- Blank/comment-only or invalidly indented lines do not prove that a
        -- scalar ended. More deeply indented content belongs to a block scalar
        -- or may continue a plain scalar. Keep all of these regions fail-closed.
        skip_line = true
      else
        scalar = nil
        skip_line = false
      end
    end

    if not skip_line and is_blank_or_comment(line) then
      skip_line = true
    end

    if not skip_line then
      local body = line:sub(indent + 1)
      local sequence_entry = body:match("^%-[ \t]+") ~= nil
      local sequence_value = body:match("^%-[ \t]+(.*)$")
      local sequence_flow = sequence_value and flow_state_for_node(sequence_value) or nil

      -- A flow-style sequence item (`- { ... }` / `- [ ... ]`) is never an
      -- action candidate. If it spans lines, enter a fail-closed flow region.
      if sequence_flow then
        if sequence_flow.depth > 0 then
          scalar = {
            kind = "flow",
            indent = indent,
            quote = sequence_flow.quote,
            depth = sequence_flow.depth,
          }
        end
        skip_line = true
      end

      if not skip_line then
        while #stack > 0 do
          local top = stack[#stack]
          if top.indent < indent then
            break
          end
          -- YAML permits an indentationless block sequence as a mapping value:
          -- `steps:` followed by `- uses:` at the same indentation as `steps`.
          if top.indent == indent and top.key == "steps" and sequence_entry then
            break
          end
          table.remove(stack)
        end

        local kind = uses_mapping_value_start(line)
        if kind and is_action_uses_context(stack, kind) then
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

        local key, value, key_indent = mapping_header(line, indent)
        if key and value and key_indent then
          local value_kind, quote, flow = mapping_value_kind(value)
          if value_kind == "nested" then
            table.insert(stack, { key = key, indent = key_indent })
          elseif value_kind == "flow" then
            if flow and flow.depth > 0 then
              scalar = {
                kind = "flow",
                indent = key_indent,
                quote = flow.quote,
                depth = flow.depth,
              }
            end
          elseif value_kind == "block" or value_kind == "quoted" or value_kind == "plain" then
            scalar = { kind = value_kind, indent = key_indent, quote = quote }
          end
        end
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
