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

## Troubleshooting

### "read failed: EOF" when adding a note

If `:NoteAdd` fails with `read failed: EOF (wanted 528 bytes, buffer had 0)`, the server closed the connection before sending a response. This commonly happens when **no active project** is set.

**Fix**: Create or switch to a project before adding notes:

1. `:NumscullListProjects` — list available projects
2. `:NumscullProject <name>` — switch to a project
3. If no projects exist, create one via the server or Mockscull client first

You can also set `project` in `setup()` to auto-switch after connect:

```lua
require("numscull").setup({ config_dir = "/path/to/config", project = "my-project" })
```

### Debug logging

Set `NUMSCULL_DEBUG=1` before starting Neovim to log transport read/write activity (useful when debugging connection issues).

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

### Test against numscull_native

With the server running (`../mockscull/numscull_native -r mockscull/sample-config -p 5111`):

```bash
nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/test_real_server.lua
```

This runs: Connect → ListProjects → CreateProject (if needed) → ChangeProject → AddNote.

### Verifying schema and client implementation

1. **Inspect schemas**: Read `mockscull/schema/*.schema.json` for method names, param shapes, and response structures. Compare with `lua/numscull/notes.lua`, `flow.lua`, `control.lua`.
2. **Run Mockscull tests**: From repo root, `cd mockscull && pip install -e ".[dev]" && pytest tests/ -v`. Requires `numscull_native` binary or use `tests/mock_server.py` as the server.
3. **Cross-check Lua vs Python**: Compare `mockscull/src/numscull/client.py` method signatures and params with the Lua client's `request()` calls in `lua/numscull/notes.lua`, `flow.lua`, `control.lua`.
4. **Wire protocol**: `mockscull/src/numscull/transport.py` and `crypto.py` document the wire format. `lua/numscull/transport.lua` and `crypto.lua` must match (10-byte header, 528-byte blocks, counter nonces).

See `mockscull/README.md` for full protocol documentation and module/method tables.

## Numscull test

```bash
./numscull/zig-out/bin/numscull_native -r vimscull/mockscull/sample-config/ -p 5000 --no-pidfile
```


* Config dir: same as above
* User: python-client
* Project: test-proj