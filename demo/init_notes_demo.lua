-- Minimal init for notes demo recording (server-connected)
vim.o.number = true
vim.o.cursorline = true
vim.o.termguicolors = false
vim.o.showmode = true
vim.o.laststatus = 2
vim.o.cmdheight = 2

local config_dir = os.getenv("NUMSCULL_CONFIG_DIR") or "/tmp/numscull-demo"
local port = tonumber(os.getenv("NUMSCULL_PORT") or "5222")

require("numscull").setup({
  host = "127.0.0.1",
  port = port,
  identity = "demo-reviewer",
  config_dir = config_dir,
  icon = ">>",
  auto_connect = false,
  auto_fetch = false,
})
