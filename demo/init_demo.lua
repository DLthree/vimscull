-- init_demo.lua - Realistic Neovim demo config for vimscull
-- Compatible with Neovim 0.9.5+

-- =========================
-- Core settings
-- =========================
vim.g.mapleader = " "

vim.o.number = true
vim.o.relativenumber = true
vim.o.mouse = "a"

vim.o.expandtab = true
vim.o.shiftwidth = 2
vim.o.tabstop = 2
vim.o.smartindent = true

vim.o.termguicolors = true
vim.o.signcolumn = "yes"
vim.o.cursorline = true
vim.o.splitright = true
vim.o.splitbelow = true

vim.o.ignorecase = true
vim.o.smartcase = true

vim.o.updatetime = 250
vim.o.timeoutlen = 300
vim.o.cmdheight = 2

-- =========================
-- lazy.nvim bootstrap
-- =========================
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
local uv = vim.uv or vim.loop
if not uv.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- =========================
-- Plugins
-- =========================
require("lazy").setup({
  -- UI enhancements for vim.ui.input/select
  {
    "stevearc/dressing.nvim",
    opts = {},
  },

  -- Statusline
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = { 
      options = { 
        globalstatus = true,
        theme = 'auto',
      } 
    },
  },

  -- vimscull (local plugin from repo)
  {
    dir = vim.fn.getcwd(),
    lazy = false,
    config = function()
      local config_dir = os.getenv("NUMSCULL_CONFIG_DIR") or "/tmp/numscull-demo"
      local port = tonumber(os.getenv("NUMSCULL_PORT") or "5222")
      
      require("numscull").setup({
        host = "127.0.0.1",
        port = port,
        identity = "demo-reviewer",
        config_dir = config_dir,
        icon = "📝",
        editor = "float",  -- Use two-pane float editor
        context_lines = 10,
        float_border = "rounded",
        auto_connect = false,
        auto_fetch = false,
      })
    end,
  },
}, {
  ui = {
    border = "rounded",
  },
})
