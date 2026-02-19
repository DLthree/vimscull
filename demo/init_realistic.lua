-- init.lua (minimal-but-realistic Neovim demo env for vimscull)
-- Demonstrates vimscull in a realistic environment with Telescope

-- =========================
-- Core settings (mainstream)
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
local uv = vim.uv or vim.loop  -- vim.uv is only available in newer versions
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
-- Plugins (minimal for demo)
-- =========================
require("lazy").setup({
  -- Nice defaults for vim.ui.input/select
  {
    "stevearc/dressing.nvim",
    opts = {},
  },

  -- Statusline
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = { options = { globalstatus = true } },
  },

  -- Telescope (essential for showing realistic environment)
  {
    "nvim-telescope/telescope.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      local telescope = require("telescope")
      telescope.setup({
        defaults = {
          layout_strategy = "horizontal",
          sorting_strategy = "ascending",
          winblend = 0,
        },
      })
      -- Minimal keymaps
      local builtin = require("telescope.builtin")
      vim.keymap.set("n", "<leader>ff", builtin.find_files, { desc = "Find files" })
      vim.keymap.set("n", "<leader>fg", builtin.live_grep,  { desc = "Live grep" })
      vim.keymap.set("n", "<leader>fb", builtin.buffers,    { desc = "Buffers" })
    end,
  },

  -- vimscull (local dev plugin)
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
        editor = "float",  -- Use the new two-pane float editor
        context_lines = 10,
        float_border = "rounded",
        auto_connect = false,
        auto_fetch = false,
      })
    end,
  },
})

