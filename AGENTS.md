# AGENTS.md

Neovim plugin for persistent audit annotations. Pure Lua, no build step.

## Setup

```bash
apt-get install -y neovim
```

## Test

Run from the repo root:

```bash
nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/run_tests.lua
```

Exit code is non-zero on failure.

## Structure

- `lua/audit_notes.lua` — core module: storage, extmarks, note CRUD
- `plugin/audit_notes.lua` — plugin loader and user command registration
- `tests/run_tests.lua` — headless test suite
