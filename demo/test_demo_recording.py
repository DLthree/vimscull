#!/usr/bin/env python3
"""Validate a recorded .cast file without building the SVG.

Checks structure, detects errors/stalls, and verifies that all expected
Numscull commands appear in the output (via NUMSCULL_DEMO markers).

Two validation sources are used:
  1. The .cast file itself (terminal output captured by asciinema)
  2. The demo.log file written by NUMSCULL_DEMO logging (more reliable)

Exit code 0 = pass, 1 = issues found.
"""

import json
import sys
from pathlib import Path

from demo_utils import CAST_FILE, DEMO_DIR

# Commands the demo is expected to exercise.
EXPECTED_COMMANDS = [
    "NumscullConnect",
    "NumscullProject",
    "NoteAdd",
    "NoteList",
    "FlowCreate",
    "FlowAddNode",
    "FlowList",
]

# Strings that prove the relevant feature appeared in the terminal output.
CONTENT_CHECKS = {
    "Notes": ["argon2", "pbkdf2", "#security"],
    "Flows": ["Security", "Audit"],
    "Commands": [":Flow", "FlowCreate"],
}

# Thresholds
MAX_GAP_SECONDS = 10   # flag gaps longer than this
HANG_THRESHOLD = 60    # gaps this long likely indicate a hang


# ── helpers ──────────────────────────────────────────────────────


def _collect_output(lines):
    """Parse .cast events.  Returns (full_output_str, duration, gap_list)."""
    parts = []
    last_ts = 0.0
    max_ts = 0.0
    gaps = []  # (line_number, gap_seconds)

    for lineno, raw in enumerate(lines[1:], start=2):
        try:
            ts, event_type, data = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            continue

        max_ts = max(max_ts, ts)
        gap = ts - last_ts
        if gap > MAX_GAP_SECONDS:
            gaps.append((lineno, gap))
        last_ts = ts

        if event_type == "o":
            parts.append(data)

    return "".join(parts), max_ts, gaps


def _find_demo_log():
    """Try to locate the demo.log produced during recording."""
    # The log lives inside the temp config dir.  The recording script
    # prints the config_dir, but we don't have it here.  Scan /tmp for
    # the most recent numscull-demo-*/demo.log.
    import glob

    candidates = sorted(
        glob.glob("/tmp/numscull-demo-*/demo.log"),
        key=lambda p: Path(p).stat().st_mtime,
        reverse=True,
    )
    return Path(candidates[0]) if candidates else None


# ── checks ───────────────────────────────────────────────────────


def check_cast_structure(lines):
    """Validate basic .cast structure.  Returns (header, ok)."""
    if len(lines) < 2:
        print("FAIL  cast file too short")
        return None, False
    header = json.loads(lines[0])
    print(f"file     {CAST_FILE.name}  ({CAST_FILE.stat().st_size / 1024:.1f} KB)")
    print(f"term     {header.get('width', '?')}x{header.get('height', '?')}")
    return header, True


def check_errors(lines):
    """Scan terminal output for error / timeout strings."""
    hits = []
    for lineno, raw in enumerate(lines[1:], start=2):
        try:
            _, etype, data = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            continue
        if etype != "o":
            continue
        low = data.lower()
        if "error" in low or "fail" in low or "timeout" in low:
            hits.append((lineno, data.rstrip()[:80]))
    return hits


def check_gaps(gaps, duration):
    """Classify gaps into pauses and potential hangs."""
    # Ignore gaps in the final 10 % (shutdown can be slow).
    early = [(ln, g) for ln, g in gaps if g < duration * 0.9]
    hangs = [(ln, g) for ln, g in early if g >= HANG_THRESHOLD]
    pauses = [(ln, g) for ln, g in early if g < HANG_THRESHOLD]
    return hangs, pauses


def check_content(full_output):
    """Verify that expected feature strings appear in the output."""
    missing = {}
    for label, needles in CONTENT_CHECKS.items():
        if not any(n in full_output for n in needles):
            missing[label] = needles
    return missing


def check_markers_in_output(full_output):
    """Check for NUMSCULL_DEMO START/END markers in .cast output."""
    results = {}  # cmd -> (has_start, has_end)
    for cmd in EXPECTED_COMMANDS:
        start = f"[NUMSCULL_DEMO] {cmd}: START" in full_output
        end = f"[NUMSCULL_DEMO] {cmd}: END" in full_output
        results[cmd] = (start, end)
    return results


def check_markers_in_log(log_path):
    """Check for NUMSCULL_DEMO START/END markers in the demo.log file."""
    if not log_path or not log_path.exists():
        return None
    text = log_path.read_text()
    results = {}
    for cmd in EXPECTED_COMMANDS:
        start = f"[NUMSCULL_DEMO] {cmd}: START" in text
        end = f"[NUMSCULL_DEMO] {cmd}: END" in text
        results[cmd] = (start, end)
    return results


def check_floating_prompts(full_output):
    """Detect unwanted floating-window prompts that leaked into recording."""
    bad = []
    if "Note (use" in full_output:
        bad.append("Note (use \\n ...) prompt leaked")
    if "Edit Note (inline)" in full_output:
        bad.append("Edit Note (inline) prompt leaked")
    return bad


# ── main ─────────────────────────────────────────────────────────


def main():
    if not CAST_FILE.exists():
        print(f"FAIL  cast file not found: {CAST_FILE}")
        return False

    lines = CAST_FILE.read_text().splitlines()
    header, ok = check_cast_structure(lines)
    if not ok:
        return False

    full_output, duration, gaps = _collect_output(lines)
    event_count = len(lines) - 1
    print(f"events   {event_count}")
    print(f"duration {duration:.1f}s")

    issues = False

    # ── errors ───────────────────────────────────────────────────
    errors = check_errors(lines)
    if errors:
        print(f"\n[WARN] error strings ({len(errors)}):")
        for ln, snip in errors[:5]:
            print(f"  line {ln}: {snip}")
        issues = True
    else:
        print("\nerrors   none")

    # ── floating prompts ─────────────────────────────────────────
    prompts = check_floating_prompts(full_output)
    if prompts:
        for p in prompts:
            print(f"[FAIL] {p}")
        issues = True

    # ── gaps / hangs ─────────────────────────────────────────────
    hangs, pauses = check_gaps(gaps, duration)
    if hangs:
        print(f"\n[FAIL] possible hangs (>{HANG_THRESHOLD}s):")
        for ln, g in hangs[:3]:
            print(f"  line {ln}: {g:.1f}s")
        issues = True
    if pauses:
        print(f"pauses   {len(pauses)} (>{MAX_GAP_SECONDS}s, likely ok)")

    # ── content ──────────────────────────────────────────────────
    missing = check_content(full_output)
    print("\ncontent:")
    for label in CONTENT_CHECKS:
        status = "MISSING" if label in missing else "ok"
        print(f"  {label:10s} {status}")
    if missing:
        issues = True

    # ── NUMSCULL_DEMO markers ────────────────────────────────────
    cast_markers = check_markers_in_output(full_output)
    log_path = _find_demo_log()
    log_markers = check_markers_in_log(log_path)

    print(f"\nfunction calls (NUMSCULL_DEMO):")
    if log_path:
        print(f"  log file: {log_path}")
    source_label = "log" if log_markers else "cast"
    markers = log_markers or cast_markers

    for cmd in EXPECTED_COMMANDS:
        has_start, has_end = markers.get(cmd, (False, False))
        if has_start and has_end:
            status = "ok"
        elif has_start:
            # UI-opening commands may not emit END until the buffer closes.
            status = "ok (START only)"
        else:
            status = "MISSING"
            issues = True
        print(f"  {cmd:22s} {status}  [{source_label}]")

    # ── verdict ──────────────────────────────────────────────────
    print()
    if issues:
        print("RESULT  issues found")
    else:
        print("RESULT  ok")
    return not issues


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
