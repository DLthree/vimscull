"""Encryption layer: NaCl Box key exchange and encrypted channel."""

import json
import os
import socket
import struct
from pathlib import Path
from typing import Any, Dict

from nacl.bindings import crypto_box, crypto_box_open, crypto_scalarmult_base

from .transport import (
    BLOCK_SIZE,
    ENCRYPTED_BLOCK_SIZE,
    HEADER_SIZE,
    KEY_LEN,
    NONCE_LEN,
    pack_plaintext_bytes,
    read_exact,
)


def counter_nonce(counter: int) -> bytes:
    """Encode counter as 24-byte nonce: LE u64 + 16 zero bytes."""
    return struct.pack("<Q", counter) + b"\x00" * 16


def generate_x25519_keypair() -> tuple[bytes, bytes]:
    """Generate an X25519 keypair. Returns (public_key, secret_key)."""
    sk = os.urandom(32)
    pk = crypto_scalarmult_base(sk)
    return pk, sk


def load_keypair(identity_name: str, config_dir: Path) -> tuple[bytes, bytes]:
    """Returns (public_key, secret_key), each 32 bytes."""
    identity_path = config_dir / "identities" / identity_name
    raw = identity_path.read_bytes()
    if len(raw) != 64:
        raise ValueError(f"Expected 64-byte identity file, got {len(raw)}")
    return raw[:32], raw[32:]


class EncryptedChannel:
    """Encrypted communication using ephemeral X25519 + NaCl Box."""

    def __init__(
        self,
        sock: socket.socket,
        ours_recv_sk: bytes,
        ours_send_sk: bytes,
        theirs_recv_pk: bytes,
        theirs_send_pk: bytes,
    ):
        self.sock = sock
        self.ours_recv_sk = ours_recv_sk
        self.ours_send_sk = ours_send_sk
        self.theirs_recv_pk = theirs_recv_pk
        self.theirs_send_pk = theirs_send_pk
        self.send_nonce: int = 1
        self.recv_nonce: int = 1

    def send(self, message: Dict[str, Any]) -> None:
        json_bytes = json.dumps(message).encode("utf-8")
        framed = pack_plaintext_bytes(json_bytes)
        if len(framed) > BLOCK_SIZE - 2:
            raise ValueError(f"Message too large: {len(framed)} > {BLOCK_SIZE - 2}")

        block = bytearray(BLOCK_SIZE)
        struct.pack_into("<H", block, 0, len(framed))
        block[2 : 2 + len(framed)] = framed
        padding_start = 2 + len(framed)
        block[padding_start:] = os.urandom(BLOCK_SIZE - padding_start)

        nonce = counter_nonce(self.send_nonce)
        self.send_nonce += 1

        ct = crypto_box(bytes(block), nonce, self.theirs_send_pk, self.ours_send_sk)
        self.sock.sendall(ct)

    def recv_raw(self) -> bytes:
        """Receive and decrypt one block, returning raw payload bytes."""
        ct = read_exact(self.sock, ENCRYPTED_BLOCK_SIZE)
        nonce = counter_nonce(self.recv_nonce)
        self.recv_nonce += 1

        block = crypto_box_open(ct, nonce, self.theirs_recv_pk, self.ours_recv_sk)
        msg_len = struct.unpack("<H", block[:2])[0]
        return block[2 : 2 + msg_len]

    def recv(self) -> Dict[str, Any]:
        """Receive, decrypt, and parse a JSON response."""
        data = self.recv_raw()
        header = data[:HEADER_SIZE]
        json_len = int(header.decode("ascii"))
        json_bytes = data[HEADER_SIZE : HEADER_SIZE + json_len]

        while len(json_bytes) < json_len:
            more = self.recv_raw()
            json_bytes += more

        return json.loads(json_bytes[:json_len].decode("utf-8"))


def do_key_exchange(
    sock: socket.socket,
    our_static_sk: bytes,
    their_static_pk: bytes,
) -> EncryptedChannel:
    """Perform the ephemeral key exchange after init."""
    server_exchange = read_exact(sock, NONCE_LEN + ENCRYPTED_BLOCK_SIZE)
    server_nonce = server_exchange[:NONCE_LEN]
    server_ct = server_exchange[NONCE_LEN:]

    server_block = crypto_box_open(server_ct, server_nonce, their_static_pk, our_static_sk)

    server_recv_pk = server_block[:KEY_LEN]
    server_send_pk = server_block[KEY_LEN : KEY_LEN * 2]

    our_recv_pk, our_recv_sk = generate_x25519_keypair()
    our_send_pk, our_send_sk = generate_x25519_keypair()

    block = bytearray(BLOCK_SIZE)
    block[:KEY_LEN] = our_recv_pk
    block[KEY_LEN : KEY_LEN * 2] = our_send_pk
    block[KEY_LEN * 2 :] = os.urandom(BLOCK_SIZE - KEY_LEN * 2)

    client_nonce = os.urandom(NONCE_LEN)
    client_ct = crypto_box(bytes(block), client_nonce, their_static_pk, our_static_sk)

    sock.sendall(client_nonce + client_ct)

    return EncryptedChannel(
        sock=sock,
        ours_recv_sk=our_recv_sk,
        ours_send_sk=our_send_sk,
        theirs_recv_pk=server_send_pk,
        theirs_send_pk=server_recv_pk,
    )
