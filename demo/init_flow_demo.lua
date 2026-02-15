-- Minimal init for flow demo recording
vim.o.number = true
vim.o.cursorline = true
vim.o.termguicolors = true
vim.o.showmode = true
vim.o.laststatus = 2
vim.o.cmdheight = 2

require("flows").setup()
