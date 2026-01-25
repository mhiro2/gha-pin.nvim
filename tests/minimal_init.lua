local mini_path = vim.env.MINI_PATH or "deps/mini.nvim"

vim.opt.rtp:append(vim.fn.getcwd())
vim.opt.rtp:append(mini_path)

vim.env.XDG_CACHE_HOME = vim.fn.getcwd() .. "/.tests/cache"
vim.fn.mkdir(vim.env.XDG_CACHE_HOME, "p")

vim.o.swapfile = false
vim.o.backup = false
vim.o.writebackup = false
vim.o.shadafile = "NONE"
