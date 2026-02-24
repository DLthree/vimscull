## Building the demo

### Dependencies

```bash
sudo apt-get install -y neovim libsodium-dev
pip install asciinema pexpect pynacl
npm install -g svg-term-cli        # for SVG conversion
```

### Quick start (Makefile)

```bash
cd demo/
make all        # deps → record → validate → svg
```

Individual targets:

| Target       | What it does                                              |
|--------------|-----------------------------------------------------------|
| `make deps`     | Check system deps, pre-install Neovim plugins          |
| `make record`   | Record the asciinema screencast                        |
| `make validate` | Verify the .cast file (errors, stalls, missing features) |
| `make svg`      | Convert .cast → animated SVG (needs svg-term-cli)      |
| `make clean`    | Remove generated .cast and .svg                        |
| `make help`     | Show all targets                                       |

### File overview

```
demo/
  demo_utils.py            shared constants, find_python()
  pre_setup_plugins.py     dependency check + plugin pre-install
  setup_demo_server.py     start mock server, pre-create projects
  record_unified_demo.py   pexpect-driven asciinema recording
  test_demo_recording.py   .cast + demo.log validation
  init_demo.lua            Neovim config for demo recording
  example.py               sample file shown in the demo
  Makefile                 single entry point
  BUILD.md                 this file
```

### How validation works

Two complementary sources:

1. **`.cast` file** — The asciinema recording captures all terminal output including
   `[NUMSCULL_DEMO]` markers emitted by `demo_log()` in `lua/numscull/init.lua`.
2. **`demo.log`** — When `NUMSCULL_DEMO=1` and `NUMSCULL_CONFIG_DIR` is set, each
   logged call also appends to `$NUMSCULL_CONFIG_DIR/demo.log`. This is more reliable
   than scraping terminal escape sequences.

`test_demo_recording.py` checks both sources and reports which commands were called.

### Embedding in README

```markdown
![vimscull Demo](demo/vimscull-demo.svg)
```
