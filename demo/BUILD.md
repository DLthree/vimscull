## Building the demo

### Dependencies

```bash
# asciinema – terminal recorder
pip install asciinema

# pexpect – drives terminal sessions programmatically
pip install pexpect

# pynacl – NaCl bindings for mock server
pip install pynacl

# svg-term-cli – converts .cast → animated .svg
npm install -g svg-term-cli
```

---

## Unified demo (all features)

Demonstrates: `:NumscullConnect`, `:NumscullProject`, `:NoteAdd`, `:NoteEdit` (float editor),
`:NoteList`, `:FlowCreate`, `:FlowAddNode`, `:FlowList`, `:NumscullDisconnect`.

### Recording

```bash
# Pre-install plugins (run once, or when plugins change)
python3 demo/pre_setup_plugins.py

# Record the demo
python3 demo/record_unified_demo.py
```

The script:
1. Pre-installs Neovim plugins (lazy.nvim, lualine, dressing.nvim)
2. Starts a mock Numscull server
3. Records a complete workflow showing all features
4. Shuts down the server

### Converting to animated SVG

```bash
svg-term \
  --in  demo/vimscull-demo.cast \
  --out demo/vimscull-demo.svg \
  --window --no-cursor --padding 10
```

---

## Testing the demo config

Before recording, test that vimscull works with the demo config:

```bash
python3 demo/test_demo_config.py
```

---

## Embedding in README

```markdown
## Demo

![vimscull Demo — Connect, add/edit notes with float editor, create flows, add nodes](demo/vimscull-demo.svg)
```
