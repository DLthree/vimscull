"""Pytest fixtures for Numscull integration tests.

Provides a session-scoped server fixture that provisions a fresh config,
starts numscull_native, and yields config path. Client factory creates
connected, initialized NumscullClient instances.
"""

import subprocess
import time
from pathlib import Path

import pytest

from numscull import NumscullClient, load_keypair

# Known test state
TEST_IDENTITY = "test-client"
TEST_PORT = 5111


def _kill_port(port: int) -> None:
    """Kill any process listening on the given port."""
    try:
        result = subprocess.run(
            ["lsof", "-ti", f"TCP:{port}", "-sTCP:LISTEN"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and result.stdout.strip():
            pid = result.stdout.strip().split()[0]
            subprocess.run(["kill", pid], capture_output=True)
            time.sleep(0.3)
    except (FileNotFoundError, IndexError):
        pass


def _port_listening(port: int) -> bool:
    """Check if something is listening on the port."""
    try:
        result = subprocess.run(
            ["lsof", "-ti", f"TCP:{port}", "-sTCP:LISTEN"],
            capture_output=True,
        )
        return result.returncode == 0 and bool(result.stdout.strip())
    except FileNotFoundError:
        return False


@pytest.fixture(scope="session")
def project_root() -> Path:
    """Project root directory."""
    return Path(__file__).resolve().parent.parent


@pytest.fixture(scope="session")
def binary_path(project_root: Path) -> Path:
    """Path to numscull_native binary."""
    path = project_root / "numscull_native"
    if not path.exists() or not path.is_file():
        pytest.skip("numscull_native binary not found")
    return path


@pytest.fixture(scope="session")
def server_config(project_root: Path, binary_path: Path) -> Path:
    """Provision fresh config, start server, yield config path. Teardown kills server."""
    config_dir = project_root / "tests" / ".test_config"
    server_log = project_root / "tests" / ".test_server.log"

    # Cleanup any existing process on port and remove stale config
    _kill_port(TEST_PORT)
    import shutil

    if config_dir.exists():
        shutil.rmtree(config_dir)

    # Create config (allow multiple users per project for add_user_project test)
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "server.json").write_text(
        f'{{"port": {TEST_PORT}, "max_users_per_project": 10}}'
    )

    # Create keypair
    result = subprocess.run(
        [str(binary_path), "-r", str(config_dir), "--no-pidfile", "create_keypair", TEST_IDENTITY],
        capture_output=True,
        text=True,
        cwd=str(project_root),
    )
    if result.returncode != 0:
        pytest.fail(f"create_keypair failed: {result.stderr}")

    if not (config_dir / "identities" / TEST_IDENTITY).exists():
        pytest.fail("Identity file not created")
    if not (config_dir / "users" / f"{TEST_IDENTITY}.pub").exists():
        pytest.fail("Public key file not created")

    # Start server
    server_log.write_text("")
    proc = subprocess.Popen(
        [str(binary_path), "-r", str(config_dir), "-p", str(TEST_PORT)],
        stdout=server_log.open("a"),
        stderr=subprocess.STDOUT,
        cwd=str(project_root),
    )

    # Wait for server to be ready
    for _ in range(50):
        if _port_listening(TEST_PORT):
            break
        time.sleep(0.1)
    else:
        proc.kill()
        proc.wait()
        pytest.fail(f"Server did not start. Log: {server_log.read_text()}")

    yield config_dir

    # Teardown
    try:
        proc.terminate()
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    _kill_port(TEST_PORT)
    server_log.unlink(missing_ok=True)


@pytest.fixture
def client_factory(server_config: Path):
    """Factory that returns a connected, initialized NumscullClient."""

    def _make_client(identity: str = TEST_IDENTITY, port: int = TEST_PORT) -> NumscullClient:
        _, secret = load_keypair(identity, server_config)
        client = NumscullClient(port=port)
        client.connect()
        client.control_init(identity=identity, secret_key=secret)
        return client

    return _make_client
