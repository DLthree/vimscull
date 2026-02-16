"""Schema validation tests — schema/*.schema.json

Validates that schema files are valid JSON and valid JSON Schema.
Optionally validates that client request payloads conform to the schema.
"""

import json
from pathlib import Path

import pytest

try:
    import jsonschema
except ImportError:
    jsonschema = None

SCHEMA_DIR = Path(__file__).resolve().parent.parent / "schema"
SCHEMA_FILES = ["control.schema.json", "flow.schema.json", "notes.schema.json"]


@pytest.mark.parametrize("schema_file", SCHEMA_FILES)
def test_schema_valid_json(schema_file: str) -> None:
    """Each schema file must be valid JSON."""
    path = SCHEMA_DIR / schema_file
    with open(path) as f:
        data = json.load(f)
    assert isinstance(data, dict)
    assert "$schema" in data


@pytest.mark.skipif(jsonschema is None, reason="jsonschema not installed")
@pytest.mark.parametrize("schema_file", SCHEMA_FILES)
def test_schema_valid_jsonschema(schema_file: str) -> None:
    """Each schema file must be valid JSON Schema (draft-07)."""
    path = SCHEMA_DIR / schema_file
    with open(path) as f:
        schema = json.load(f)
    jsonschema.Draft7Validator.check_schema(schema)


@pytest.mark.skipif(jsonschema is None, reason="jsonschema not installed")
def test_control_init_request_valid() -> None:
    """control/init request conforms to schema."""
    with open(SCHEMA_DIR / "control.schema.json") as f:
        schema = json.load(f)
    validator = jsonschema.Draft7Validator(schema)
    request = {
        "id": 1,
        "method": "control/init",
        "params": {"identity": "test-client", "version": "0.2.4"},
    }
    validator.validate(request)


@pytest.mark.skipif(jsonschema is None, reason="jsonschema not installed")
def test_flow_create_request_valid() -> None:
    """flow/create request conforms to schema."""
    with open(SCHEMA_DIR / "flow.schema.json") as f:
        schema = json.load(f)
    validator = jsonschema.Draft7Validator(schema)
    request = {
        "id": 1,
        "method": "flow/create",
        "params": {
            "name": "Test Flow",
            "description": "A test",
            "createdDate": "2025-01-01T00:00:00+00:00",
        },
    }
    validator.validate(request)


@pytest.mark.skipif(jsonschema is None, reason="jsonschema not installed")
def test_notes_set_request_valid() -> None:
    """notes/set request conforms to schema (NoteInput, verifyFileHash required)."""
    with open(SCHEMA_DIR / "notes.schema.json") as f:
        schema = json.load(f)
    validator = jsonschema.Draft7Validator(schema)
    request = {
        "request": {
            "method": "notes/set",
            "params": {
                "note": {
                    "location": {"fileId": {"uri": "file:///test.py"}, "line": 1},
                    "text": "todo #tag",
                    "createdDate": "2025-01-01T00:00:00+00:00",
                    "modifiedDate": "2025-01-01T00:00:00+00:00",
                },
                "verifyFileHash": None,
            },
        },
        "response": {
            "method": "notes/set",
            "result": {
                "note": {
                    "location": {"fileId": {"uri": "file:///test.py"}, "line": 1},
                    "text": "todo #tag",
                    "author": "user",
                    "modifiedBy": "user",
                    "createdDate": "2025-01-01T00:00:00+00:00",
                    "modifiedDate": "2025-01-01T00:00:00+00:00",
                },
                "tagCount": [{"tag": "tag", "count": 1}],
            },
        },
    }
    validator.validate(request)
