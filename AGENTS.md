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

## Code style

- 2-space indentation
- Module pattern: `local M = {}` returned at end of file
- Private helpers are `local function`s, public API lives on `M`
- No linter or formatter configured; match existing style
