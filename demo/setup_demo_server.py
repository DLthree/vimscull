#!/usr/bin/env python3
"""Start a mock Numscull server for demo recordings.

Sets up a temporary config directory with keypairs, starts the mock server,
optionally pre-creates projects, and prints the config directory path.

Usage:
    python3 demo/setup_demo_server.py --port 5222 --project demo-audit
    # Prints config dir path to stdout; server runs until killed.
"""

import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

from nacl.bindings import crypto_box, crypto_box_open, crypto_scalarmult_base

from demo_utils import (
    BLOCK_SIZE,
    DEFAULT_PORT,
    ENCRYPTED_BLOCK_SIZE,
    HEADER_SIZE,
    IDENTITY,
    KEY_LEN,
    MOCK_SERVER,
    NONCE_LEN,
    REPO_ROOT,
    find_python,
)


def generate_keypair(config_dir: Path):
    """Generate a NaCl keypair for the demo identity."""
    sk = os.urandom(32)
    pk = crypto_scalarmult_base(sk)

    identities = config_dir / "identities"
    identities.mkdir(parents=True, exist_ok=True)
    (identities / IDENTITY).write_bytes(pk + sk)

    users = config_dir / "users"
    users.mkdir(parents=True, exist_ok=True)
    (users / f"{IDENTITY}.pub").write_bytes(pk)
    return pk, sk


def wait_for_port(port, timeout=5):
    """Block until a TCP connection to localhost:port succeeds."""
    import time

    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=0.5)
            s.close()
            return True
        except OSError:
            time.sleep(0.2)
    return False


def read_exact(sock, n):
    """Read exactly *n* bytes from *sock*, raising EOFError on disconnect."""
    chunks, received = [], 0
    while received < n:
        chunk = sock.recv(min(n - received, 4096))
        if not chunk:
            raise EOFError
        chunks.append(chunk)
        received += len(chunk)
    return b"".join(chunks)


def counter_nonce(counter):
    return struct.pack("<Q", counter) + b"\x00" * 16


def precreate_projects(host, port, client_pk, client_sk, projects):
    """Connect to the mock server and create projects via the Numscull protocol."""
    import base64

    sock = socket.create_connection((host, port), timeout=5)

    # ── plaintext handshake ──────────────────────────────────────
    init_req = json.dumps({
        "id": 1,
        "method": "control/init",
        "params": {"identity": IDENTITY, "version": "0.2.4"},
    }).encode()
    sock.sendall(f"{len(init_req):0>{HEADER_SIZE}}".encode() + init_req)

    resp_header = read_exact(sock, HEADER_SIZE)
    resp_len = int(resp_header.decode())
    resp_body = json.loads(read_exact(sock, resp_len).decode())
    server_pk_b64 = resp_body.get("params", {}).get("publicKey", {}).get("bytes", "")
    server_pk = base64.b64decode(server_pk_b64)[:32]

    # ── key exchange ─────────────────────────────────────────────
    server_exchange = read_exact(sock, NONCE_LEN + ENCRYPTED_BLOCK_SIZE)
    server_nonce = server_exchange[:NONCE_LEN]
    server_ct = server_exchange[NONCE_LEN:]
    server_block = crypto_box_open(server_ct, server_nonce, server_pk, client_sk)
    server_recv_pk = server_block[:KEY_LEN]
    server_send_pk = server_block[KEY_LEN : KEY_LEN * 2]

    our_recv_sk = os.urandom(32)
    our_recv_pk = crypto_scalarmult_base(our_recv_sk)
    our_send_sk = os.urandom(32)
    our_send_pk = crypto_scalarmult_base(our_send_sk)

    block = bytearray(BLOCK_SIZE)
    block[:KEY_LEN] = our_recv_pk
    block[KEY_LEN : KEY_LEN * 2] = our_send_pk
    block[KEY_LEN * 2 :] = os.urandom(BLOCK_SIZE - KEY_LEN * 2)
    client_nonce = os.urandom(NONCE_LEN)
    client_ct = crypto_box(bytes(block), client_nonce, server_pk, client_sk)
    sock.sendall(client_nonce + client_ct)

    # ── encrypted channel ────────────────────────────────────────
    send_counter = 1
    recv_counter = 1
    msg_id = 2

    def enc_send(message):
        nonlocal send_counter
        json_bytes = json.dumps(message).encode()
        framed = f"{len(json_bytes):0>{HEADER_SIZE}}".encode() + json_bytes
        blk = bytearray(BLOCK_SIZE)
        struct.pack_into("<H", blk, 0, len(framed))
        blk[2 : 2 + len(framed)] = framed
        remaining = BLOCK_SIZE - 2 - len(framed)
        if remaining > 0:
            blk[2 + len(framed) :] = os.urandom(remaining)
        nonce = counter_nonce(send_counter)
        send_counter += 1
        ct = crypto_box(bytes(blk), nonce, server_recv_pk, our_send_sk)
        sock.sendall(ct)

    def enc_recv():
        nonlocal recv_counter
        ct = read_exact(sock, ENCRYPTED_BLOCK_SIZE)
        nonce = counter_nonce(recv_counter)
        recv_counter += 1
        blk = crypto_box_open(ct, nonce, server_send_pk, our_recv_sk)
        msg_len = struct.unpack("<H", blk[:2])[0]
        data = blk[2 : 2 + msg_len]
        header = data[:HEADER_SIZE]
        json_len = int(header.decode())
        return json.loads(data[HEADER_SIZE : HEADER_SIZE + json_len].decode())

    for name in projects:
        msg_id += 1
        enc_send({
            "id": msg_id,
            "method": "control/create/project",
            "params": {"name": name, "repository": "/demo", "ownerIdentity": IDENTITY},
        })
        enc_recv()

    msg_id += 1
    enc_send({"id": msg_id, "method": "control/exit", "params": {}})
    enc_recv()
    sock.close()


def main():
    parser = argparse.ArgumentParser(description="Start a mock Numscull demo server")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument(
        "--project",
        action="append",
        default=[],
        help="Pre-create project(s) on the server",
    )
    args = parser.parse_args()

    config_dir = Path(tempfile.mkdtemp(prefix="numscull-demo-"))
    client_pk, client_sk = generate_keypair(config_dir)

    python = find_python()
    proc = subprocess.Popen(
        [python, str(MOCK_SERVER), "--port", str(args.port), "--config-dir", str(config_dir)],
        cwd=str(REPO_ROOT),
    )

    if not wait_for_port(args.port):
        proc.kill()
        print("ERROR: mock server failed to start", file=sys.stderr)
        sys.exit(1)

    if args.project:
        try:
            precreate_projects("127.0.0.1", args.port, client_pk, client_sk, args.project)
        except Exception as e:
            print(f"WARNING: failed to pre-create projects: {e}", file=sys.stderr)

    # Print config dir for the caller to consume via stdout
    print(str(config_dir), flush=True)

    try:
        proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
        proc.wait(timeout=3)


if __name__ == "__main__":
    main()
