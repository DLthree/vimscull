# vimscull

Persistent, collaborative audit annotations for Neovim — rendered inline as virtual lines using extmarks.

## Features

- Inline virtual-line annotations that follow code through edits (extmark-anchored).
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
  end,
}
```

### packer.nvim

```lua
use {
  "your-user/vimscull",
  config = function()
    require("audit_notes").setup()
  end,
}
```

### Manual

Clone this repo into your Neovim runtime path (e.g. `~/.config/nvim/pack/plugins/start/vimscull`) and add to your `init.lua`:

```lua
require("audit_notes").setup()
```

## Configuration

```lua
require("audit_notes").setup({
  storage_path = nil,        -- auto: <git_root>/.audit/notes.json or ~/.local/state/nvim/audit-notes.json
  author       = nil,        -- auto: vim.g.audit_author or $USER
  autosave     = true,       -- save JSON on every BufWritePost
  icon         = "📝",       -- prefix icon for rendered notes
  max_line_len = 120,        -- truncate virtual lines beyond this width
})
```

## Commands

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

## Example keymaps

```lua
vim.keymap.set("n", "<leader>aa", "<cmd>AuditAdd<cr>",    { desc = "Add audit note" })
vim.keymap.set("n", "<leader>ae", "<cmd>AuditEdit<cr>",   { desc = "Edit audit note" })
vim.keymap.set("n", "<leader>ad", "<cmd>AuditDelete<cr>", { desc = "Delete audit note" })
vim.keymap.set("n", "<leader>al", "<cmd>AuditList<cr>",   { desc = "List audit notes" })
vim.keymap.set("n", "<leader>at", "<cmd>AuditToggle<cr>", { desc = "Toggle audit notes" })
vim.keymap.set("n", "<leader>as", "<cmd>AuditShow<cr>",   { desc = "Show full note" })
```

## How it works

### Extmarks as anchors

Each note is attached to a buffer position via `nvim_buf_set_extmark`. Extmarks are Neovim's mechanism for tracking positions through buffer edits — when lines are inserted, deleted, or moved, the extmark follows automatically. This means a note placed on line 42 will stay attached to that logical line even after surrounding edits, without any diff-tracking or line-number patching.

The extmark renders the annotation as one or more **virtual lines** below the anchored source line (`virt_lines` option). These lines are purely visual — the buffer text is never modified.

### JSON sync and persistence

Notes are stored in a plain JSON file keyed by absolute file path. Each note records a `line` and `col` for human readability and diffing, but these are **metadata only** — the extmark is the authoritative position during a session.

On `BufWritePost`, the plugin reads each note's current extmark position (`nvim_buf_get_extmark_by_id`) and writes the updated line/col back to the JSON. This keeps the JSON useful for code review and git diffs even though extmarks are ephemeral (they only exist in the running Neovim session).

**Edge cases:**
- **Deleted lines**: If text containing an extmark is deleted, Neovim collapses the extmark to the nearest valid position. The note remains; it just moves.
- **Missing/renamed files**: Entries for files that no longer exist are kept in JSON. They are never silently deleted — they simply won't render until a buffer with that path is opened.
- **Reloading**: On `BufReadPost`, notes are re-placed from JSON line numbers. Between sessions, line numbers are the fallback anchor. If the file changed outside Neovim, notes may land on slightly wrong lines (same limitation as any line-based bookmark).

## Storage format

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

## License

MIT
