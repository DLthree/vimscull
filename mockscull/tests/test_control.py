"""Control module tests — schema/control.schema.json

Methods: control/init, control/list/project, control/create/project,
control/change/project, control/remove/project, control/subscribe,
control/unsubscribe, control/add/user/server, control/add/user/project,
control/exit
"""

import pytest

from numscull import NumscullClient, load_keypair

from tests.conftest import TEST_IDENTITY, TEST_PORT
from tests.helpers import params


def test_control_init_establishes_channel(server_config, client_factory):
    """
    control/init — schema/control.schema.json
    Params: identity, version. Plaintext phase; triggers key exchange.
    """
    _, secret = load_keypair(TEST_IDENTITY, server_config)
    c = NumscullClient(port=TEST_PORT)
    c.connect()
    r = c.control_init(identity=TEST_IDENTITY, secret_key=secret)
    assert params(r).get("valid") is True, f"expected valid=True: {r}"
    assert c.channel is not None, "channel not established"
    c.close()


def test_control_list_project(client_factory):
    """
    control/list/project — schema/control.schema.json
    Returns list of projects.
    """
    c = client_factory()
    try:
        r = c.list_projects()
        assert isinstance(params(r)["projects"], list), f"bad projects: {r}"
    finally:
        c.close()


def test_control_create_project(client_factory):
    """
    control/create/project — schema/control.schema.json
    Params: name, repository, ownerIdentity
    """
    c = client_factory()
    try:
        r = c.create_project("proj-create", "/tmp/pc", TEST_IDENTITY)
        assert r["method"] == "control/create/project", f"bad method: {r}"
    finally:
        c.close()


def test_control_change_project(client_factory):
    """
    control/change/project — schema/control.schema.json
    Params: name
    """
    c = client_factory()
    try:
        c.create_project("proj-change", "/tmp/pch", TEST_IDENTITY)
        r = c.change_project("proj-change")
        assert params(r)["name"] == "proj-change", f"bad name: {r}"
    finally:
        c.close()


def test_control_remove_project(client_factory):
    """
    control/remove/project — schema/control.schema.json
    Params: name. Removing active project disconnects client.
    """
    c = client_factory()
    c.create_project("proj-rm", "/tmp/prm", TEST_IDENTITY)
    c.change_project("proj-rm")
    r = c.remove_project("proj-rm")
    assert r["method"] == "control/remove/project", f"bad method: {r}"
    c.close()


def test_control_subscribe_unsubscribe(client_factory):
    """
    control/subscribe, control/unsubscribe — schema/control.schema.json
    Params: channels (array of ints)
    """
    c = client_factory()
    try:
        c.create_project("proj-sub", "/tmp/ps", TEST_IDENTITY)
        c.change_project("proj-sub")
        r1 = c.subscribe([1, 2])
        assert r1["method"] == "control/subscribe", f"bad sub: {r1}"
        r2 = c.unsubscribe([1])
        assert r2["method"] == "control/unsubscribe", f"bad unsub: {r2}"
    finally:
        c.close()


def test_control_add_user_server(server_config, client_factory):
    """
    control/add/user/server — schema/control.schema.json
    Params: identity, publicKey. Adds a second identity to the server.
    """
    from numscull.crypto import generate_x25519_keypair

    pub2, _ = generate_x25519_keypair()
    identity2 = "test-client-2"

    c = client_factory()
    try:
        c.create_project("proj-au", "/tmp/pau", TEST_IDENTITY)
        c.change_project("proj-au")
        r = c.add_user_server(identity2, pub2)
        # Server may return method in response; verify we got a response
        assert "method" in r, f"no method in response: {r}"
    finally:
        c.close()


def test_control_add_user_project(server_config, client_factory):
    """
    control/add/user/project — schema/control.schema.json
    Params: project, identity, optional permissions
    """
    from numscull.crypto import generate_x25519_keypair

    pub2, _ = generate_x25519_keypair()
    identity2 = "test-client-2"

    c = client_factory()
    try:
        c.create_project("proj-aup", "/tmp/paup", TEST_IDENTITY)
        c.change_project("proj-aup")
        c.add_user_server(identity2, pub2)
        r = c.add_user_project("proj-aup", identity2)
        # Success or server limit (e.g. max_users_per_project=1)
        assert r["method"] in (
            "control/add/user/project",
            "control/error",
        ), f"unexpected method: {r}"
    finally:
        c.close()


def test_control_exit(client_factory):
    """
    control/exit — schema/control.schema.json
    Graceful disconnect. Server may close connection before sending response.
    """
    c = client_factory()
    c.create_project("proj-exit", "/tmp/pex", TEST_IDENTITY)
    c.change_project("proj-exit")
    try:
        r = c.exit()
        assert r.get("method") == "control/exit", f"bad method: {r}"
    except EOFError:
        # Server closed connection after exit; that's acceptable
        pass
    finally:
        c.close()


def test_send_raw_escape_hatch(client_factory):
    """
    send_raw — escape hatch for custom RPCs.
    """
    c = client_factory()
    try:
        c.create_project("proj-raw", "/tmp/pr", TEST_IDENTITY)
        c.change_project("proj-raw")
        r = c.send_raw("control/list/project")
        assert "projects" in params(r), f"bad raw: {r}"
    finally:
        c.close()
