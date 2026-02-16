"""Numscull client with control, flow, and notes modules."""

import base64
import socket
from typing import Any, Dict, List, Optional

from .crypto import EncryptedChannel, do_key_exchange
from .transport import pack_plaintext, recv_plaintext


class NumscullClient:
    def __init__(self, host: str = "127.0.0.1", port: int = 5000):
        self.host = host
        self.port = port
        self.sock: socket.socket | None = None
        self.channel: EncryptedChannel | None = None
        self._msg_id = 0

    def __enter__(self) -> "NumscullClient":
        self.connect()
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def _next_id(self) -> int:
        self._msg_id += 1
        return self._msg_id

    def connect(self) -> None:
        self.sock = socket.create_connection((self.host, self.port))

    def close(self) -> None:
        if self.sock:
            self.sock.close()
            self.sock = None

    def _send(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        if self.channel:
            self.channel.send(payload)
            return self.channel.recv()
        if not self.sock:
            raise RuntimeError("Not connected")
        self.sock.sendall(pack_plaintext(payload))
        return recv_plaintext(self.sock)

    def send_raw(self, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        return self._send({
            "id": self._next_id(),
            "method": method,
            "params": params or {},
        })

    # ── Control module ──────────────────────────────────────────────

    def control_init(
        self, identity: str, secret_key: bytes, version: str = "0.2.4"
    ) -> Dict[str, Any]:
        if not self.sock:
            raise RuntimeError("Not connected")

        request = {
            "id": self._next_id(),
            "method": "control/init",
            "params": {"identity": identity, "version": version},
        }
        self.sock.sendall(pack_plaintext(request))
        resp = recv_plaintext(self.sock)

        server_pk_b64 = resp.get("params", {}).get("publicKey", {}).get("bytes")
        if not server_pk_b64:
            raise ValueError(f"No publicKey in init response: {resp}")
        server_pk = base64.b64decode(server_pk_b64)

        self.channel = do_key_exchange(self.sock, secret_key, server_pk)
        return resp

    def list_projects(self) -> Dict[str, Any]:
        return self.send_raw("control/list/project")

    def create_project(self, name: str, repository: str, owner_identity: str) -> Dict[str, Any]:
        return self.send_raw("control/create/project", {
            "name": name, "repository": repository, "ownerIdentity": owner_identity,
        })

    def change_project(self, name: str) -> Dict[str, Any]:
        return self.send_raw("control/change/project", {"name": name})

    def remove_project(self, name: str) -> Dict[str, Any]:
        return self.send_raw("control/remove/project", {"name": name})

    def subscribe(self, channels: List[int]) -> Dict[str, Any]:
        return self.send_raw("control/subscribe", {"channels": channels})

    def unsubscribe(self, channels: List[int]) -> Dict[str, Any]:
        return self.send_raw("control/unsubscribe", {"channels": channels})

    def add_user_server(self, identity: str, public_key_bytes: bytes) -> Dict[str, Any]:
        return self.send_raw("control/add/user/server", {
            "identity": identity,
            "publicKey": {"bytes": base64.b64encode(public_key_bytes).decode("ascii")},
        })

    def add_user_project(
        self, project: str, identity: str, permissions: Optional[Dict] = None,
    ) -> Dict[str, Any]:
        params: Dict[str, Any] = {"project": project, "identity": identity}
        if permissions is not None:
            params["permissions"] = permissions
        return self.send_raw("control/add/user/project", params)

    def exit(self) -> Dict[str, Any]:
        return self.send_raw("control/exit")

    # ── Flow module ─────────────────────────────────────────────────

    def flow_get_all(self) -> Dict[str, Any]:
        return self.send_raw("flow/get/all")

    def flow_create(self, name: str, description: str, created_date: str) -> Dict[str, Any]:
        return self.send_raw("flow/create", {
            "name": name, "description": description, "createdDate": created_date,
        })

    def flow_remove(self, flow_id: int) -> Dict[str, Any]:
        return self.send_raw("flow/remove", {"flowId": flow_id})

    def flow_get(self, flow_id: int) -> Dict[str, Any]:
        return self.send_raw("flow/get", {"flowId": flow_id})

    def flow_set(self, flow: Dict[str, Any]) -> Dict[str, Any]:
        return self.send_raw("flow/set", {"flow": flow})

    def flow_set_info(
        self, flow_id: int, name: str, description: str, modified_date: str,
    ) -> Dict[str, Any]:
        return self.send_raw("flow/set/info", {
            "flowId": flow_id, "name": name,
            "description": description, "modifiedDate": modified_date,
        })

    def flow_linked_to(self, flow_id: int) -> Dict[str, Any]:
        return self.send_raw("flow/linked/to", {"flowId": flow_id})

    def flow_unlock(self, flow_id: int) -> Dict[str, Any]:
        return self.send_raw("flow/unlock", {"flowId": flow_id})

    def flow_add_node(
        self,
        location: Dict[str, Any],
        note: str,
        color: str,
        *,
        flow_id: Optional[int] = None,
        parent_id: Optional[int] = None,
        child_id: Optional[int] = None,
        name: Optional[str] = None,
        link: Optional[int] = None,
        orphaned: Optional[str] = None,
    ) -> Dict[str, Any]:
        params: Dict[str, Any] = {"location": location, "note": note, "color": color}
        if flow_id is not None:
            params["flowId"] = flow_id
        if parent_id is not None:
            params["parentId"] = parent_id
        if child_id is not None:
            params["childId"] = child_id
        if name is not None:
            params["name"] = name
        if link is not None:
            params["link"] = link
        if orphaned is not None:
            params["orphaned"] = orphaned
        return self.send_raw("flow/add/node", params)

    def flow_fork_node(
        self,
        location: Dict[str, Any],
        note: str,
        color: str,
        parent_id: int,
        *,
        name: Optional[str] = None,
        link: Optional[int] = None,
        orphaned: Optional[str] = None,
    ) -> Dict[str, Any]:
        params: Dict[str, Any] = {
            "location": location, "note": note, "color": color, "parentId": parent_id,
        }
        if name is not None:
            params["name"] = name
        if link is not None:
            params["link"] = link
        if orphaned is not None:
            params["orphaned"] = orphaned
        return self.send_raw("flow/fork/node", params)

    def flow_set_node(self, node_id: int, node: Dict[str, Any]) -> Dict[str, Any]:
        return self.send_raw("flow/set/node", {"nodeId": node_id, "node": node})

    def flow_remove_node(self, node_id: int) -> Dict[str, Any]:
        return self.send_raw("flow/remove/node", {"nodeId": node_id})

    # ── Notes module ────────────────────────────────────────────────

    def notes_for_file(
        self, uri: str, *, page: Optional[Dict[str, int]] = None,
    ) -> Dict[str, Any]:
        params: Dict[str, Any] = {"fileId": {"uri": uri}}
        if page is not None:
            params["page"] = page
        return self.send_raw("notes/for/file", params)

    def notes_set(
        self, note: Dict[str, Any], *, verify_file_hash: Optional[str] = None,
    ) -> Dict[str, Any]:
        # Server fills author/modifiedBy from the authenticated identity
        clean = {k: v for k, v in note.items() if k not in ("author", "modifiedBy")}
        return self.send_raw("notes/set", {"note": clean, "verifyFileHash": verify_file_hash})

    def notes_remove(self, uri: str, line: int) -> Dict[str, Any]:
        return self.send_raw("notes/remove", {
            "location": {"fileId": {"uri": uri}, "line": line},
        })

    def notes_tag_count(self) -> Dict[str, Any]:
        return self.send_raw("notes/tag/count")

    def notes_search(
        self, text: str, *, page: Optional[Dict[str, int]] = None,
    ) -> Dict[str, Any]:
        params: Dict[str, Any] = {"text": text}
        if page is not None:
            params["page"] = page
        return self.send_raw("notes/search", params)

    def notes_search_tags(
        self, text: str, *, page: Optional[Dict[str, int]] = None,
    ) -> Dict[str, Any]:
        params: Dict[str, Any] = {"text": text}
        if page is not None:
            params["page"] = page
        return self.send_raw("notes/search/tags", params)

    def notes_search_columns(
        self,
        filter: Dict[str, Any],
        *,
        order: Optional[Dict[str, str]] = None,
        page: Optional[Dict[str, int]] = None,
    ) -> Dict[str, Any]:
        params: Dict[str, Any] = {"filter": filter}
        if order is not None:
            params["order"] = order
        if page is not None:
            params["page"] = page
        return self.send_raw("notes/search/columns", params)
