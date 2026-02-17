# vimscull

Persistent, collaborative audit annotations and code flow highlighting for Neovim — rendered inline using extmarks.

## Demos

### Annotations

![Annotation Tutorial — add, edit, delete](demo/annotation-tutorial.svg)

### Flows

![Flow Tutorial — create, navigate, switch](demo/flow-tutorial.svg)

## Features

- **Annotations**: Inline virtual-line annotations that follow code through edits (extmark-anchored).
- **Flows**: Named sequences of highlighted code locations with colored text and parent/child navigation.
- Shared JSON storage designed to be committed to git.
- Multi-line notes, multiple notes per line, toggle visibility.
- Per-file markdown export.
- Pure Lua, no dependencies, Neovim 0.9+.

## Installation

### lazy.nvim

```lua
{
  "your-user/vimscull",
  config = function()
    require("audit_notes").setup({
      -- All options are optional:
      -- storage_path = "/custom/path/notes.json",
      -- author       = "alice",
      -- autosave     = true,
      -- icon         = "📝",
      -- max_line_len = 120,
    })
    require("flows").setup({
      -- storage_path = "/custom/path/flows.json",
    })
  end,
}
```

### packer.nvim

```lua
use {
  "your-user/vimscull",
  config = function()
    require("audit_notes").setup()
    require("flows").setup()
  end,
}
```

### Manual

Clone this repo into your Neovim runtime path (e.g. `~/.config/nvim/pack/plugins/start/vimscull`) and add to your `init.lua`:

```lua
require("audit_notes").setup()
require("flows").setup()
```

## Configuration

### Annotations

```lua
require("audit_notes").setup({
  storage_path = nil,        -- auto: <git_root>/.audit/notes.json or ~/.local/state/nvim/audit-notes.json
  author       = nil,        -- auto: vim.g.audit_author or $USER
  autosave     = true,       -- save JSON on every BufWritePost
  icon         = "📝",       -- prefix icon for rendered notes
  max_line_len = 120,        -- truncate virtual lines beyond this width
})
```

### Flows

```lua
require("flows").setup({
  storage_path = nil,        -- auto: <git_root>/.audit/flows.json or ~/.local/state/nvim/flows.json
})
```

## Commands

### Annotation commands

| Command | Description |
|---|---|
| `:AuditAdd` | Prompt for note text, add below cursor line |
| `:AuditAddHere {text}` | Add a note with inline text (no prompt) |
| `:AuditEdit` | Edit the note closest to the cursor |
| `:AuditDelete` | Delete the note closest to the cursor (with confirmation) |
| `:AuditList` | Open a scratch buffer listing notes; `<CR>` jumps to line |
| `:AuditToggle` | Show/hide annotations without losing data |
| `:AuditShow` | Echo the full text of the closest note |
| `:AuditExport` | Write a markdown summary to `.audit/<file>.md` |

Use `\n` in note text to create multi-line annotations.

### Flow commands

| Command | Description |
|---|---|
| `:FlowCreate [name]` | Create a new flow (becomes the active flow) |
| `:FlowDelete` | Delete the active flow (with confirmation) |
| `:FlowSelect` | Open floating window to pick, create, or delete flows |
| `:FlowAddNode` | Add visual selection as a node to the active flow (prompts for color) |
| `:FlowDeleteNode` | Remove the closest node near cursor from the active flow |
| `:FlowNext` | Jump to the next (child) node in the active flow |
| `:FlowPrev` | Jump to the previous (parent) node in the active flow |
| `:FlowList` | Open a scratch buffer listing nodes; `<CR>` jumps to location |

Available highlight colors: Red, Blue, Green, Yellow, Cyan, Magenta.

## Example keymaps

```lua
-- Annotations
vim.keymap.set("n", "<leader>aa", "<cmd>AuditAdd<cr>",    { desc = "Add audit note" })
vim.keymap.set("n", "<leader>ae", "<cmd>AuditEdit<cr>",   { desc = "Edit audit note" })
vim.keymap.set("n", "<leader>ad", "<cmd>AuditDelete<cr>", { desc = "Delete audit note" })
vim.keymap.set("n", "<leader>al", "<cmd>AuditList<cr>",   { desc = "List audit notes" })
vim.keymap.set("n", "<leader>at", "<cmd>AuditToggle<cr>", { desc = "Toggle audit notes" })
vim.keymap.set("n", "<leader>as", "<cmd>AuditShow<cr>",   { desc = "Show full note" })

-- Flows
vim.keymap.set("n", "<leader>fc", "<cmd>FlowCreate<cr>",     { desc = "Create flow" })
vim.keymap.set("n", "<leader>fs", "<cmd>FlowSelect<cr>",     { desc = "Select flow" })
vim.keymap.set("v", "<leader>fa", ":<C-u>FlowAddNode<cr>",   { desc = "Add flow node" })
vim.keymap.set("n", "<leader>fd", "<cmd>FlowDeleteNode<cr>", { desc = "Delete flow node" })
vim.keymap.set("n", "<leader>fn", "<cmd>FlowNext<cr>",       { desc = "Next flow node" })
vim.keymap.set("n", "<leader>fp", "<cmd>FlowPrev<cr>",       { desc = "Prev flow node" })
vim.keymap.set("n", "<leader>fl", "<cmd>FlowList<cr>",       { desc = "List flow nodes" })
```

## How it works

### Annotations — extmarks as anchors

Each note is attached to a buffer position via `nvim_buf_set_extmark`. Extmarks are Neovim's mechanism for tracking positions through buffer edits — when lines are inserted, deleted, or moved, the extmark follows automatically. This means a note placed on line 42 will stay attached to that logical line even after surrounding edits, without any diff-tracking or line-number patching.

The extmark renders the annotation as one or more **virtual lines** below the anchored source line (`virt_lines` option). These lines are purely visual — the buffer text is never modified.

### Flows — inline highlights with navigation

A flow is a named, ordered list of code locations (file, line, column range). Each node in a flow highlights the specified text range with a colored background using extmarks with `hl_group`. Only one flow is active at a time — switching flows swaps the highlights across all open buffers.

Nodes have a parent/child relationship defined by their order in the flow. `:FlowNext` moves to the child node, `:FlowPrev` moves to the parent, wrapping around at the ends. Navigation works across files — jumping to a node in a different file opens that file automatically.

### JSON sync and persistence

Notes are stored in `.audit/notes.json`, flows in `.audit/flows.json`. Both are plain JSON files designed for git storage. On `BufWritePost`, the plugin syncs live extmark positions back to JSON.

**Edge cases:**
- **Deleted lines**: If text containing an extmark is deleted, Neovim collapses the extmark to the nearest valid position. The note remains; it just moves.
- **Missing/renamed files**: Entries for files that no longer exist are kept in JSON. They are never silently deleted — they simply won't render until a buffer with that path is opened.
- **Reloading**: On `BufReadPost`, notes are re-placed from JSON line numbers. Between sessions, line numbers are the fallback anchor. If the file changed outside Neovim, notes may land on slightly wrong lines (same limitation as any line-based bookmark).

## Storage format

### Annotations

```json
{
  "/absolute/path/to/file.lua": [
    {
      "id": "a1b2c3d4-...",
      "text": "This function has a race condition.\nNeeds mutex.",
      "author": "alice",
      "timestamp": "2025-03-15T10:30:00Z",
      "line": 42,
      "col": 0
    }
  ]
}
```

### Flows

```json
{
  "flows": [
    {
      "id": "a1b2c3d4-...",
      "name": "Security Audit",
      "nodes": [
        {
          "id": "e5f6g7h8-...",
          "file": "/absolute/path/to/file.py",
          "line": 10,
          "col_start": 4,
          "col_end": 20,
          "color": "FlowRed"
        }
      ]
    }
  ],
  "active_flow_id": "a1b2c3d4-..."
}
```

## Mockscull (reference implementation & schema)

The `mockscull/` directory contains the **reference Python client** and **canonical schemas** for the Numscull protocol. vimscull’s Lua client is a port of this protocol.

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
3. **Cross-check Lua vs Python**: Compare `mockscull/src/numscull/client.py` method signatures and params with the Lua client’s `request()` calls in `lua/numscull/notes.lua`, `flow.lua`, `control.lua`.
4. **Wire protocol**: `mockscull/src/numscull/transport.py` and `crypto.py` document the wire format. `lua/numscull/transport.lua` and `crypto.lua` must match (10-byte header, 528-byte blocks, counter nonces).

See `mockscull/README.md` for full protocol documentation and module/method tables.

## License

MIT
