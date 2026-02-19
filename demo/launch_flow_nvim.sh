#!/bin/bash
# Wrapper to launch nvim with the numscull plugin for flow demo recording
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
exec nvim -u "$REPO_ROOT/demo/init_realistic.lua" \
  "$REPO_ROOT/demo/example_flow.py"
