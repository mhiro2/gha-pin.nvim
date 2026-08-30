local M = {}

M.minimum = {
  major = 0,
  minor = 10,
  patch = 0,
}

---@param version table
---@return boolean
function M.is_supported(version)
  local minimum = M.minimum
  if version.major ~= minimum.major then
    return version.major > minimum.major
  end
  if version.minor ~= minimum.minor then
    return version.minor > minimum.minor
  end
  return (version.patch or 0) >= minimum.patch
end

---@param version table
---@return string
function M.format(version)
  return string.format("%d.%d.%d", version.major, version.minor, version.patch or 0)
end

---@param version? table
function M.assert_supported(version)
  version = version or vim.version()
  if M.is_supported(version) then
    return
  end

  error(string.format("gha-pin.nvim requires Neovim >= %s (current: %s)", M.format(M.minimum), M.format(version)), 2)
end

return M
