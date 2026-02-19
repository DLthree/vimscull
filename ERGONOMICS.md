# Ergonomic Improvements

This document describes the ergonomic improvements added to vimscull.

## Quick Connect

### NumscullQuickConnect

Connect to a server and optionally open a project in one command:

```vim
:NumscullQuickConnect [host] [port] [project]
:NumscullQuickConnect! [host] [port] [project]  " Save config to .numscull/config
```

Examples:
```vim
" Connect to default host/port
:NumscullQuickConnect

" Connect to specific host and port
:NumscullQuickConnect 192.168.1.100 5001

" Connect and switch to project
:NumscullQuickConnect 127.0.0.1 5000 myproject

" Connect and save settings to .numscull/config
:NumscullQuickConnect! 127.0.0.1 5000 myproject
```

### NumscullQuickConnectAuto

Auto-connect using settings from `.numscull/config` in the project root:

```vim
:NumscullQuickConnectAuto
```

The `.numscull/config` file format is simple:
```
host=127.0.0.1
port=5000
project=myproject
```

## Status Indicator

Get connection and flow status for statusline/winbar:

```lua
-- In your statusline config
require('numscull').status()
```

This returns a string showing:
- Connection icon (📝) when connected
- Current active flow name (if any)

Example in your statusline:
```lua
-- For lualine
sections = {
  lualine_x = { require('numscull').status },
}

-- For manual statusline
vim.o.statusline = '%<%f %h%m%r%=%{luaeval("require(\'numscull\').status()")} %-14.(%l,%c%V%) %P'
```

## "Here" Variants

All main actions now have "Here" variants that work at the current cursor position with smart defaults.

### NoteAddHere

Add a note at the current cursor position with immediate editor (no prompt):

```vim
:NoteAddHere
```

Features:
- Opens the editor immediately (no intermediate prompt)
- Pre-fills with template (if configured)
- Cursor is positioned in the edit buffer ready to type
- Buffer-local mapping: `<leader>na` (default, configurable)

### NoteEditHere

Edit the closest note at cursor in the full editor:

```vim
:NoteEditHere
```

Same as `:NoteEditOpen` but with a clearer "Here" naming convention.
Buffer-local mapping: `<leader>ne` (default, configurable)

### FlowAddNodeHere

Add a flow node at the current cursor with smart defaults:

```vim
:FlowAddNodeHere
```

Smart defaults:
- **Location**: Current file and line (automatically)
- **Name**: Extracted from Treesitter/LSP (function/symbol name) or falls back to `filename:line`
- **Color**: Last used color in this flow, or first palette color

The command will still prompt for name and color, but with intelligent defaults pre-filled.

## Note Templates

Configure a template for new notes:

```lua
require('numscull').setup({
  note_template = "# TODO:\n- [ ] \n",
})
```

The template is pre-filled when using `NoteAddHere`.

## Buffer-Local Mappings

Quick-add mappings are automatically set up for buffers:

```lua
require('numscull').setup({
  mappings = {
    note_add = "<leader>na",   -- NoteAddHere
    note_edit = "<leader>ne",  -- NoteEditHere
  },
})
```

These mappings are only active in buffers with files (not scratch buffers).

## Configuration Example

Full example with all new features:

```lua
require('numscull').setup({
  host = "127.0.0.1",
  port = 5000,
  identity = "myuser",
  config_dir = vim.fn.expand("~/.config/numscull"),
  
  -- Note template
  note_template = [[
# TODO:
- [ ] 

Tags: #
]],
  
  -- Quick mappings
  mappings = {
    note_add = "<leader>na",
    note_edit = "<leader>ne",
  },
})
```

## Workflow Examples

### Quick Start Workflow

1. Auto-connect to your project:
   ```vim
   :NumscullQuickConnectAuto
   ```

2. Add notes as you work:
   - Press `<leader>na` to add a note immediately
   - Edit with `<leader>ne` or `:NoteEditHere`

3. Add flow nodes while navigating:
   ```vim
   :FlowAddNodeHere
   ```
   The node name will be the function name where your cursor is!

### Team Workflow

Save connection settings for your team:

```vim
:NumscullQuickConnect! server.example.com 5000 teamproject
```

This creates `.numscull/config` which you can commit to your repo.
Team members just run:
```vim
:NumscullQuickConnectAuto
```

## Status Line Integration Examples

### Lualine

```lua
require('lualine').setup {
  sections = {
    lualine_x = {
      function()
        return require('numscull').status()
      end,
    },
  },
}
```

### Native Statusline

```lua
vim.o.statusline = table.concat({
  '%<%f',                                      -- filename
  '%h%m%r',                                    -- flags
  '%=',                                        -- right align
  '%{luaeval("require(\'numscull\').status()")}', -- numscull status
  ' %-14.(%l,%c%V%)',                          -- line, column
  ' %P',                                       -- percentage
})
```
