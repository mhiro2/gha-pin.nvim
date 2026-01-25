-- Commands are defined here so they are available without explicit setup call.
-- Each command lazily requires the module and uses default configuration unless user called setup().

local function mod()
  return require("gha-pin")
end

vim.api.nvim_create_user_command("GhaPinCheck", function()
  mod().check(0)
end, { desc = "gha-pin.nvim: check pinned uses SHA vs latest", nargs = 0 })

vim.api.nvim_create_user_command("GhaPinFix", function(opts)
  mod().fix(0, opts.line1, opts.line2)
end, { desc = "gha-pin.nvim: update pinned SHA to latest", range = true })

vim.api.nvim_create_user_command("GhaPinExplain", function()
  mod().explain(0)
end, { desc = "gha-pin.nvim: explain resolution for uses under cursor", nargs = 0 })

vim.api.nvim_create_user_command("GhaPinCacheClear", function()
  mod().cache_clear()
end, { desc = "gha-pin.nvim: clear cache", nargs = 0 })
