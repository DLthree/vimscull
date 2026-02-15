## Building the annotation-tutorial demo

### Dependencies

```bash
# asciinema – terminal recorder
pip install asciinema

# svg-term-cli – converts .cast → animated .svg
npm install -g svg-term-cli
```

### Recording the cast

```bash
asciinema rec demo/annotation-tutorial.cast
```

Inside the recording session, walk through the plugin workflow:

1. Open a sample file in Neovim (`nvim lua/audit_notes/init.lua`)
2. Run `:AuditAdd` — type a note, press Enter
3. Run `:AuditEdit` — change the note text
4. Run `:AuditDelete` — confirm deletion
5. Exit Neovim, then press `Ctrl-D` to stop recording

### Converting to animated SVG

```bash
svg-term \
  --in  demo/annotation-tutorial.cast \
  --out demo/annotation-tutorial.svg \
  --window --no-cursor --padding 10
```

### Embedding in README

```markdown
## Demo

![Annotation Tutorial — add, edit, delete](demo/annotation-tutorial.svg)
```

Place above the `## Features` section. The SVG auto-plays inline on GitHub with no external dependencies.

---

## Building the flow-tutorial demo

### Recording the cast (automated)

```bash
python3 demo/record_flow_tutorial.py
```

This script uses `pexpect` to drive a full Neovim session that:

1. Creates a "Security Audit" flow with 3 nodes across the request pipeline
2. Navigates between nodes with `:FlowNext` / `:FlowPrev`
3. Creates a second "Bug: Negative Transfer" flow with different nodes
4. Switches between flows with `:FlowSelect` to show highlights change
5. Lists nodes with `:FlowList`

### Converting to animated SVG

```bash
svg-term \
  --in  demo/flow-tutorial.cast \
  --out demo/flow-tutorial.svg \
  --window --no-cursor --padding 10
```

### Embedding in README

```markdown
![Flow Tutorial — create, navigate, switch](demo/flow-tutorial.svg)
```
