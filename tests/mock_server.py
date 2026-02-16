#!/usr/bin/env python3
"""Mock Numscull server with full NaCl encryption. In-memory storage for notes, flows, projects."""

import argparse
import base64
import json
import os
import re
import socket
import sys
import threading
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

# Add mockscull to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "mockscull" / "src"))

from nacl.bindings import crypto_box, crypto_box_open, crypto_scalarmult_base

HEADER_SIZE = 10
BLOCK_SIZE = 512
TAG_LEN = 16
NONCE_LEN = 24
KEY_LEN = 32
ENCRYPTED_BLOCK_SIZE = BLOCK_SIZE + TAG_LEN


def read_exact(sock: socket.socket, nbytes: int) -> bytes:
    chunks, received = [], 0
    while received < nbytes:
        chunk = sock.recv(min(nbytes - received, 4096))
        if not chunk:
            raise EOFError("Socket closed while reading data")
        chunks.append(chunk)
        received += len(chunk)
    return b"".join(chunks)


def pack_plaintext_bytes(payload: bytes) -> bytes:
    length_str = f"{len(payload):0>{HEADER_SIZE}}"
    return length_str.encode("ascii") + payload


def pack_plaintext(message: dict) -> bytes:
    return pack_plaintext_bytes(json.dumps(message).encode("utf-8"))


def recv_plaintext(sock: socket.socket) -> dict:
    header = read_exact(sock, HEADER_SIZE)
    payload_len = int(header.decode("ascii"))
    payload = read_exact(sock, payload_len)
    return json.loads(payload.decode("utf-8"))


def counter_nonce(counter: int) -> bytes:
    import struct
    return struct.pack("<Q", counter) + b"\x00" * 16


def generate_x25519_keypair() -> tuple[bytes, bytes]:
    sk = os.urandom(32)
    pk = crypto_scalarmult_base(sk)
    return pk, sk


class EncryptedChannel:
    def __init__(self, sock, ours_recv_sk, ours_send_sk, theirs_recv_pk, theirs_send_pk):
        self.sock = sock
        self.ours_recv_sk = ours_recv_sk
        self.ours_send_sk = ours_send_sk
        self.theirs_recv_pk = theirs_recv_pk
        self.theirs_send_pk = theirs_send_pk
        self.send_nonce = 1
        self.recv_nonce = 1

    def send(self, message: dict) -> None:
        import struct
        json_bytes = json.dumps(message).encode("utf-8")
        framed = pack_plaintext_bytes(json_bytes)
        if len(framed) > BLOCK_SIZE - 2:
            raise ValueError(f"Message too large")
        block = bytearray(BLOCK_SIZE)
        struct.pack_into("<H", block, 0, len(framed))
        block[2:2 + len(framed)] = framed
        block[2 + len(framed):] = os.urandom(BLOCK_SIZE - 2 - len(framed))
        nonce = counter_nonce(self.send_nonce)
        self.send_nonce += 1
        ct = crypto_box(bytes(block), nonce, self.theirs_send_pk, self.ours_send_sk)
        self.sock.sendall(ct)

    def recv(self) -> dict:
        import struct
        ct = read_exact(self.sock, ENCRYPTED_BLOCK_SIZE)
        nonce = counter_nonce(self.recv_nonce)
        self.recv_nonce += 1
        block = crypto_box_open(ct, nonce, self.theirs_recv_pk, self.ours_recv_sk)
        msg_len = struct.unpack("<H", block[:2])[0]
        data = block[2:2 + msg_len]
        header = data[:HEADER_SIZE]
        json_len = int(header.decode("ascii"))
        json_bytes = data[HEADER_SIZE:HEADER_SIZE + json_len]
        while len(json_bytes) < json_len:
            ct = read_exact(self.sock, ENCRYPTED_BLOCK_SIZE)
            nonce = counter_nonce(self.recv_nonce)
            self.recv_nonce += 1
            block = crypto_box_open(ct, nonce, self.theirs_recv_pk, self.ours_recv_sk)
            msg_len = struct.unpack("<H", block[:2])[0]
            json_bytes += bytes(block[2:2 + msg_len])
        return json.loads(json_bytes[:json_len].decode("utf-8"))


def server_key_exchange(sock, identity: str, client_pk: bytes, server_sk: bytes) -> EncryptedChannel:
    """Server-side key exchange. Client sends first (server's encrypted keys)."""
    import struct
    server_recv_pk, server_recv_sk = generate_x25519_keypair()
    server_send_pk, server_send_sk = generate_x25519_keypair()
    block = bytearray(BLOCK_SIZE)
    block[:KEY_LEN] = server_recv_pk
    block[KEY_LEN:KEY_LEN * 2] = server_send_pk
    block[KEY_LEN * 2:] = os.urandom(BLOCK_SIZE - KEY_LEN * 2)
    server_nonce = os.urandom(NONCE_LEN)
    server_ct = crypto_box(bytes(block), server_nonce, client_pk, server_sk)
    sock.sendall(server_nonce + server_ct)
    client_exchange = read_exact(sock, NONCE_LEN + ENCRYPTED_BLOCK_SIZE)
    client_nonce = client_exchange[:NONCE_LEN]
    client_ct = client_exchange[NONCE_LEN:]
    client_block = crypto_box_open(client_ct, client_nonce, client_pk, server_sk)
    client_recv_pk = client_block[:KEY_LEN]
    client_send_pk = client_block[KEY_LEN:KEY_LEN * 2]
    return EncryptedChannel(
        sock, server_recv_sk, server_send_sk, client_send_pk, client_recv_pk
    )


def extract_hashtags(text: str) -> set:
    return set(re.findall(r"#(\w+)", text))


class MockServer:
    def __init__(self, config_dir: Path):
        self.config_dir = Path(config_dir)
        self.projects = {}
        self.active_project = None
        self.identity = None
        server_keypair_path = self.config_dir / "server.keypair"
        if server_keypair_path.exists():
            raw = server_keypair_path.read_bytes()
            if len(raw) == 64:
                self.server_pk = raw[:32]
                self.server_sk = raw[32:]
            else:
                self._gen_keypair()
        else:
            self._gen_keypair()
            self.config_dir.mkdir(parents=True, exist_ok=True)
            (self.config_dir / "server.keypair").write_bytes(self.server_pk + self.server_sk)

    def _gen_keypair(self):
        self.server_pk, self.server_sk = generate_x25519_keypair()

    def _get_client_pk(self, identity: str) -> bytes:
        pub_path = self.config_dir / "users" / f"{identity}.pub"
        if not pub_path.exists():
            pub_path = self.config_dir / "identities" / identity
            if pub_path.exists():
                return pub_path.read_bytes()[:32]
            raise ValueError(f"Unknown identity: {identity}")
        return pub_path.read_bytes()

    def _handle_init(self, sock, req: dict) -> dict:
        identity = (req.get("params") or {}).get("identity", "unknown")
        version = (req.get("params") or {}).get("version", "0.2.4")
        try:
            client_pk = self._get_client_pk(identity)
        except (ValueError, FileNotFoundError):
            return {"id": req.get("id"), "method": "control/init", "params": {"valid": False, "publicKey": {"bytes": base64.b64encode(self.server_pk).decode("ascii")}}}
        self.identity = identity
        return {"id": req.get("id"), "method": "control/init", "params": {"valid": True, "publicKey": {"bytes": base64.b64encode(self.server_pk).decode("ascii")}}}

    def _handle_request(self, channel: EncryptedChannel, msg: dict) -> dict:
        method = msg.get("method", "")
        params = msg.get("params") or {}
        req_id = msg.get("id", 0)
        if method == "control/list/project":
            projects = [{"name": k, "repository": v.get("repository", ""), "ownerIdentity": v.get("ownerIdentity", "")} for k, v in self.projects.items()]
            return {"id": req_id, "method": method, "result": {"projects": projects}}
        if method == "control/create/project":
            name = params.get("name", "")
            self.projects[name] = {"repository": params.get("repository", ""), "ownerIdentity": params.get("ownerIdentity", ""), "notes": {}, "flows": {}, "flow_infos": {}, "next_flow_id": 1, "next_node_id": {}}
            return {"id": req_id, "method": method, "result": {}}
        if method == "control/change/project":
            self.active_project = params.get("name")
            return {"id": req_id, "method": method, "result": {"name": self.active_project}}
        if method == "control/remove/project":
            if params.get("name") in self.projects:
                del self.projects[params.get("name")]
            if self.active_project == params.get("name"):
                self.active_project = None
            return {"id": req_id, "method": method, "result": {}}
        if method == "control/subscribe":
            return {"id": req_id, "method": method, "result": {"channels": params.get("channels", [])}}
        if method == "control/unsubscribe":
            return {"id": req_id, "method": method, "result": {"channels": params.get("channels", [])}}
        if method == "control/exit":
            return {"id": req_id, "method": method, "result": {}}
        if not self.active_project or self.active_project not in self.projects:
            return {"id": req_id, "method": "control/error", "result": {"reason": "no active project"}}
        proj = self.projects[self.active_project]
        now = datetime.now(timezone.utc).isoformat()
        if method == "notes/set":
            note = params.get("note", {})
            loc = note.get("location", {})
            uri = (loc.get("fileId") or {}).get("uri", "")
            line = loc.get("line", 0)
            key = (uri, line)
            full_note = {"location": loc, "text": note.get("text", ""), "author": self.identity, "modifiedBy": self.identity, "createdDate": note.get("createdDate", now), "modifiedDate": note.get("modifiedDate", now), "orphaned": note.get("orphaned")}
            proj["notes"][key] = full_note
            tags = defaultdict(int)
            for n in proj["notes"].values():
                for t in extract_hashtags(n.get("text", "")):
                    tags[t] += 1
            return {"id": req_id, "method": method, "result": {"note": full_note, "tagCount": [{"tag": k, "count": v} for k, v in tags.items()]}}
        if method == "notes/for/file":
            file_id = params.get("fileId", {})
            uri = file_id.get("uri", "")
            notes = [n for k, n in proj["notes"].items() if k[0] == uri]
            notes.sort(key=lambda n: n.get("location", {}).get("line", 0))
            page = params.get("page", {})
            idx = page.get("index", 0)
            size = page.get("size", 100)
            paginated = notes[idx:idx + size]
            max_page = max(0, (len(notes) - 1) // size) if size > 0 else 0
            return {"id": req_id, "method": method, "result": {"fileId": file_id, "notes": paginated, "maxPage": max_page}}
        if method == "notes/remove":
            loc = params.get("location", {})
            uri = (loc.get("fileId") or {}).get("uri", "")
            line = loc.get("line", 0)
            key = (uri, line)
            if key in proj["notes"]:
                del proj["notes"][key]
            tags = defaultdict(int)
            for n in proj["notes"].values():
                for t in extract_hashtags(n.get("text", "")):
                    tags[t] += 1
            return {"id": req_id, "method": method, "result": {"location": loc, "tagCount": [{"tag": k, "count": v} for k, v in tags.items()]}}
        if method == "notes/search":
            text = params.get("text", "").lower()
            notes = [n for n in proj["notes"].values() if text in (n.get("text", "") or "").lower()]
            page = params.get("page", {})
            idx = page.get("index", 0)
            size = page.get("size", 100)
            paginated = notes[idx:idx + size]
            max_page = max(0, (len(notes) - 1) // size) if size > 0 else 0
            return {"id": req_id, "method": method, "result": {"notes": paginated, "maxPage": max_page}}
        if method == "notes/search/tags":
            text = params.get("text", "").lower()
            notes = [n for n in proj["notes"].values() if text in extract_hashtags(n.get("text", ""))]
            page = params.get("page", {})
            idx = page.get("index", 0)
            size = page.get("size", 100)
            paginated = notes[idx:idx + size]
            max_page = max(0, (len(notes) - 1) // size) if size > 0 else 0
            return {"id": req_id, "method": method, "result": {"notes": paginated, "maxPage": max_page}}
        if method == "notes/search/columns":
            flt = params.get("filter") or {}
            notes = list(proj["notes"].values())
            if flt.get("author"):
                notes = [n for n in notes if n.get("author") == flt.get("author")]
            page = params.get("page", {})
            idx = page.get("index", 0)
            size = page.get("size", 100)
            paginated = notes[idx:idx + size]
            max_page = max(0, (len(notes) - 1) // size) if size > 0 else 0
            return {"id": req_id, "method": method, "result": {"notes": paginated, "maxPage": max_page}}
        if method == "notes/tag/count":
            tags = defaultdict(int)
            for n in proj["notes"].values():
                for t in extract_hashtags(n.get("text", "")):
                    tags[t] += 1
            return {"id": req_id, "method": method, "result": {"tags": [{"tag": k, "count": v} for k, v in tags.items()]}}
        if method == "flow/create":
            fid = proj["next_flow_id"]
            proj["next_flow_id"] += 1
            proj["flow_infos"][fid] = {"infoId": fid, "name": params.get("name", ""), "description": params.get("description", ""), "author": self.identity, "modifiedBy": self.identity, "createdDate": params.get("createdDate", now), "modifiedDate": now}
            proj["flows"][fid] = {"info": proj["flow_infos"][fid], "nodes": {}}
            proj["next_node_id"][fid] = 1
            return {"id": req_id, "method": method, "result": {"flow": proj["flows"][fid]}}
        if method == "flow/get/all":
            infos = list(proj["flow_infos"].values())
            return {"id": req_id, "method": method, "result": {"flowInfos": infos}}
        if method == "flow/get":
            fid = params.get("flowId")
            flow = proj["flows"].get(fid)
            if not flow:
                return {"id": req_id, "method": "control/error", "result": {"reason": "flow not found"}}
            return {"id": req_id, "method": method, "result": {"flow": flow}}
        if method == "flow/add/node":
            loc = params.get("location", {})
            fid = params.get("flowId")
            if not fid:
                fid = next(iter(proj["flows"].keys()), None)
            if not fid:
                return {"id": req_id, "method": "control/error", "result": {"reason": "no flow"}}
            nid = proj["next_node_id"][fid]
            proj["next_node_id"][fid] += 1
            node = {"location": loc, "note": params.get("note", ""), "color": params.get("color", "#888"), "outEdges": [], "inEdges": [], "name": params.get("name", "")}
            if params.get("parentId"):
                node["inEdges"] = [params["parentId"]]
                if params["parentId"] in proj["flows"][fid]["nodes"]:
                    proj["flows"][fid]["nodes"][params["parentId"]]["outEdges"].append(nid)
            if params.get("childId"):
                node["outEdges"] = [params["childId"]]
            proj["flows"][fid]["nodes"][nid] = node
            return {"id": req_id, "method": method, "result": {"flowId": fid, "nodeId": nid}}
        if method == "flow/fork/node":
            loc = params.get("location", {})
            parent_id = params.get("parentId")
            fid = next((f for f, fl in proj["flows"].items() if parent_id in fl["nodes"]), None)
            if not fid:
                return {"id": req_id, "method": "control/error", "result": {"reason": "parent not found"}}
            nid = proj["next_node_id"][fid]
            proj["next_node_id"][fid] += 1
            node = {"location": loc, "note": params.get("note", ""), "color": params.get("color", "#888"), "outEdges": [], "inEdges": [parent_id], "name": params.get("name", "")}
            proj["flows"][fid]["nodes"][parent_id]["outEdges"].append(nid)
            proj["flows"][fid]["nodes"][nid] = node
            return {"id": req_id, "method": method, "result": {"flowId": fid, "nodeId": nid}}
        if method == "flow/set/node":
            nid = params.get("nodeId")
            node = params.get("node", {})
            for fid, flow in proj["flows"].items():
                if nid in flow["nodes"]:
                    flow["nodes"][nid] = {**flow["nodes"][nid], **node, "location": node.get("location", flow["nodes"][nid]["location"]), "note": node.get("note", flow["nodes"][nid]["note"]), "color": node.get("color", flow["nodes"][nid]["color"]), "outEdges": node.get("outEdges", flow["nodes"][nid]["outEdges"]), "inEdges": node.get("inEdges", flow["nodes"][nid]["inEdges"])}
                    return {"id": req_id, "method": method, "result": {"flowId": fid, "nodeId": nid}}
            return {"id": req_id, "method": "control/error", "result": {"reason": "node not found"}}
        if method == "flow/remove/node":
            nid = params.get("nodeId")
            for fid, flow in proj["flows"].items():
                if nid in flow["nodes"]:
                    del flow["nodes"][nid]
                    return {"id": req_id, "method": method, "result": {"flowId": fid, "nodeId": nid}}
            return {"id": req_id, "method": "control/error", "result": {"reason": "node not found"}}
        if method == "flow/remove":
            fid = params.get("flowId")
            if fid in proj["flows"]:
                del proj["flows"][fid]
                del proj["flow_infos"][fid]
            return {"id": req_id, "method": method, "result": {"flowId": fid, "linkedFlows": []}}
        if method == "flow/set/info":
            fid = params.get("flowId")
            if fid in proj["flow_infos"]:
                proj["flow_infos"][fid].update({"name": params.get("name", ""), "description": params.get("description", ""), "modifiedDate": params.get("modifiedDate", now), "modifiedBy": self.identity})
            return {"id": req_id, "method": method, "result": {"info": proj["flow_infos"].get(fid, {})}}
        if method == "flow/linked/to":
            return {"id": req_id, "method": method, "result": {"flowIds": []}}
        if method == "flow/unlock":
            return {"id": req_id, "method": method, "result": {"flowId": params.get("flowId")}}
        return {"id": req_id, "method": "control/error", "result": {"reason": f"unknown method: {method}"}}

    def handle_client(self, sock: socket.socket) -> None:
        try:
            req = recv_plaintext(sock)
            if req.get("method") != "control/init":
                sock.close()
                return
            resp = self._handle_init(sock, req)
            sock.sendall(pack_plaintext(resp))
            identity = (req.get("params") or {}).get("identity", "unknown")
            try:
                client_pk = self._get_client_pk(identity)
            except (ValueError, FileNotFoundError):
                sock.close()
                return
            channel = server_key_exchange(sock, identity, client_pk, self.server_sk)
            while True:
                msg = channel.recv()
                resp = self._handle_request(channel, msg)
                channel.send(resp)
                if resp.get("method") == "control/exit":
                    break
        except (EOFError, ConnectionResetError, BrokenPipeError):
            pass
        finally:
            sock.close()

    def run(self, host: str, port: int) -> None:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((host, port))
        server.listen(5)
        while True:
            sock, _ = server.accept()
            t = threading.Thread(target=self.handle_client, args=(sock,))
            t.daemon = True
            t.start()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=5111)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--config-dir", type=Path, required=True)
    args = parser.parse_args()
    args.config_dir.mkdir(parents=True, exist_ok=True)
    (args.config_dir / "users").mkdir(parents=True, exist_ok=True)
    server = MockServer(args.config_dir)
    server.run(args.host, args.port)


if __name__ == "__main__":
    main()
