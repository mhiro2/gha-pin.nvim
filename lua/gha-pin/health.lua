local health = vim.health

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
  if vim.system then
    local obj = vim.system(cmd, { text = true }):wait(timeout_ms)
    if not obj then
      return { code = -1, stdout = "", stderr = "Timed out", timeout = true }
    end
    return {
      code = obj.code or 0,
      stdout = obj.stdout or "",
      stderr = obj.stderr or "",
    }
  end

  local stdout = {}
  local stderr = {}
  local jobid = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if type(data) == "table" then
        for _, v in ipairs(data) do
          if v ~= "" then
            table.insert(stdout, v)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if type(data) == "table" then
        for _, v in ipairs(data) do
          if v ~= "" then
            table.insert(stderr, v)
          end
        end
      end
    end,
  })

  if type(jobid) ~= "number" or jobid <= 0 then
    return { code = 1, stdout = "", stderr = "Failed to start job" }
  end

  local waited = vim.fn.jobwait({ jobid }, timeout_ms)
  local code = type(waited) == "table" and waited[1] or -1
  if code == -1 then
    pcall(vim.fn.jobstop, jobid)
    return { code = -1, stdout = table.concat(stdout, "\n"), stderr = table.concat(stderr, "\n"), timeout = true }
  end
  return { code = code, stdout = table.concat(stdout, "\n"), stderr = table.concat(stderr, "\n") }
end

local function check_neovim_version()
  health.start("Neovim version")
  local version = vim.version()
  local major = version.major
  local minor = version.minor
  local required_major = 0
  local required_minor = 9

  if major > required_major or (major == required_major and minor >= required_minor) then
    health.ok(string.format("Neovim %d.%d.%d is supported", major, minor, version.patch))
  else
    health.error(
      string.format(
        "Neovim %d.%d.%d is not supported. Required: >= %d.%d",
        major,
        minor,
        version.patch,
        required_major,
        required_minor
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
