# AGENTS.md

## Project Overview

**vimscull** is a Neovim plugin that provides persistent, collaborative audit annotations rendered inline as virtual lines using extmarks. Written entirely in Lua, it requires no external Lua dependencies — only Neovim 0.9+.

## Repository Structure

```
lua/audit_notes.lua      # Core plugin module (all business logic)
plugin/audit_notes.lua   # Plugin loader and user command registration
tests/run_tests.lua      # Automated test suite
README.md                # User-facing documentation
```

## Language

100% Lua, targeting the Neovim Lua runtime (`vim.api`, `vim.fn`).

## Dependencies

### Required

- **Neovim >= 0.9** — the only hard dependency. Tests run headless via `nvim`.

#### Installing Neovim

Ubuntu / Debian:

```bash
# Neovim 0.9+ is not in older distro repos; use the stable PPA or download an appimage.
sudo add-apt-repository ppa:neovim-ppa/stable
sudo apt-get update
sudo apt-get install -y neovim
```

Or download the latest release directly:

```bash
curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.appimage
chmod u+x nvim-linux-x86_64.appimage
sudo mv nvim-linux-x86_64.appimage /usr/local/bin/nvim
```

macOS (Homebrew):

```bash
brew install neovim
```

Verify the version meets the minimum requirement:

```bash
nvim --version   # must be v0.9.0 or later
```

### Optional

- **Git** — used at runtime to auto-detect the project root for note storage (`git rev-parse --show-toplevel`). Not required for tests.

## Build

There is no build step. The plugin is pure Lua loaded by Neovim's runtime path.

## Running Tests

```bash
nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/run_tests.lua
```

This runs the full test suite (17 suites, 74+ assertions) headlessly. Exit code is non-zero on failure. Tests create and clean up temporary files automatically.

The command must be run from the repository root so that `set rtp+=.` correctly adds the plugin to Neovim's runtime path.

## Code Conventions

- Module pattern: local `M = {}` table with public API methods, returned at end of file.
- Private helpers are file-local functions (`local function name() ... end`).
- 2-space indentation.
- User feedback via `vim.notify()` with appropriate log levels (`vim.log.levels.INFO`, `WARN`, `ERROR`).
- Safe Neovim API calls wrapped in `pcall()` where failure is possible.
- No external linter or formatter is configured; maintain consistency with the existing style.

## Key Design Details

- **Extmarks** are the authoritative anchor for note positions during a session — not line numbers.
- **JSON storage** (`<git_root>/.audit/notes.json` or `~/.local/state/nvim/audit-notes.json`) persists notes between sessions. Line numbers in JSON are metadata written back on save.
- **Virtual lines** (`virt_lines` extmark option) render annotations below the anchored line without modifying buffer text.

## Common Tasks

| Task | Command |
|---|---|
| Run tests | `nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/run_tests.lua` |
| Install plugin locally | Clone into `~/.config/nvim/pack/plugins/start/vimscull` |
| Check Neovim version | `nvim --version` |
