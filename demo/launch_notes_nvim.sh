#!/bin/bash
# Wrapper to launch nvim with the numscull plugin for notes demo recording
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec nvim -u NONE \
  --cmd "set rtp+=$REPO_ROOT" \
  --cmd "set loadplugins" \
  -c "luafile $REPO_ROOT/demo/init_notes_demo.lua" \
  "$REPO_ROOT/demo/example.py"
