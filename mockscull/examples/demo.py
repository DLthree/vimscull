#!/usr/bin/env python3
"""Interactive demo for the Numscull client — exercises control, flow, and notes modules."""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from numscull import NumscullClient, load_keypair


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _pp(label: str, resp: dict) -> None:
    print(f"\n→ {label}")
    print(json.dumps(resp, indent=2))


def _parse_args() -> argparse.Namespace:
    # Default config relative to project root (parent of examples/)
    project_root = Path(__file__).resolve().parent.parent
    default_config = project_root / "config"
    if not (default_config / "identities").exists() and (project_root / "sample-config").exists():
        default_config = project_root / "sample-config"
    default_pubkey = default_config / "users" / "python-client.pub"

    parser = argparse.ArgumentParser(description="Numscull client demo")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument("--pubkey", type=Path, default=default_pubkey)
    parser.add_argument("--config-dir", type=Path, default=default_config)
    parser.add_argument("--version", default="0.2.4")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    identity = args.pubkey.stem
    print(f"Using identity '{identity}' (from {args.pubkey})")

    _pub, secret = load_keypair(identity, args.config_dir)
    print(f"Loaded keypair for '{identity}'")

    with NumscullClient(host=args.host, port=args.port) as client:
        # ── 1. Init + encryption ────────────────────────────────
        resp = client.control_init(identity=identity, secret_key=secret, version=args.version)
        _pp("control/init", resp)
        print("Encryption established!")

        # ── 2. Control: projects ────────────────────────────────
        _pp("control/list/project", client.list_projects())

        _pp(
            "control/create/project",
            client.create_project(
                name="demo-project",
                repository="/tmp/demo-repo",
                owner_identity=identity,
            ),
        )

        _pp("control/change/project", client.change_project("demo-project"))

        # ── 3. Flow module ──────────────────────────────────────
        _pp("flow/get/all (empty)", client.flow_get_all())

        _pp(
            "flow/create",
            client.flow_create(
                name="Demo Flow",
                description="Created by python demo",
                created_date=_now(),
            ),
        )

        # Get the flow back
        get_all = client.flow_get_all()
        _pp("flow/get/all (after create)", get_all)

        flow_id = get_all.get("params", {}).get("flowInfos", [{}])[0].get("infoId")
        if flow_id is not None:
            _pp("flow/get", client.flow_get(flow_id))

            loc = {
                "fileId": {"uri": "file:///tmp/demo.py"},
                "line": 1,
                "startCol": 0,
                "endCol": 10,
            }
            add_resp = client.flow_add_node(
                location=loc,
                note="First node",
                color="#ff0000",
                flow_id=flow_id,
                name="entry",
            )
            _pp("flow/add/node", add_resp)

            node_id = add_resp.get("params", {}).get("nodeId")
            if node_id is not None:
                loc2 = {
                    "fileId": {"uri": "file:///tmp/demo.py"},
                    "line": 10,
                    "startCol": 0,
                    "endCol": 20,
                }
                _pp(
                    "flow/fork/node",
                    client.flow_fork_node(
                        location=loc2,
                        note="Forked node",
                        color="#00ff00",
                        parent_id=node_id,
                    ),
                )

            _pp("flow/get (with nodes)", client.flow_get(flow_id))
            _pp("flow/set/info", client.flow_set_info(flow_id, "Renamed Flow", "Updated desc", _now()))
            _pp("flow/linked/to", client.flow_linked_to(flow_id))
            _pp("flow/unlock", client.flow_unlock(flow_id))

        # ── 4. Notes module ─────────────────────────────────────
        note_obj = {
            "location": {"fileId": {"uri": "file:///tmp/demo.py"}, "line": 5},
            "text": "TODO: refactor this #demo #test",
            "createdDate": _now(),
            "modifiedDate": _now(),
        }
        _pp("notes/set", client.notes_set(note_obj))

        _pp("notes/for/file", client.notes_for_file("file:///tmp/demo.py"))
        _pp("notes/tag/count", client.notes_tag_count())
        _pp("notes/search", client.notes_search("refactor"))
        _pp("notes/search/tags", client.notes_search_tags("demo"))
        _pp(
            "notes/search/columns",
            client.notes_search_columns(
                filter={"author": identity},
                order={"by": "createdDate", "ordering": "descending"},
            ),
        )
        _pp("notes/remove", client.notes_remove("file:///tmp/demo.py", 5))

        # ── 5. Cleanup ─────────────────────────────────────────
        if flow_id is not None:
            _pp("flow/remove", client.flow_remove(flow_id))

        _pp("control/list/project (before cleanup)", client.list_projects())
        # Removing the active project disconnects us, so this is the last call
        _pp("control/remove/project", client.remove_project("demo-project"))

    print("\nDone.")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
