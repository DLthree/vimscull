"""Test helpers for Numscull integration tests."""

from datetime import datetime, timezone
from typing import Any, Dict


def params(resp: Dict[str, Any]) -> Dict[str, Any]:
    """Extract params/result from response. Init uses result, RPCs use params."""
    return resp.get("params", resp.get("result", resp))


def now() -> str:
    """Return current UTC timestamp in ISO format."""
    return datetime.now(timezone.utc).isoformat()


def make_location(
    uri: str = "file:///test.py",
    line: int = 1,
    start_col: int = 0,
    end_col: int = 5,
) -> Dict[str, Any]:
    """Build TextDocumentRange for flow/notes locations."""
    return {
        "fileId": {"uri": uri},
        "line": line,
        "startCol": start_col,
        "endCol": end_col,
    }
