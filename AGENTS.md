# AGENTS.md

Neovim plugin for persistent audit annotations via Numscull protocol. Pure Lua, no build step.

## Setup

```bash
apt-get install -y neovim libsodium-dev
```

For tests: `pip install pynacl` (or use `.venv`).

## Test

Run from the repo root:

```bash
nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/run_tests.lua
```

Exit code is non-zero on failure.

## Structure

- `lua/numscull/init.lua` — main entry: setup(), config, autocommands, public API
- `lua/numscull/crypto.lua` — NaCl Box encryption (libsodium FFI)
- `lua/numscull/transport.lua` — TCP via vim.uv, plaintext + encrypted framing
- `lua/numscull/client.lua` — JSON-RPC layer
- `lua/numscull/control.lua` — init, projects, subscribe, exit
- `lua/numscull/notes.lua` — notes API + extmark rendering
- `lua/numscull/flow.lua` — flows API + scratch buffer display
- `plugin/numscull.lua` — user command registration
- `tests/mock_server.py` — Python mock Numscull server
- `tests/run_tests.lua` — headless test suite
