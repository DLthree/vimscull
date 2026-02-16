"""Notes module tests — schema/notes.schema.json

Methods: notes/set, notes/for/file, notes/tag/count, notes/search,
notes/search/tags, notes/search/columns, notes/remove

Server quirks:
- notes/set: verifyFileHash required at params level (use null if not verifying)
- notes/set: Do not send author or modifiedBy; server fills from identity
"""

from tests.conftest import TEST_IDENTITY
from tests.helpers import now, params


def test_notes_set(client_factory):
    """
    notes/set — schema/notes.schema.json
    Params: note, verifyFileHash (required, may be null)
    """
    c = client_factory()
    try:
        c.create_project("proj-ns", "/tmp/pns", TEST_IDENTITY)
        c.change_project("proj-ns")
        r = c.notes_set(
            {
                "location": {"fileId": {"uri": "file:///a.py"}, "line": 1},
                "text": "todo #tag1",
                "createdDate": now(),
                "modifiedDate": now(),
            }
        )
        note = params(r)["note"]
        assert note["text"] == "todo #tag1", f"bad text: {r}"
        assert note["author"] == TEST_IDENTITY, f"author not filled: {r}"
    finally:
        c.close()


def test_notes_set_strips_author_modified_by(client_factory):
    """
    notes/set — server overrides author/modifiedBy from identity.
    Client must not send these; server fills them.
    """
    c = client_factory()
    try:
        c.create_project("proj-ns2", "/tmp/pns2", TEST_IDENTITY)
        c.change_project("proj-ns2")
        r = c.notes_set(
            {
                "location": {"fileId": {"uri": "file:///b.py"}, "line": 1},
                "text": "hi",
                "author": "bogus",
                "modifiedBy": "bogus",
                "createdDate": now(),
                "modifiedDate": now(),
            }
        )
        note = params(r)["note"]
        assert note["author"] == TEST_IDENTITY, f"author not overridden: {note}"
    finally:
        c.close()


def test_notes_for_file(client_factory):
    """
    notes/for/file — schema/notes.schema.json
    Params: fileId (uri)
    """
    c = client_factory()
    try:
        c.create_project("proj-nff", "/tmp/pnff", TEST_IDENTITY)
        c.change_project("proj-nff")
        c.notes_set(
            {
                "location": {"fileId": {"uri": "file:///c.py"}, "line": 1},
                "text": "hello",
                "createdDate": now(),
                "modifiedDate": now(),
            }
        )
        r = c.notes_for_file("file:///c.py")
        notes = params(r)["notes"]
        assert len(notes) == 1, f"expected 1 note: {notes}"
        assert notes[0]["text"] == "hello", f"bad text: {notes}"
    finally:
        c.close()


def test_notes_tag_count(client_factory):
    """
    notes/tag/count — schema/notes.schema.json
    Returns tag counts. #hashtag extraction is server-side.
    """
    c = client_factory()
    try:
        c.create_project("proj-ntc", "/tmp/pntc", TEST_IDENTITY)
        c.change_project("proj-ntc")
        c.notes_set(
            {
                "location": {"fileId": {"uri": "file:///d.py"}, "line": 1},
                "text": "thing #alpha #beta",
                "createdDate": now(),
                "modifiedDate": now(),
            }
        )
        r = c.notes_tag_count()
        tags = {t["tag"]: t["count"] for t in params(r)["tags"]}
        assert "alpha" in tags and "beta" in tags, f"missing tags: {tags}"
    finally:
        c.close()


def test_notes_search(client_factory):
    """
    notes/search — schema/notes.schema.json
    Params: text, optional page
    """
    c = client_factory()
    try:
        c.create_project("proj-ns3", "/tmp/pns3", TEST_IDENTITY)
        c.change_project("proj-ns3")
        c.notes_set(
            {
                "location": {"fileId": {"uri": "file:///e.py"}, "line": 1},
                "text": "unique_needle_xyz",
                "createdDate": now(),
                "modifiedDate": now(),
            }
        )
        r = c.notes_search("unique_needle")
        assert len(params(r)["notes"]) >= 1, f"search miss: {r}"
    finally:
        c.close()


def test_notes_search_tags(client_factory):
    """
    notes/search/tags — schema/notes.schema.json
    Params: text (tag to search)
    """
    c = client_factory()
    try:
        c.create_project("proj-nst", "/tmp/pnst", TEST_IDENTITY)
        c.change_project("proj-nst")
        c.notes_set(
            {
                "location": {"fileId": {"uri": "file:///f.py"}, "line": 1},
                "text": "x #searchtag",
                "createdDate": now(),
                "modifiedDate": now(),
            }
        )
        r = c.notes_search_tags("searchtag")
        assert len(params(r)["notes"]) >= 1, f"tag search miss: {r}"
    finally:
        c.close()


def test_notes_search_columns(client_factory):
    """
    notes/search/columns — schema/notes.schema.json
    Params: filter, optional order, page
    """
    c = client_factory()
    try:
        c.create_project("proj-nsc", "/tmp/pnsc", TEST_IDENTITY)
        c.change_project("proj-nsc")
        c.notes_set(
            {
                "location": {"fileId": {"uri": "file:///g.py"}, "line": 1},
                "text": "col search",
                "createdDate": now(),
                "modifiedDate": now(),
            }
        )
        r = c.notes_search_columns(
            {"author": TEST_IDENTITY},
            order={"by": "createdDate", "ordering": "descending"},
        )
        assert len(params(r)["notes"]) >= 1, f"col search miss: {r}"
    finally:
        c.close()


def test_notes_remove(client_factory):
    """
    notes/remove — schema/notes.schema.json
    Params: location (fileId, line)
    """
    c = client_factory()
    try:
        c.create_project("proj-nr", "/tmp/pnr", TEST_IDENTITY)
        c.change_project("proj-nr")
        c.notes_set(
            {
                "location": {"fileId": {"uri": "file:///h.py"}, "line": 7},
                "text": "doomed",
                "createdDate": now(),
                "modifiedDate": now(),
            }
        )
        r = c.notes_remove("file:///h.py", 7)
        assert r["method"] == "notes/remove", f"bad method: {r}"
        after = c.notes_for_file("file:///h.py")
        assert len(params(after)["notes"]) == 0, f"note not removed: {after}"
    finally:
        c.close()
