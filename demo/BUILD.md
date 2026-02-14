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
