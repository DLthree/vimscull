# Mockscull

Mockscull is an open specificaton for connecting to the Numscull server. Numscull is a collaborative code-annotation server with encrypted communication. Numscull lets users attach **flows** (directed graphs of code locations) and **notes** (tagged annotations on file lines) to a shared project, all transported over an authenticated NaCl Box channel.

## Architecture

```
┌──────────────┐         TCP + NaCl Box          ┌─────────────────┐
│ Python client │ ◄──────────────────────────────► │ numscull_native │
│  (numscull/)  │   plaintext init → key exchange │   (Zig server)  │
└──────────────┘         → encrypted RPCs         └─────────────────┘
```

The server (`numscull_native`) is a precompiled Zig binary. The Python client lives in `src/numscull/` and communicates over a custom binary protocol with JSON-RPC-style messages inside NaCl-encrypted 512-byte blocks.

## Wire Protocol

| Phase | On wire | Description |
|-------|---------|-------------|
| 1. Plaintext init | `[10-byte length header][JSON]` | Client sends `control/init` with identity; server responds with its static X25519 public key |
| 2. Key exchange | `[24-byte nonce][528-byte ciphertext]` | Both sides exchange ephemeral X25519 keypairs encrypted with NaCl Box using static keys |
| 3. Encrypted RPC | `[528-byte ciphertext]` | Fixed 512-byte blocks (`[u16 LE payload len][10-byte header + JSON][random padding]`) encrypted with counter nonces starting at 1 |

## Project Layout

```
numscull_native              Zig server binary
config/                      Runtime configuration (create via Quick start)
  server.json                Server settings (port, limits)
  server.keypair             Server X25519 keypair (64 bytes)
  identities/<name>          Client keypairs (64 bytes: pubkey || secretkey)
  users/<name>.pub           Client public keys (32 bytes)
  dbs/                       Per-project databases
sample-config/               Pre-configured for demo (uses python-client identity)
schema/
  control.schema.json        Control module JSON schema (draft-07)
  flow.schema.json           Flow module JSON schema (draft-07)
  notes.schema.json          Notes module JSON schema (draft-07)
src/numscull/                Client library package
  __init__.py                Re-exports NumscullClient, load_keypair
  transport.py               Wire protocol framing and socket helpers
  crypto.py                  NaCl Box encryption, key exchange, EncryptedChannel
  client.py                  NumscullClient — all RPC methods
tests/
  conftest.py                Pytest fixtures (server, client factory)
  helpers.py                 Test helpers (params, make_location, now)
  test_control.py            Control module integration tests
  test_flow.py               Flow module integration tests
  test_notes.py              Notes module integration tests
  test_schema.py             Schema validation tests (JSON + JSON Schema)
examples/
  demo.py                    Interactive demo (exercises all 3 modules)
```

## Modules & Methods

### Control (identity, projects, subscriptions)

| Method | Status | Notes |
|--------|--------|-------|
| `control/init` | Tested | Plaintext phase; triggers key exchange |
| `control/list/project` | Tested | |
| `control/create/project` | Tested | |
| `control/change/project` | Tested | |
| `control/remove/project` | Tested | Disconnects client if removing active project |
| `control/subscribe` | Tested | |
| `control/unsubscribe` | Tested | |
| `control/add/user/server` | Tested | |
| `control/add/user/project` | Tested | |
| `control/exit` | Tested | Graceful disconnect |

### Flow (directed code-location graphs)

| Method | Status | Notes |
|--------|--------|-------|
| `flow/get/all` | Tested | Returns all FlowInfo summaries |
| `flow/create` | Tested | |
| `flow/get` | Tested | Returns full flow with nodes |
| `flow/set` | Tested | Replace entire flow |
| `flow/set/info` | Tested | Update metadata |
| `flow/linked/to` | Tested | |
| `flow/unlock` | Tested | |
| `flow/add/node` | Tested | Supports optional flowId, parentId, childId, name, link |
| `flow/fork/node` | Tested | Forks from existing parent |
| `flow/set/node` | Tested | |
| `flow/remove/node` | Tested | |
| `flow/remove` | Tested | |

### Notes (tagged line annotations)

| Method | Status | Notes |
|--------|--------|-------|
| `notes/set` | Tested | Server fills author/modifiedBy; verifyFileHash required (even as null) |
| `notes/for/file` | Tested | |
| `notes/tag/count` | Tested | #hashtag extraction is server-side |
| `notes/search` | Tested | Full-text search |
| `notes/search/tags` | Tested | |
| `notes/search/columns` | Tested | Supports filter + order + page |
| `notes/remove` | Tested | |

## Server Quirks

- **Pidfile** — The server writes `config/numscull.pid` on startup. If the server crashes, this file must be deleted manually before restart.

The JSON schemas document `notes/set` (verifyFileHash required, NoteInput without author/modifiedBy) and `control/remove/project` (disconnects when removing active project) via `$comment` and schema structure.

## Running

### Quick start (create your own config)

```bash
# Create fresh config + identity
echo '{"port":5000}' > config/server.json
./numscull_native -r config --no-pidfile create_keypair python-client

# Start server
./numscull_native -r config -p 5000

# Run demo (separate terminal)
pip install -e .
python examples/demo.py
```

### Quick demo (use sample-config)

```bash
# Start server with pre-configured sample-config
./numscull_native -r sample-config -p 5000 --no-pidfile

# Run demo (separate terminal; auto-uses sample-config if config/ has no identities)
pip install -e .
python examples/demo.py
```

### Integration tests

```bash
pip install -e ".[dev]"
pytest tests/ -v
```

The test suite uses pytest fixtures: it provisions a fresh config, starts the server on port 5111, runs 40 tests (31 integration + 9 schema validation) across all three modules, then tears everything down. Tests are self-documenting: each test references the schema method and params.

## Current Status

- **Encryption**: Full NaCl Box protocol working (X25519 key exchange, counter nonces, 512-byte padded blocks).
- **Control module**: All 10 methods implemented and integration-tested.
- **Flow module**: All 12 methods implemented and integration-tested.
- **Notes module**: All 7 methods implemented and integration-tested.
- **Total**: 29 methods implemented, 40 pytest tests (31 integration + 9 schema validation, all passing).
