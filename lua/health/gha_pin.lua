-- NOTE:
-- Neovim's :checkhealth looks for `lua/health/<name>.lua` and calls `require("health.<name>").check()`.
-- We keep this file as a tiny adapter, and implement the actual logic in `lua/gha-pin/health.lua`.

local M = {}

function M.check()
  require("gha-pin.health").check()
end

return M
