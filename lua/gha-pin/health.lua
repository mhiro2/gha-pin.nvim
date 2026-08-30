local health = vim.health
local nvim_version = require("gha-pin.version")

local M = {}

---@class GhaPinHealthCmdResult
---@field code integer
---@field stdout string
---@field stderr string
---@field timeout boolean|nil

---@param cmd string[]
---@param timeout_ms integer
---@return GhaPinHealthCmdResult
local function run_cmd(cmd, timeout_ms)
  local obj = vim.system(cmd, { text = true, timeout = timeout_ms }):wait()
  return {
    code = obj.code or 0,
    stdout = obj.stdout or "",
    stderr = obj.stderr or "",
    timeout = obj.code == 124,
  }
end

local function check_neovim_version()
  health.start("Neovim version")
  local version = vim.version()
  if nvim_version.is_supported(version) then
    health.ok(string.format("Neovim %s is supported", nvim_version.format(version)))
  else
    health.error(
      string.format(
        "Neovim %s is not supported. Required: >= %s",
        nvim_version.format(version),
        nvim_version.format(nvim_version.minimum)
      )
    )
  end
end

local function check_executables()
  health.start("Executables")

  local gh_available = vim.fn.executable("gh") == 1
  local curl_available = vim.fn.executable("curl") == 1

  if gh_available then
    health.ok("`gh` is available (recommended)")
  else
    health.warn("`gh` is not available")
  end

  if curl_available then
    health.ok("`curl` is available")
  else
    if not gh_available then
      health.error("Neither `gh` nor `curl` is available. At least one is required.")
    else
      health.info("`curl` is not available (optional, `gh` is available)")
    end
  end
end

local function check_authentication()
  health.start("Authentication")

  local gh_available = vim.fn.executable("gh") == 1
  local token_env = vim.env.GITHUB_TOKEN

  if gh_available then
    local res = run_cmd({ "gh", "auth", "status" }, 1500)
    if res.timeout then
      health.info("Timed out while checking `gh` authentication status")
    elseif res.code == 0 then
      health.ok("`gh` is authenticated")
    else
      health.warn("`gh` may not be authenticated. Run `gh auth login` if needed.")
    end
  end

  if token_env and token_env ~= "" then
    health.ok("`GITHUB_TOKEN` environment variable is set")
  else
    if not gh_available then
      health.warn("`GITHUB_TOKEN` environment variable is not set (required if `gh` is not available)")
    else
      health.info("`GITHUB_TOKEN` environment variable is not set (optional when `gh` is available)")
    end
  end
end

local function check_configuration()
  health.start("Configuration")

  local ok = pcall(require, "gha-pin")
  if not ok then
    health.error("Failed to load gha-pin module")
    return
  end

  health.info("Configuration is checked at runtime. Use `:GhaPinCheck` to test functionality.")
end

function M.check()
  health.start("gha-pin.nvim")

  check_neovim_version()
  check_executables()
  check_authentication()
  check_configuration()
end

return M
