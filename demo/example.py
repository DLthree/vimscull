"""User authentication module."""

import hashlib
import os


def hash_password(password: str, salt: bytes = None) -> tuple[str, bytes]:
    if salt is None:
        salt = os.urandom(16)
    hashed = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 100_000)
    return hashed.hex(), salt


def verify_password(password: str, stored_hash: str, salt: bytes) -> bool:
    computed, _ = hash_password(password, salt)
    return computed == stored_hash


def authenticate(username: str, password: str, user_db: dict) -> bool:
    if username not in user_db:
        return False
    record = user_db[username]
    return verify_password(password, record["hash"], record["salt"])
