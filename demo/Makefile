PYTHON ?= $(shell test -x ../.venv/bin/python3 && echo ../.venv/bin/python3 || echo python3)
CAST   := vimscull-demo.cast
SVG    := vimscull-demo.svg

.PHONY: all deps record validate svg clean

## all      – full pipeline: deps check, record, validate, convert to SVG
all: deps record validate svg

## deps     – check / install system dependencies and Neovim plugins
deps:
	$(PYTHON) pre_setup_plugins.py

## record   – record the asciinema screencast
record:
	$(PYTHON) record_unified_demo.py

## validate – check the .cast file for errors, stalls, missing features
validate:
	$(PYTHON) test_demo_recording.py

## svg      – convert the .cast to an animated SVG (requires svg-term-cli)
svg:
	svg-term --in $(CAST) --out $(SVG) --window --no-cursor --padding 10
	@echo "SVG written to $(SVG)"

## clean    – remove generated artefacts
clean:
	rm -f $(CAST) $(SVG)

## help     – show available targets
help:
	@grep '^## ' Makefile | sed 's/^## //'
