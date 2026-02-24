# vimscull

Persistent, collaborative audit annotations and code flow highlighting for Neovim — rendered inline using extmarks. All data synced via the Numscull protocol.

# Quick quick quickstart

```bash
mkdir -p ~/.config/nvim/pack/plugins/start/
ln -s ~/proj/vimscull/ ~/.config/nvim/pack/plugins/start/vimscull
```

* add to ~/.config/nvim/init.lua :

```lua
require("numscull").setup({
  host         = "127.0.0.1", -- Numscull server host
  port         = 5000,        -- Numscull server port
  identity     = nil,         -- auto: $USER — must match a keypair in config_dir
  config_dir   = nil,         -- path containing identities/<name> and users/<name>.pub
  project      = nil,         -- auto-switch to this project after connect
  icon         = "📝",        -- prefix icon for rendered notes
  max_line_len = 120,         -- truncate virtual lines beyond this width
  auto_connect = false,       -- connect on setup (requires identity + config_dir)
  auto_fetch   = true,        -- fetch notes for each buffer on BufReadPost
  quick_connect_auto = false, -- auto-connect from .numscull/config on startup
  note_template = "",         -- template for new notes
  mappings = {
    note_add = "<leader>na",           -- quick add note
    note_edit = "<leader>ne",          -- quick edit note
    flow_add_node_here = nil,          -- optional: add flow node at cursor
    flow_select = nil,                 -- optional: select flow
  },
})

```

## Demo

![vimscull Demo — Connect, add/edit notes, create flows, add nodes](demo/vimscull-demo.svg)

Features shown:
- **Server connection** and project management
- **Notes**: Add notes via command args, edit with inline editor 
- **Flows**: Create code flow highlighting, add colored nodes, list flows
- **Modern UI**: lualine statusline

## Features

- **Server-connected annotations**: Inline virtual-line notes synced via the Numscull protocol (NaCl-encrypted JSON-RPC).
- **Search & tags**: Full-text search, tag-based search (`#tag`), and tag frequency counts across notes.
- **Flows**: Named, graph-based sequences of highlighted code locations with colored text, parent/child navigation, and a floating selection UI — all synced via Numscull.
- Multi-line notes, toggle visibility, per-file note listing with jump-to-line.
- Pure Lua, Neovim 0.9+, libsodium for encryption.

## Installation

### Manual

Clone this repo into your Neovim runtime path (e.g. `~/.config/nvim/pack/plugins/start/vimscull`) and add to your `init.lua`:

```lua
require("numscull").setup()
```

### lazy.nvim

```lua
{
  "your-user/vimscull",
  config = function()
    require("numscull").setup({
      -- All options are optional:
      -- host         = "127.0.0.1",
      -- port         = 5000,
      -- identity     = nil,       -- auto: $USER
      -- config_dir   = nil,       -- path to identities/ and users/
      -- project      = nil,       -- auto-switch to project on connect
      -- icon         = "📝",
      -- max_line_len = 120,
      -- auto_connect = false,
      -- auto_fetch   = true,
    })
  end,
}
```

### packer.nvim

```lua
use {
  "your-user/vimscull",
  config = function()
    require("numscull").setup()
  end,
}
```


## Configuration

```lua
require("numscull").setup({
  host         = "127.0.0.1", -- Numscull server host
  port         = 5000,        -- Numscull server port
  identity     = nil,         -- auto: $USER — must match a keypair in config_dir
  config_dir   = nil,         -- path containing identities/<name> and users/<name>.pub
  project      = nil,         -- auto-switch to this project after connect
  icon         = "📝",        -- prefix icon for rendered notes
  max_line_len = 120,         -- truncate virtual lines beyond this width
  auto_connect = false,       -- connect on setup (requires identity + config_dir)
  auto_fetch   = true,        -- fetch notes for each buffer on BufReadPost
  quick_connect_auto = false, -- auto-connect from .numscull/config on startup
  note_template = "",         -- template for new notes
  mappings = {
    note_add = "<leader>na",           -- quick add note
    note_edit = "<leader>ne",          -- quick edit note
    flow_add_node_here = nil,          -- optional: add flow node at cursor
    flow_select = nil,                 -- optional: select flow
  },
})
```

### Quick workflow tips

- Create `.numscull/config` at project root with `host=`, `port=`, `project=` lines, then use `:NumscullQuickConnect` to connect from config.
- Enable `quick_connect_auto = true` to auto-connect on startup.
- Use `:NoteAddHere` to open the editor immediately (no prompts).
- Use `:FlowAddNodeHere` to add flow nodes with smart defaults (extracts function name from cursor).
- Add `require('numscull').status()` to your statusline to show connection state and active flow.

## Commands

### Connection commands

| Command | Description |
|---|---|
| `:NumscullConnect [host] [port]` | Connect to Numscull server and initialize (encrypted handshake) |
| `:NumscullQuickConnect[!]` | Connect from `.numscull/config` at project root; use `!` to save changes |
| `:NumscullDisconnect` | Disconnect from server |
| `:NumscullProject <name>` | Switch active project |
| `:NumscullListProjects` | List available projects |

### Note commands

| Command | Description |
|---|---|
| `:NoteAdd [text]` | Add note at cursor (prompts if no text given) |
| `:NoteAddHere` | Add note with immediate editor (no prompts, uses template) |
| `:NoteEdit` | Edit the note closest to the cursor |
| `:NoteEditHere` | Edit the closest note in full editor |
| `:NoteDelete` | Delete the note closest to the cursor (with confirmation) |
| `:NoteShow` | Echo the full text of the closest note |
| `:NoteList` | Open a scratch buffer listing notes; `<CR>` jumps to line |
| `:NoteToggle` | Show/hide annotations without losing data |
| `:NoteSearch <text>` | Search notes by text |
| `:NoteSearchTags <tag>` | Search notes by tag |
| `:NoteTagCount` | Show tag frequency counts |

Use `\n` in note text to create multi-line annotations.

### Flow commands

| Command | Description |
|---|---|
| `:FlowCreate [name] [description...]` | Create a new flow (becomes the active flow) |
| `:FlowDelete` | Delete the active flow (with confirmation) |
| `:FlowSelect` | Open floating window to pick, create, or delete flows |
| `:FlowAddNode [flow_id]` | Add visual selection as a node to the active flow (prompts for color) |
| `:FlowAddNodeHere` | Add node at cursor with smart defaults (function name, last color) |
| `:FlowDeleteNode` | Remove the closest node near cursor from the active flow |
| `:FlowNext` | Jump to the next node in the active flow |
| `:FlowPrev` | Jump to the previous node in the active flow |
| `:FlowList` | List all flows in a scratch buffer |
| `:FlowShow [flow_id]` | Show flow details and nodes; `<CR>` jumps to location |
| `:FlowRemoveNode <node_id>` | Remove a flow node by server ID |
| `:FlowRemove <flow_id>` | Remove a flow by server ID |

Available highlight colors: Red, Blue, Green, Yellow, Cyan, Magenta.

## Example keymaps

```lua
-- Notes
vim.keymap.set("n", "<leader>na", "<cmd>NoteAdd<cr>",        { desc = "Add note" })
vim.keymap.set("n", "<leader>ne", "<cmd>NoteEdit<cr>",       { desc = "Edit note" })
vim.keymap.set("n", "<leader>nd", "<cmd>NoteDelete<cr>",     { desc = "Delete note" })
vim.keymap.set("n", "<leader>nl", "<cmd>NoteList<cr>",       { desc = "List notes" })
vim.keymap.set("n", "<leader>nt", "<cmd>NoteToggle<cr>",     { desc = "Toggle notes" })
vim.keymap.set("n", "<leader>ns", "<cmd>NoteShow<cr>",       { desc = "Show full note" })
vim.keymap.set("n", "<leader>n/", "<cmd>NoteSearch<cr>",     { desc = "Search notes" })
vim.keymap.set("n", "<leader>n#", "<cmd>NoteSearchTags<cr>", { desc = "Search by tag" })

-- Flows
vim.keymap.set("n", "<leader>fc", "<cmd>FlowCreate<cr>",     { desc = "Create flow" })
vim.keymap.set("n", "<leader>fs", "<cmd>FlowSelect<cr>",     { desc = "Select flow" })
vim.keymap.set("v", "<leader>fa", ":<C-u>FlowAddNode<cr>",   { desc = "Add flow node" })
vim.keymap.set("n", "<leader>fd", "<cmd>FlowDeleteNode<cr>", { desc = "Delete flow node" })
vim.keymap.set("n", "<leader>fn", "<cmd>FlowNext<cr>",       { desc = "Next flow node" })
vim.keymap.set("n", "<leader>fp", "<cmd>FlowPrev<cr>",       { desc = "Prev flow node" })
vim.keymap.set("n", "<leader>fl", "<cmd>FlowList<cr>",       { desc = "List flows" })
vim.keymap.set("n", "<leader>fw", "<cmd>FlowShow<cr>",       { desc = "Show flow details" })
```

## Developers

See [DEV.md](./DEV.md) 