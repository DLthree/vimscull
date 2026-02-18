## Building the demos

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

## Notes tutorial (server-connected annotations)

Demonstrates: `:NumscullConnect`, `:NumscullProject`, `:NoteAdd`, `:NoteEdit`,
`:NoteShow`, `:NoteList`, `:NoteToggle`, `:NoteDelete`, `:NumscullDisconnect`.

### Recording

```bash
python3 demo/record_notes_tutorial.py
```

The script starts a mock Numscull server, records a full notes workflow in
Neovim, then shuts the server down.

### Converting to animated SVG

```bash
svg-term \
  --in  demo/notes-tutorial.cast \
  --out demo/notes-tutorial.svg \
  --window --no-cursor --padding 10
```

---

## Search & tags tutorial

Demonstrates: `:NoteAdd` with `#tags`, `:NoteSearch`, `:NoteSearchTags`,
`:NoteTagCount`, `:NoteList`.

### Recording

```bash
python3 demo/record_search_tutorial.py
```

### Converting to animated SVG

```bash
svg-term \
  --in  demo/search-tutorial.cast \
  --out demo/search-tutorial.svg \
  --window --no-cursor --padding 10
```

---

## Flow tutorial (server-connected code flows)

Demonstrates: `:NumscullConnect`, `:NumscullProject`, `:FlowCreate`,
`:FlowAddNode`, `:FlowNext`, `:FlowPrev`, `:FlowSelect`, `:FlowList`,
`:FlowShow`, `:FlowDelete`.

### Recording

```bash
python3 demo/record_flow_tutorial.py
```

The script starts a mock Numscull server, records a full flows workflow in
Neovim, then shuts the server down.

### Converting to animated SVG

```bash
svg-term \
  --in  demo/flow-tutorial.cast \
  --out demo/flow-tutorial.svg \
  --window --no-cursor --padding 10
```

---

## Legacy annotation tutorial

The original `record_tutorial.py` and `annotation-tutorial.*` files used the
old local-only `AuditAdd`/`AuditEdit`/`AuditDelete` commands. These are
superseded by the server-connected notes tutorial above.

---

## Embedding in README

```markdown
## Demos

### Notes (server-connected annotations)

![Notes Tutorial — connect, add, edit, search, delete](demo/notes-tutorial.svg)

### Search & Tags

![Search Tutorial — tagged notes, search, tag counts](demo/search-tutorial.svg)

### Flows

![Flow Tutorial — create, navigate, switch](demo/flow-tutorial.svg)
```
