-- Minimal init for demo recording
vim.o.number = true
vim.o.cursorline = true
vim.o.termguicolors = false
vim.o.showmode = true
vim.o.laststatus = 2
vim.o.cmdheight = 2

require("audit_notes").setup({
  author = "reviewer",
  icon = ">>",
})
