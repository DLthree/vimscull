#!/usr/bin/env python3
"""
Test vimscull with the demo config to ensure everything works before recording.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

DEMO_DIR = Path(__file__).resolve().parent
REPO_ROOT = DEMO_DIR.parent
INIT_FILE = DEMO_DIR / "init_demo.lua"
SETUP_SCRIPT = DEMO_DIR / "setup_demo_server.py"
PORT = 5222


def find_python():
    venv = REPO_ROOT / ".venv" / "bin" / "python3"
    if venv.exists():
        return str(venv)
    return "python3"


def main():
    print("Testing vimscull with demo config...")
    
    python = find_python()
    
    # Start mock server
    print(f"\n1. Starting mock server on port {PORT}...")
    server_proc = subprocess.Popen(
        [python, str(SETUP_SCRIPT), "--port", str(PORT), "--project", "test-project"],
        stdout=subprocess.PIPE,
        text=True,
    )
    config_dir = server_proc.stdout.readline().strip()
    if not config_dir or not Path(config_dir).is_dir():
        print("ERROR: failed to start mock server", file=sys.stderr)
        server_proc.kill()
        sys.exit(1)
    print(f"✓ Mock server started, config_dir={config_dir}")
    
    try:
        # Set environment variables
        os.environ["NUMSCULL_CONFIG_DIR"] = config_dir
        os.environ["NUMSCULL_PORT"] = str(PORT)
        os.environ["USER"] = "demo-reviewer"
        
        # Run vimscull tests with the demo config
        print(f"\n2. Running vimscull tests with demo config...")
        test_cmd = [
            "nvim",
            "--headless",
            "-u", str(INIT_FILE),
            "-l", str(REPO_ROOT / "tests" / "run_tests.lua")
        ]
        
        result = subprocess.run(
            test_cmd,
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=60
        )
        
        # Check if tests passed
        output = result.stdout + result.stderr
        if "ALL TESTS PASSED" in output:
            print("✓ All tests passed!")
            return 0
        elif "PASS" in output:
            # Count passes and fails
            pass_count = output.count(" PASS:")
            fail_count = output.count(" FAIL:")
            print(f"Tests completed: {pass_count} passed, {fail_count} failed")
            if fail_count > 0:
                print("\nFailed tests (showing last 50 lines):")
                print("\n".join(output.split("\n")[-50:]))
            return 0 if fail_count == 0 else 1
        else:
            print("ERROR: Could not determine test results")
            print("\nOutput (last 50 lines):")
            print("\n".join(output.split("\n")[-50:]))
            return 1
            
    finally:
        print("\n3. Cleaning up...")
        server_proc.terminate()
        try:
            server_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            server_proc.kill()
        print("✓ Cleanup complete")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(f"Error during test: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)
