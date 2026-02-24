#!/usr/bin/env python3
"""
Test script to verify demo recording without building SVG.
Checks the .cast file for errors, stalls, and validates it completes properly.
"""

import json
import sys
from pathlib import Path

DEMO_DIR = Path(__file__).resolve().parent
CAST_FILE = DEMO_DIR / "vimscull-demo.cast"


def check_cast_file():
    """Check the cast file for issues."""
    if not CAST_FILE.exists():
        print(f"❌ Cast file not found: {CAST_FILE}")
        return False
    
    print(f"✓ Cast file found: {CAST_FILE}")
    print(f"  Size: {CAST_FILE.stat().st_size / 1024:.1f} KB")
    
    # Read and parse cast file
    with open(CAST_FILE) as f:
        lines = f.readlines()
    
    if len(lines) < 2:
        print("❌ Cast file is too short")
        return False
    
    # Parse header
    header = json.loads(lines[0])
    print(f"  Duration: {header.get('duration', 'unknown')} seconds")
    print(f"  Terminal: {header.get('width', '?')}x{header.get('height', '?')}")
    
    # Check for issues in the output
    errors = []
    timeouts = []
    floats = []
    last_timestamp = 0
    max_timestamp = 0
    
    for i, line in enumerate(lines[1:], start=2):
        try:
            timestamp, event_type, data = json.loads(line)
            max_timestamp = max(max_timestamp, timestamp)
            
            # Check for long gaps (stalls) - but ignore gaps in the last 10% of recording
            if timestamp < max_timestamp * 0.9 and timestamp - last_timestamp > 10:
                timeouts.append(f"Line {i}: {timestamp - last_timestamp:.1f}s gap")
            last_timestamp = timestamp
            
            if event_type == "o":  # output event
                # Check for error messages
                if "error" in data.lower() or "fail" in data.lower():
                    errors.append(f"Line {i}: {data[:80]}")
                
                # Check for timeout messages
                if "timeout" in data.lower():
                    timeouts.append(f"Line {i}: timeout detected")
                
                # Check for floating window prompts
                if "Note (use" in data or "Edit Note (inline)" in data:
                    floats.append(f"Line {i}: floating prompt detected")
        except json.JSONDecodeError:
            print(f"⚠️  Warning: Could not parse line {i}")
    
    # Report findings
    print(f"\n📊 Analysis:")
    print(f"  Total events: {len(lines) - 1}")
    print(f"  Duration: {last_timestamp:.1f}s")
    
    issues_found = False
    
    if errors:
        print(f"\n❌ Errors found ({len(errors)}):")
        for error in errors[:5]:  # Show first 5
            print(f"  {error}")
        issues_found = True
    else:
        print(f"\n✓ No errors found")
    
    if timeouts:
        print(f"\n❌ Timeouts/stalls found ({len(timeouts)}):")
        for timeout in timeouts[:5]:
            print(f"  {timeout}")
        issues_found = True
    else:
        print(f"✓ No timeouts/stalls found")
    
    if floats:
        print(f"\n❌ Floating prompts found ({len(floats)}):")
        for float_msg in floats[:5]:
            print(f"  {float_msg}")
        issues_found = True
    else:
        print(f"✓ No floating prompts found")
    
    # Check for expected content/commands (use looser matching)
    full_output = ""
    for line in lines[1:]:
        try:
            _, event_type, data = json.loads(line)
            if event_type == "o":
                full_output += data
        except:
            pass
    
    print(f"\n📝 Content verification:")
    # Check for key indicators
    indicators = {
        "Notes": "Consider using argon2" in full_output or "pbkdf2" in full_output or "#security" in full_output,
        "Flows": "Security" in full_output or "Audit" in full_output,
        "Commands": ":Flow" in full_output or "FlowCreate" in full_output,
    }
    
    for key, found in indicators.items():
        if found:
            print(f"  ✓ {key} content found")
        else:
            print(f"  ❌ {key} content NOT FOUND")
            issues_found = True
    
    # Check for demo logging output (NUMSCULL_DEMO markers)
    demo_functions = [
        "NumscullConnect",
        "NumscullProject", 
        "NoteAdd",
        "NoteList",
        "FlowCreate",
        "FlowAddNode",
        "FlowList",
    ]
    
    print(f"\n🔍 Function call verification (NUMSCULL_DEMO logging):")
    for func in demo_functions:
        start_marker = f"[NUMSCULL_DEMO] {func}: START"
        end_marker = f"[NUMSCULL_DEMO] {func}: END"
        
        if start_marker in full_output:
            if end_marker in full_output:
                print(f"  ✓ {func} called and completed (START/END found)")
            else:
                # Some functions (like List, Show) don't return immediately because they open buffers
                print(f"  ✓ {func} called (START found, END may be deferred for UI functions)")
        else:
            print(f"  ❌ {func} NOT CALLED (no START marker)")
            issues_found = True
    
    # Note: Connection info may not be visible if it succeeds silently
    if "127.0.0.1" in full_output or "5222" in full_output:
        print(f"\n  ✓ Connection info found")
    else:
        print(f"\n  ℹ️  Connection info not visible (check NUMSCULL_DEMO logging above)")
    
    # Check for long gaps (>60s indicates potential hang)
    long_gaps = []
    for t in timeouts:
        if "gap" in t:
            try:
                gap_str = t.split("gap")[1].split("s")[0].strip()
                if gap_str and float(gap_str) > 60:
                    long_gaps.append(t)
            except (ValueError, IndexError):
                pass
    
    if long_gaps:
        print(f"\n⚠️  Warning: Very long gaps detected (>60s):")
        for gap in long_gaps[:3]:
            print(f"  {gap}")
    
    if issues_found:
        print(f"\n❌ Demo has issues - see above")
        return False
    else:
        print(f"\n✅ Demo looks good!")
        return True


if __name__ == "__main__":
    success = check_cast_file()
    sys.exit(0 if success else 1)
