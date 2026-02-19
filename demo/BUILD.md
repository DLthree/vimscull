## Building the demo

### Dependencies

```bash
# System dependencies
sudo apt-get install -y neovim libsodium-dev

# Python dependencies
pip install asciinema pexpect pynacl

# Node.js dependency for SVG conversion
npm install -g svg-term-cli
```

**Note**: libsodium-dev is required for the NaCl encryption used by vimscull. Without it, crypto operations will fail.

---

## Unified demo (all features)

Demonstrates: `:NumscullConnect`, `:NumscullProject`, `:NoteAdd`, `:NoteEdit` (inline editor),
`:NoteList`, `:FlowCreate`, `:FlowAddNode`, `:FlowList`, `:NumscullDisconnect`.

### Recording

```bash
# Pre-install plugins (run once, or when plugins change)
# This also checks for required dependencies
python3 demo/pre_setup_plugins.py

# Record the demo
python3 demo/record_unified_demo.py
```

The script:
1. Pre-installs Neovim plugins (lazy.nvim, lualine, dressing.nvim)
2. Checks for required system dependencies (libsodium-dev, pynacl, neovim, asciinema)
3. Starts a mock Numscull server
4. Records a complete workflow showing all features
5. Shuts down the server

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
