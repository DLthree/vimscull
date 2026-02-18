# vimscull

Persistent, collaborative audit annotations and code flow highlighting for Neovim — rendered inline using extmarks. All data synced via the Numscull protocol.

## Demos

### Notes (server-connected annotations)

![Notes Tutorial — connect, add, edit, search, delete](demo/notes-tutorial.svg)

### Search & Tags

![Search Tutorial — tagged notes, search, tag counts](demo/search-tutorial.svg)

### Flows (server-connected code flow highlighting)

![Flow Tutorial — create, navigate, switch](demo/flow-tutorial.svg)

## Features

- **Server-connected annotations**: Inline virtual-line notes synced via the Numscull protocol (NaCl-encrypted JSON-RPC).
- **Search & tags**: Full-text search, tag-based search (`#tag`), and tag frequency counts across notes.
- **Flows**: Named, graph-based sequences of highlighted code locations with colored text, parent/child navigation, and a floating selection UI — all synced via Numscull.
- Multi-line notes, toggle visibility, per-file note listing with jump-to-line.
- Pure Lua, Neovim 0.9+, libsodium for encryption.

## Installation

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

### Manual

Clone this repo into your Neovim runtime path (e.g. `~/.config/nvim/pack/plugins/start/vimscull`) and add to your `init.lua`:

```lua
require("numscull").setup()
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
})
```

## Commands

### Connection commands

| Command | Description |
|---|---|
| `:NumscullConnect [host] [port]` | Connect to Numscull server and initialize (encrypted handshake) |
| `:NumscullDisconnect` | Disconnect from server |
| `:NumscullProject <name>` | Switch active project |
| `:NumscullListProjects` | List available projects |

### Note commands

| Command | Description |
|---|---|
| `:NoteAdd [text]` | Add note at cursor (prompts if no text given) |
| `:NoteEdit` | Edit the note closest to the cursor |
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

## How it works

### Annotations — extmarks as anchors

Each note is attached to a buffer position via `nvim_buf_set_extmark`. Extmarks are Neovim's mechanism for tracking positions through buffer edits — when lines are inserted, deleted, or moved, the extmark follows automatically. This means a note placed on line 42 will stay attached to that logical line even after surrounding edits, without any diff-tracking or line-number patching.

The extmark renders the annotation as one or more **virtual lines** below the anchored source line (`virt_lines` option). These lines are purely visual — the buffer text is never modified.

### Flows — inline highlights with navigation

A flow is a named, directed graph of code locations (file, line, column range) stored on the Numscull server. Each node in a flow highlights the specified text range with a colored background using extmarks with `hl_group`. Only one flow is active at a time — switching flows swaps the highlights across all open buffers.

Nodes are ordered by server ID for linear navigation. `:FlowNext` moves to the next node, `:FlowPrev` moves to the previous, wrapping around at the ends. Navigation works across files — jumping to a node in a different file opens that file automatically.

The server stores the full graph structure with directed edges (parent/child/fork relationships). Use `:FlowShow` to inspect the graph, or `:FlowAddNode` and `:FlowRemoveNode` for fine-grained control.

### Numscull protocol and encryption

Notes and flows are synced over TCP using the Numscull protocol. The connection begins with a plaintext `control/init` handshake, followed by an ephemeral X25519 key exchange. All subsequent JSON-RPC messages are encrypted with NaCl Box (Poly1305 MAC, counter-based nonces, 528-byte blocks). The Lua client uses FFI bindings to libsodium.

## Mockscull (reference implementation & schema)

The `mockscull/` directory contains the **reference Python client** and **canonical schemas** for the Numscull protocol. vimscull's Lua client is a port of this protocol.

### Why it exists

- **Schema source**: JSON schemas in `mockscull/schema/` define the RPC methods, params, and responses for control, notes, and flow. These are the source of truth for wire format and data shapes.
- **Reference client**: `mockscull/src/numscull/` implements the full protocol (crypto, transport, client). The Lua implementation in `lua/numscull/` mirrors this.
- **Test harness**: `mockscull/tests/` runs pytest integration tests against a real Numscull server (or the mock server in `tests/mock_server.py`). These tests validate schema compliance and client behavior.

### What is available

| Path | Purpose |
|------|---------|
| `mockscull/schema/control.schema.json` | Control module: init, projects, subscribe, exit |
| `mockscull/schema/notes.schema.json` | Notes module: set, for/file, remove, search, tag/count |
| `mockscull/schema/flow.schema.json` | Flow module: create, get, add/node, fork/node, etc. |
| `mockscull/src/numscull/client.py` | `NumscullClient` — all RPC methods |
| `mockscull/src/numscull/crypto.py` | NaCl Box, key exchange, `EncryptedChannel` |
| `mockscull/src/numscull/transport.py` | Wire framing (plaintext init, 528-byte encrypted blocks) |
| `mockscull/tests/test_control.py` | Control integration tests |
| `mockscull/tests/test_notes.py` | Notes integration tests |
| `mockscull/tests/test_flow.py` | Flow integration tests |
| `mockscull/tests/test_schema.py` | JSON Schema validation tests |

### Verifying schema and client implementation

1. **Inspect schemas**: Read `mockscull/schema/*.schema.json` for method names, param shapes, and response structures. Compare with `lua/numscull/notes.lua`, `flow.lua`, `control.lua`.
2. **Run Mockscull tests**: From repo root, `cd mockscull && pip install -e ".[dev]" && pytest tests/ -v`. Requires `numscull_native` binary or use `tests/mock_server.py` as the server.
3. **Cross-check Lua vs Python**: Compare `mockscull/src/numscull/client.py` method signatures and params with the Lua client's `request()` calls in `lua/numscull/notes.lua`, `flow.lua`, `control.lua`.
4. **Wire protocol**: `mockscull/src/numscull/transport.py` and `crypto.py` document the wire format. `lua/numscull/transport.lua` and `crypto.lua` must match (10-byte header, 528-byte blocks, counter nonces).

See `mockscull/README.md` for full protocol documentation and module/method tables.

## License

MIT
