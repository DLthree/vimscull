"""Flow module tests — schema/flow.schema.json

Methods: flow/get/all, flow/create, flow/get, flow/set, flow/set/info,
flow/add/node, flow/fork/node, flow/set/node, flow/remove/node,
flow/linked/to, flow/unlock, flow/remove
"""

from tests.conftest import TEST_IDENTITY
from tests.helpers import make_location, now, params


def test_flow_get_all_empty(client_factory):
    """
    flow/get/all — schema/flow.schema.json
    Returns all FlowInfo summaries. Empty when no flows.
    """
    c = client_factory()
    try:
        c.create_project("proj-fga", "/tmp/pfga", TEST_IDENTITY)
        c.change_project("proj-fga")
        r = c.flow_get_all()
        assert params(r)["flowInfos"] == [], f"expected empty: {r}"
    finally:
        c.close()


def test_flow_create(client_factory):
    """
    flow/create — schema/flow.schema.json
    Params: name, description, createdDate
    """
    c = client_factory()
    try:
        c.create_project("proj-fc", "/tmp/pfc", TEST_IDENTITY)
        c.change_project("proj-fc")
        r = c.flow_create("Test Flow", "desc", now())
        flow = params(r)["flow"]
        assert flow["info"]["name"] == "Test Flow", f"bad name: {r}"
        assert flow["nodes"] == {}, f"expected empty nodes: {r}"
    finally:
        c.close()


def test_flow_get(client_factory):
    """
    flow/get — schema/flow.schema.json
    Params: flowId. Returns full flow with nodes.
    """
    c = client_factory()
    try:
        c.create_project("proj-fg", "/tmp/pfg", TEST_IDENTITY)
        c.change_project("proj-fg")
        cr = c.flow_create("F", "d", now())
        fid = params(cr)["flow"]["info"]["infoId"]
        r = c.flow_get(fid)
        assert params(r)["flow"]["info"]["infoId"] == fid, f"id mismatch: {r}"
    finally:
        c.close()


def test_flow_set(client_factory):
    """
    flow/set — schema/flow.schema.json
    Params: flow. Replace entire flow.
    """
    c = client_factory()
    try:
        c.create_project("proj-fs", "/tmp/pfs", TEST_IDENTITY)
        c.change_project("proj-fs")
        cr = c.flow_create("Original", "desc", now())
        flow = params(cr)["flow"].copy()
        flow["info"] = flow["info"].copy()
        flow["info"]["name"] = "Replaced"
        flow["info"]["description"] = "replaced desc"
        flow["info"]["modifiedDate"] = now()
        r = c.flow_set(flow)
        assert r["method"] == "flow/set", f"bad method: {r}"
    finally:
        c.close()


def test_flow_set_info(client_factory):
    """
    flow/set/info — schema/flow.schema.json
    Params: flowId, name, description, modifiedDate
    """
    c = client_factory()
    try:
        c.create_project("proj-fsi", "/tmp/pfsi", TEST_IDENTITY)
        c.change_project("proj-fsi")
        cr = c.flow_create("Old", "d", now())
        fid = params(cr)["flow"]["info"]["infoId"]
        r = c.flow_set_info(fid, "New", "new desc", now())
        assert params(r)["info"]["name"] == "New", f"name not updated: {r}"
    finally:
        c.close()


def test_flow_add_node(client_factory):
    """
    flow/add/node — schema/flow.schema.json
    Params: location, note, color; optional flowId, parentId, childId, name, link
    """
    c = client_factory()
    try:
        c.create_project("proj-fan", "/tmp/pfan", TEST_IDENTITY)
        c.change_project("proj-fan")
        cr = c.flow_create("F", "d", now())
        fid = params(cr)["flow"]["info"]["infoId"]
        r = c.flow_add_node(make_location(), "note1", "#ff0000", flow_id=fid, name="start")
        assert "nodeId" in params(r), f"no nodeId: {r}"
    finally:
        c.close()


def test_flow_fork_node(client_factory):
    """
    flow/fork/node — schema/flow.schema.json
    Params: location, note, color, parentId; optional name, link
    """
    c = client_factory()
    try:
        c.create_project("proj-ffn", "/tmp/pffn", TEST_IDENTITY)
        c.change_project("proj-ffn")
        cr = c.flow_create("F", "d", now())
        fid = params(cr)["flow"]["info"]["infoId"]
        nid = params(c.flow_add_node(make_location(line=1), "n1", "#ff0000", flow_id=fid))["nodeId"]
        r = c.flow_fork_node(make_location(line=10), "n2", "#00ff00", parent_id=nid)
        assert params(r)["nodeId"] != nid, f"fork same id: {r}"
    finally:
        c.close()


def test_flow_get_with_nodes_and_edges(client_factory):
    """
    flow/get — returns flow with nodes and edges.
    """
    c = client_factory()
    try:
        c.create_project("proj-fgn", "/tmp/pfgn", TEST_IDENTITY)
        c.change_project("proj-fgn")
        cr = c.flow_create("F", "d", now())
        fid = params(cr)["flow"]["info"]["infoId"]
        n1 = params(c.flow_add_node(make_location(line=1), "n1", "#f00", flow_id=fid))["nodeId"]
        n2 = params(c.flow_fork_node(make_location(line=2), "n2", "#0f0", parent_id=n1))["nodeId"]
        flow = params(c.flow_get(fid))["flow"]
        nodes = flow["nodes"]
        assert str(n1) in nodes and str(n2) in nodes, f"missing nodes: {list(nodes.keys())}"
        assert n2 in nodes[str(n1)]["outEdges"], f"missing edge: {nodes[str(n1)]}"
    finally:
        c.close()


def test_flow_set_node(client_factory):
    """
    flow/set/node — schema/flow.schema.json
    Params: nodeId, node
    """
    c = client_factory()
    try:
        c.create_project("proj-fsn", "/tmp/pfsn", TEST_IDENTITY)
        c.change_project("proj-fsn")
        cr = c.flow_create("F", "d", now())
        fid = params(cr)["flow"]["info"]["infoId"]
        nid = params(c.flow_add_node(make_location(), "orig", "#f00", flow_id=fid))["nodeId"]
        node_data = params(c.flow_get(fid))["flow"]["nodes"][str(nid)].copy()
        node_data["note"] = "updated"
        r = c.flow_set_node(nid, node_data)
        assert params(r)["nodeId"] == nid, f"bad set_node: {r}"
        updated = params(c.flow_get(fid))["flow"]["nodes"][str(nid)]
        assert updated["note"] == "updated", f"note not changed: {updated}"
    finally:
        c.close()


def test_flow_remove_node(client_factory):
    """
    flow/remove/node — schema/flow.schema.json
    Params: nodeId
    """
    c = client_factory()
    try:
        c.create_project("proj-frn", "/tmp/pfrn", TEST_IDENTITY)
        c.change_project("proj-frn")
        cr = c.flow_create("F", "d", now())
        fid = params(cr)["flow"]["info"]["infoId"]
        nid = params(c.flow_add_node(make_location(), "n", "#f00", flow_id=fid))["nodeId"]
        r = c.flow_remove_node(nid)
        assert params(r)["nodeId"] == nid, f"bad remove: {r}"
        flow = params(c.flow_get(fid))["flow"]
        assert str(nid) not in flow["nodes"], "node still present"
    finally:
        c.close()


def test_flow_linked_to(client_factory):
    """
    flow/linked/to — schema/flow.schema.json
    Params: flowId
    """
    c = client_factory()
    try:
        c.create_project("proj-flt", "/tmp/pflt", TEST_IDENTITY)
        c.change_project("proj-flt")
        cr = c.flow_create("F", "d", now())
        fid = params(cr)["flow"]["info"]["infoId"]
        r = c.flow_linked_to(fid)
        assert isinstance(params(r)["flowIds"], list), f"bad linked: {r}"
    finally:
        c.close()


def test_flow_unlock(client_factory):
    """
    flow/unlock — schema/flow.schema.json
    Params: flowId
    """
    c = client_factory()
    try:
        c.create_project("proj-ful", "/tmp/pful", TEST_IDENTITY)
        c.change_project("proj-ful")
        cr = c.flow_create("F", "d", now())
        fid = params(cr)["flow"]["info"]["infoId"]
        r = c.flow_unlock(fid)
        assert params(r)["flowId"] == fid, f"bad unlock: {r}"
    finally:
        c.close()


def test_flow_remove(client_factory):
    """
    flow/remove — schema/flow.schema.json
    Params: flowId
    """
    c = client_factory()
    try:
        c.create_project("proj-fr", "/tmp/pfr", TEST_IDENTITY)
        c.change_project("proj-fr")
        cr = c.flow_create("F", "d", now())
        fid = params(cr)["flow"]["info"]["infoId"]
        r = c.flow_remove(fid)
        assert params(r)["flowId"] == fid, f"bad remove: {r}"
        assert params(c.flow_get_all())["flowInfos"] == [], "flow not removed"
    finally:
        c.close()
