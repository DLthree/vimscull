"""Low-level wire protocol: plaintext framing and socket helpers."""

import json
import socket
import struct
from typing import Any, Dict

from nacl.bindings.crypto_box import crypto_box_MACBYTES, crypto_box_NONCEBYTES

HEADER_SIZE = 10
BLOCK_SIZE = 512
TAG_LEN = crypto_box_MACBYTES  # 16
NONCE_LEN = crypto_box_NONCEBYTES  # 24
KEY_LEN = 32
ENCRYPTED_BLOCK_SIZE = BLOCK_SIZE + TAG_LEN  # 528


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
    """Prefix payload with a 10-byte zero-padded decimal length header."""
    length_str = f"{len(payload):0>{HEADER_SIZE}}"
    return length_str.encode("ascii") + payload


def pack_plaintext(message: Dict[str, Any]) -> bytes:
    return pack_plaintext_bytes(json.dumps(message).encode("utf-8"))


def recv_plaintext(sock: socket.socket) -> Dict[str, Any]:
    header = read_exact(sock, HEADER_SIZE)
    payload_len = int(header.decode("ascii"))
    payload = read_exact(sock, payload_len)
    return json.loads(payload.decode("utf-8"))
