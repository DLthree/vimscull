-- tests/run_tests.lua — automated test suite for vimscull (numscull protocol)
-- Run: nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/run_tests.lua
-- Requires: libsodium, python3, pynacl

local api = vim.api
local fn = vim.fn
local uv = vim.uv or vim.loop

local passed, failed, skipped, errors = 0, 0, 0, {}
local TEST_PORT = 5111
local TEST_IDENTITY = "test-client"
local server_job = nil
local config_dir = nil

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function report(name, ok, msg)
  if ok then
    passed = passed + 1
    print("  PASS: " .. name)
  else
    failed = failed + 1
    table.insert(errors, { name = name, msg = msg })
    print("  FAIL: " .. name .. " — " .. (msg or ""))
  end
end

local function report_skip(name, reason)
  skipped = skipped + 1
  print("  SKIP: " .. name .. " — " .. (reason or ""))
end

local function assert_eq(name, got, expected)
  if got == expected then
    report(name, true)
  else
    report(name, false, string.format("expected %s, got %s", vim.inspect(expected), vim.inspect(got)))
  end
end

local function assert_neq(name, got, unexpected)
  if got ~= unexpected then
    report(name, true)
  else
    report(name, false, string.format("did not expect %s", vim.inspect(unexpected)))
  end
end

local function assert_true(name, val, msg)
  if val then
    report(name, true)
  else
    report(name, false, msg or "expected truthy value")
  end
end

local function assert_nil(name, val, msg)
  if val == nil then
    report(name, true)
  else
    report(name, false, (msg or "expected nil") .. ", got " .. vim.inspect(val))
  end
end

local function assert_match(name, str, pattern)
  if type(str) == "string" and str:find(pattern) then
    report(name, true)
  else
    report(name, false, string.format("expected match for %q in %q", pattern, tostring(str)))
  end
end

local function assert_gte(name, got, min_val)
  if type(got) == "number" and got >= min_val then
    report(name, true)
  else
    report(name, false, string.format("expected >= %s, got %s", tostring(min_val), tostring(got)))
  end
end

local function port_open(port)
  local result = fn.systemlist("nc -z 127.0.0.1 " .. port .. " 2>/dev/null && echo ok || true")
  return result and result[1] == "ok"
end

local function wait_for_port(port, max_wait_sec)
  max_wait_sec = max_wait_sec or 5
  local start = os.time()
  while (os.time() - start) < max_wait_sec do
    if port_open(port) then return true end
    os.execute("sleep 0.2 2>/dev/null || ping -c 1 127.0.0.1 >/dev/null 2>&1")
  end
  return false
end

local function start_mock_server()
  local root = fn.getcwd()
  local script = root .. "/tests/mock_server.py"
  local python = root .. "/.venv/bin/python3"
  if vim.fn.filereadable(python) == 0 then
    python = "python3"
  end
  local cmd = string.format("%s %s --port %d --config-dir %s", python, script, TEST_PORT, config_dir)
  server_job = fn.jobstart(cmd, { cwd = root })
  if server_job <= 0 then
    return false, "failed to start mock server"
  end
  if not wait_for_port(TEST_PORT) then
    fn.jobstop(server_job)
    return false, "mock server did not start"
  end
  return true
end

local function stop_mock_server()
  if server_job and server_job > 0 then
    fn.jobstop(server_job)
    server_job = nil
  end
end

--- Write a temp file with content and open it in a buffer.
--- Returns bufnr, file_path, uri.
local function open_test_file(name, content)
  local path = config_dir .. "/" .. name
  local f = io.open(path, "w")
  f:write(content)
  f:close()
  vim.cmd("edit " .. path)
  local bufnr = api.nvim_get_current_buf()
  local uri = "file://" .. path
  return bufnr, path, uri
end

--- Close current buffer.
local function close_buf()
  pcall(vim.cmd, "bwipeout!")
end

--- Reload all numscull modules to get a fresh state.
local function reload_numscull()
  for mod, _ in pairs(package.loaded) do
    if mod:match("^numscull") then
      package.loaded[mod] = nil
    end
  end
end

--- Make a note_input table.
local function make_note_input(uri, line, text)
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  return {
    location = { fileId = { uri = uri }, line = line },
    text = text,
    createdDate = now,
    modifiedDate = now,
  }
end

-----------------------------------------------------------------------
print("=== vimscull (numscull) test suite ===\n")

-----------------------------------------------------------------------
-- [Crypto]
-----------------------------------------------------------------------
print("[Crypto]")
do
  package.loaded["numscull.crypto"] = nil
  local crypto = require("numscull.crypto")
  if crypto._load_error then
    report("libsodium available", false, crypto._load_error)
  else
    report("libsodium available", true)

    local pk, sk = crypto.generate_x25519_keypair()
    assert_true("keypair generated", pk and sk and #pk == 32 and #sk == 32)

    -- Two keypairs should be different
    local pk2, sk2 = crypto.generate_x25519_keypair()
    assert_true("keypairs are unique", pk ~= pk2 and sk ~= sk2)
  end
end

-- Setup config dir and keypair
config_dir = fn.tempname()
fn.mkdir(config_dir, "p")
fn.mkdir(config_dir .. "/identities", "p")
fn.mkdir(config_dir .. "/users", "p")

print("\n[Crypto — Keypair I/O]")
do
  local crypto = require("numscull.crypto")
  if not crypto._load_error then
    local pk, sk = crypto.generate_x25519_keypair()
    crypto.write_keypair(config_dir, TEST_IDENTITY, pk, sk)
    report("test keypair written", true)

    -- Load it back and verify
    local loaded_pk, loaded_sk = crypto.load_keypair(TEST_IDENTITY, config_dir)
    assert_eq("loaded pk matches written pk", loaded_pk, pk)
    assert_eq("loaded sk matches written sk", loaded_sk, sk)

    -- Counter nonce: first few should be different
    local n1 = crypto.counter_nonce(1)
    local n2 = crypto.counter_nonce(2)
    assert_eq("counter_nonce length", #n1, 24)
    assert_true("counter_nonce values differ", n1 ~= n2)

    -- Pack plaintext bytes
    local packed = crypto.pack_plaintext_bytes("hello")
    assert_eq("pack_plaintext_bytes header", packed:sub(1, 10), "0000000005")
    assert_eq("pack_plaintext_bytes payload", packed:sub(11), "hello")
  else
    report("test keypair written", false, "crypto not available")
  end
end

-----------------------------------------------------------------------
-- [Mock Server]
-----------------------------------------------------------------------
print("\n[Mock Server]")
do
  local ok, err = start_mock_server()
  if not ok then
    report("mock server started", false, err)
    print("\nSkipping integration tests (mock server failed).")
    print("Ensure: python3, pip install pynacl, libsodium installed")
  else
    report("mock server started", true)
  end
end

local integration_ok = false
if server_job and server_job > 0 then

-----------------------------------------------------------------------
-- [Connect & Init]
-----------------------------------------------------------------------
print("\n[Connect & Init]")
do
  reload_numscull()
  local numscull = require("numscull")
  numscull.setup({ config_dir = config_dir, identity = TEST_IDENTITY, auto_fetch = false })
  local ok, err = numscull.connect("127.0.0.1", TEST_PORT)
  assert_true("connect + init", ok, err)
  integration_ok = true
end

if integration_ok then

-----------------------------------------------------------------------
-- [Control — Projects]
-----------------------------------------------------------------------
print("\n[Control — Projects]")
do
  local numscull = require("numscull")

  -- Create project
  local proj_result, proj_err = numscull.create_project("test-proj", "/tmp/test", TEST_IDENTITY)
  assert_true("create project", proj_err == nil, proj_err)

  -- Create a second project
  local proj2_result, proj2_err = numscull.create_project("test-proj-2", "/tmp/test2", TEST_IDENTITY)
  assert_true("create second project", proj2_err == nil, proj2_err)

  -- List projects — should show both
  local list_result, list_err = numscull.list_projects()
  assert_true("list projects succeeds", list_err == nil, list_err)
  if list_result then
    local projects = list_result.projects or {}
    assert_gte("list projects count >= 2", #projects, 2)
    -- Verify project names are present
    local found = {}
    for _, p in ipairs(projects) do found[p.name] = true end
    assert_true("test-proj in list", found["test-proj"])
    assert_true("test-proj-2 in list", found["test-proj-2"])
  end

  -- Change project
  local chg_ok, chg_err = numscull.change_project("test-proj")
  assert_true("change project", chg_err == nil, chg_err)
end

-----------------------------------------------------------------------
-- [Control — Subscribe/Unsubscribe]
-----------------------------------------------------------------------
print("\n[Control — Subscribe/Unsubscribe]")
do
  local control = require("numscull.control")

  local sub_result, sub_err = control.subscribe({ "notes", "flows" })
  assert_true("subscribe succeeds", sub_err == nil, sub_err)
  if sub_result then
    local channels = sub_result.channels or {}
    assert_eq("subscribe channels count", #channels, 2)
  end

  local unsub_result, unsub_err = control.unsubscribe({ "flows" })
  assert_true("unsubscribe succeeds", unsub_err == nil, unsub_err)
  if unsub_result then
    local channels = unsub_result.channels or {}
    assert_eq("unsubscribe channels count", #channels, 1)
  end
end

-----------------------------------------------------------------------
-- [Notes — Basic CRUD]
-----------------------------------------------------------------------
print("\n[Notes — Basic CRUD]")
do
  local numscull = require("numscull")
  local bufnr, path, uri = open_test_file("sample.lua", "local x = 1\nlocal y = 2\nlocal z = 3\nreturn x + y + z\n")
  api.nvim_win_set_cursor(0, { 2, 0 })

  -- Set a note
  local note, err = numscull.set(make_note_input(uri, 2, "test note #tag1"))
  assert_true("notes/set", note ~= nil, err)
  if note then
    assert_eq("note text", note.text, "test note #tag1")
    assert_eq("note author", note.author, TEST_IDENTITY)
    assert_eq("note line", note.line, 2)
  end

  -- Fetch notes for file
  local notes, err2 = numscull.for_file(uri)
  assert_true("notes/for/file", notes ~= nil, err2)
  if notes then
    assert_eq("notes returned count", #notes, 1)
    assert_eq("fetched note text", notes[1].text, "test note #tag1")
    assert_eq("fetched note line", notes[1].line, 2)
  end

  -- Tag count
  local tag_result, err3 = numscull.tag_count()
  assert_true("notes/tag/count", tag_result ~= nil, err3)
  if tag_result then
    local tags = tag_result.tags or {}
    assert_gte("tags count >= 1", #tags, 1)
    -- Find tag1
    local found_tag1 = false
    for _, t in ipairs(tags) do
      if t.tag == "tag1" then found_tag1 = true end
    end
    assert_true("tag1 in tag_count", found_tag1)
  end

  -- Remove note
  local ok_remove, err4 = numscull.remove(uri, 2)
  assert_true("notes/remove", ok_remove ~= nil, err4)

  local notes_after = numscull.for_file(uri)
  assert_true("notes empty after remove", notes_after and #notes_after == 0)

  close_buf()
end

-----------------------------------------------------------------------
-- [Notes — Multiple Notes on Same File]
-----------------------------------------------------------------------
print("\n[Notes — Multiple Notes on Same File]")
do
  local numscull = require("numscull")
  local notes_mod = require("numscull.notes")
  local bufnr, path, uri = open_test_file("multi.lua",
    "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n")

  -- Add notes on lines 2, 5, and 8
  local n1, e1 = numscull.set(make_note_input(uri, 2, "note on line 2"))
  local n2, e2 = numscull.set(make_note_input(uri, 5, "note on line 5 #multi"))
  local n3, e3 = numscull.set(make_note_input(uri, 8, "note on line 8 #multi #extra"))
  assert_true("set note line 2", n1 ~= nil, e1)
  assert_true("set note line 5", n2 ~= nil, e2)
  assert_true("set note line 8", n3 ~= nil, e3)

  -- Fetch and verify count
  local notes = numscull.for_file(uri)
  assert_true("multi: fetched notes", notes ~= nil)
  if notes then
    assert_eq("multi: 3 notes returned", #notes, 3)
    -- Notes should be sorted by line
    assert_eq("multi: first note line", notes[1].line, 2)
    assert_eq("multi: second note line", notes[2].line, 5)
    assert_eq("multi: third note line", notes[3].line, 8)
  end

  -- Cache should reflect the same
  local cached = notes_mod.get_cached(uri)
  assert_true("multi: cache populated", cached ~= nil and #cached == 3)

  -- Remove middle note, verify
  numscull.remove(uri, 5)
  local after = numscull.for_file(uri)
  if after then
    assert_eq("multi: 2 notes after remove", #after, 2)
    assert_eq("multi: remaining line 2", after[1].line, 2)
    assert_eq("multi: remaining line 8", after[2].line, 8)
  end

  -- Clean up all notes
  numscull.remove(uri, 2)
  numscull.remove(uri, 8)
  close_buf()
end

-----------------------------------------------------------------------
-- [Notes — Update / Overwrite]
-----------------------------------------------------------------------
print("\n[Notes — Update / Overwrite]")
do
  local numscull = require("numscull")
  local bufnr, path, uri = open_test_file("update.lua", "line1\nline2\nline3\n")

  -- Add a note, then overwrite it on the same line
  numscull.set(make_note_input(uri, 1, "original note"))
  local updated, err = numscull.set(make_note_input(uri, 1, "updated note"))
  assert_true("update note succeeds", updated ~= nil, err)
  if updated then
    assert_eq("updated note text", updated.text, "updated note")
  end

  -- Fetch — should still be only 1 note
  local notes = numscull.for_file(uri)
  if notes then
    assert_eq("overwrite: still 1 note", #notes, 1)
    assert_eq("overwrite: text is updated", notes[1].text, "updated note")
  end

  numscull.remove(uri, 1)
  close_buf()
end

-----------------------------------------------------------------------
-- [Notes — Search]
-----------------------------------------------------------------------
print("\n[Notes — Search]")
do
  local numscull = require("numscull")
  local _, _, uri = open_test_file("search.lua", "a\nb\nc\nd\ne\n")

  -- Seed a few notes with different text and tags
  numscull.set(make_note_input(uri, 1, "alpha #bug"))
  numscull.set(make_note_input(uri, 2, "beta #feature"))
  numscull.set(make_note_input(uri, 3, "gamma #bug #critical"))
  numscull.set(make_note_input(uri, 4, "delta something"))

  -- Text search: "alpha"
  local r1, e1 = numscull.search("alpha")
  assert_true("search succeeds", r1 ~= nil, e1)
  if r1 then
    assert_eq("search 'alpha' count", #(r1.notes or {}), 1)
  end

  -- Text search: "a" should match alpha, gamma, delta (all contain 'a')
  local r2, e2 = numscull.search("a")
  assert_true("search 'a' succeeds", r2 ~= nil, e2)
  if r2 then
    assert_gte("search 'a' count >= 3", #(r2.notes or {}), 3)
  end

  -- Text search: case-insensitive ("ALPHA" should find "alpha")
  local r3, e3 = numscull.search("ALPHA")
  assert_true("search case-insensitive", r3 ~= nil, e3)
  if r3 then
    assert_eq("search 'ALPHA' finds alpha", #(r3.notes or {}), 1)
  end

  -- Text search: no match
  local r4, e4 = numscull.search("nonexistent_xyz")
  assert_true("search no match succeeds", r4 ~= nil, e4)
  if r4 then
    assert_eq("search no match count", #(r4.notes or {}), 0)
  end

  -- Search by tags: "bug"
  local t1, te1 = numscull.search_tags("bug")
  assert_true("search_tags succeeds", t1 ~= nil, te1)
  if t1 then
    assert_eq("search_tags 'bug' count", #(t1.notes or {}), 2)
  end

  -- Search by tags: "feature"
  local t2, te2 = numscull.search_tags("feature")
  assert_true("search_tags 'feature' succeeds", t2 ~= nil, te2)
  if t2 then
    assert_eq("search_tags 'feature' count", #(t2.notes or {}), 1)
  end

  -- Search by tags: "critical"
  local t3, te3 = numscull.search_tags("critical")
  assert_true("search_tags 'critical' succeeds", t3 ~= nil, te3)
  if t3 then
    assert_eq("search_tags 'critical' count", #(t3.notes or {}), 1)
  end

  -- Search columns: filter by author
  local c1, ce1 = numscull.search_columns({ author = TEST_IDENTITY })
  assert_true("search_columns by author succeeds", c1 ~= nil, ce1)
  if c1 then
    assert_gte("search_columns by author count >= 4", #(c1.notes or {}), 4)
  end

  -- Search columns: filter by nonexistent author
  local c2, ce2 = numscull.search_columns({ author = "nobody" })
  assert_true("search_columns no match succeeds", c2 ~= nil, ce2)
  if c2 then
    assert_eq("search_columns no match count", #(c2.notes or {}), 0)
  end

  -- Tag count after seeding
  local tc, tce = numscull.tag_count()
  assert_true("tag_count after seeding", tc ~= nil, tce)
  if tc then
    local tag_map = {}
    for _, t in ipairs(tc.tags or {}) do tag_map[t.tag] = t.count end
    assert_eq("tag_count bug=2", tag_map["bug"], 2)
    assert_eq("tag_count feature=1", tag_map["feature"], 1)
    assert_eq("tag_count critical=1", tag_map["critical"], 1)
  end

  -- Cleanup
  numscull.remove(uri, 1)
  numscull.remove(uri, 2)
  numscull.remove(uri, 3)
  numscull.remove(uri, 4)
  close_buf()
end

-----------------------------------------------------------------------
-- [Notes — Extmark Decoration]
-----------------------------------------------------------------------
print("\n[Notes — Extmark Decoration]")
do
  local numscull = require("numscull")
  local notes_mod = require("numscull.notes")
  local bufnr, path, uri = open_test_file("extmarks.lua",
    "local a = 1\nlocal b = 2\nlocal c = 3\nreturn a + b + c\n")
  api.nvim_win_set_cursor(0, { 1, 0 })

  -- Add a note and decorate
  numscull.set(make_note_input(uri, 1, "extmark note line 1"))
  numscull.set(make_note_input(uri, 3, "extmark note line 3"))
  numscull.for_file(uri)
  notes_mod.decorate(bufnr)

  local ns_id = api.nvim_create_namespace("numscull_notes")
  local marks = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
  assert_gte("extmark count >= 2", #marks, 2)

  -- Verify extmark rows (0-indexed)
  if #marks >= 2 then
    -- marks are sorted by position
    assert_eq("extmark 1 row", marks[1][2], 0)  -- line 1 = row 0
    assert_eq("extmark 2 row", marks[2][2], 2)  -- line 3 = row 2
  end

  -- Check virt_lines detail on first extmark
  local detail = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
  if #detail >= 1 then
    local ext_details = detail[1][4]
    assert_true("extmark has virt_lines", ext_details and ext_details.virt_lines ~= nil)
    if ext_details and ext_details.virt_lines then
      local vl = ext_details.virt_lines
      assert_gte("virt_lines count >= 1", #vl, 1)
      -- First virt_line should contain header with author and text
      local header_text = vl[1][1][1] or ""
      assert_match("virt_line contains author", header_text, TEST_IDENTITY:gsub("%-", "%%-"))
      assert_match("virt_line contains note text", header_text, "extmark note line 1")
    end
  end

  -- Clean up
  numscull.remove(uri, 1)
  numscull.remove(uri, 3)
  close_buf()
end

-----------------------------------------------------------------------
-- [Notes — Toggle Visibility]
-----------------------------------------------------------------------
print("\n[Notes — Toggle Visibility]")
do
  local numscull = require("numscull")
  local notes_mod = require("numscull.notes")
  local bufnr, path, uri = open_test_file("toggle.lua", "line1\nline2\nline3\n")

  numscull.set(make_note_input(uri, 1, "toggle note"))
  numscull.for_file(uri)
  notes_mod.decorate(bufnr)

  local ns_id = api.nvim_create_namespace("numscull_notes")

  -- Verify extmarks present initially
  local marks_before = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
  assert_gte("toggle: marks before toggle", #marks_before, 1)

  -- Toggle off (notes start visible)
  notes_mod.toggle()
  local marks_hidden = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
  assert_eq("toggle: marks after hide", #marks_hidden, 0)

  -- Toggle back on
  notes_mod.toggle()
  local marks_shown = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
  assert_gte("toggle: marks after show", #marks_shown, 1)

  numscull.remove(uri, 1)
  close_buf()
end

-----------------------------------------------------------------------
-- [Notes — List Scratch Buffer]
-----------------------------------------------------------------------
print("\n[Notes — List Scratch Buffer]")
do
  local numscull = require("numscull")
  local notes_mod = require("numscull.notes")
  local bufnr, path, uri = open_test_file("list.lua", "aaa\nbbb\nccc\n")
  local orig_buf = bufnr

  numscull.set(make_note_input(uri, 1, "first note"))
  numscull.set(make_note_input(uri, 3, "third note"))

  -- Call list() — should open a new scratch buffer
  notes_mod.list()

  local list_buf = api.nvim_get_current_buf()
  assert_true("list: opened new buffer", list_buf ~= orig_buf)
  assert_eq("list: buftype is nofile", vim.bo[list_buf].buftype, "nofile")
  assert_eq("list: filetype is numscull_list", vim.bo[list_buf].filetype, "numscull_list")

  local lines = api.nvim_buf_get_lines(list_buf, 0, -1, false)
  assert_gte("list: has content lines", #lines, 3) -- header + blank + at least 1 note
  assert_match("list: header present", lines[1], "Notes for")

  -- Find note entries
  local found_first, found_third = false, false
  for _, l in ipairs(lines) do
    if l:find("first note") then found_first = true end
    if l:find("third note") then found_third = true end
  end
  assert_true("list: shows first note", found_first)
  assert_true("list: shows third note", found_third)

  -- Close scratch buffer, go back
  close_buf()
  -- Now clean up notes
  numscull.remove(uri, 1)
  numscull.remove(uri, 3)
  close_buf()
end

-----------------------------------------------------------------------
-- [Notes — add() with Cursor]
-----------------------------------------------------------------------
print("\n[Notes — add() with Cursor]")
do
  local numscull = require("numscull")
  local bufnr, path, uri = open_test_file("add_cursor.lua", "one\ntwo\nthree\nfour\n")

  -- Position cursor on line 3 and add a note via add()
  api.nvim_win_set_cursor(0, { 3, 0 })
  numscull.add("cursor note at line 3")

  local notes = numscull.for_file(uri)
  assert_true("add: notes fetched", notes ~= nil)
  if notes then
    assert_eq("add: 1 note", #notes, 1)
    assert_eq("add: line is 3", notes[1].line, 3)
    assert_eq("add: text matches", notes[1].text, "cursor note at line 3")
  end

  numscull.remove(uri, 3)
  close_buf()
end

-----------------------------------------------------------------------
-- [Notes — Notes on Multiple Files]
-----------------------------------------------------------------------
print("\n[Notes — Notes on Multiple Files]")
do
  local numscull = require("numscull")

  local buf1, path1, uri1 = open_test_file("file_a.lua", "a1\na2\na3\n")
  numscull.set(make_note_input(uri1, 1, "note in file A"))
  close_buf()

  local buf2, path2, uri2 = open_test_file("file_b.lua", "b1\nb2\nb3\n")
  numscull.set(make_note_input(uri2, 2, "note in file B"))
  close_buf()

  -- Fetch notes for file A — should only have file A's note
  local notesA = numscull.for_file(uri1)
  assert_true("multi-file: file A notes", notesA ~= nil and #notesA == 1)
  if notesA and #notesA >= 1 then
    assert_eq("multi-file: file A text", notesA[1].text, "note in file A")
  end

  -- Fetch notes for file B — should only have file B's note
  local notesB = numscull.for_file(uri2)
  assert_true("multi-file: file B notes", notesB ~= nil and #notesB == 1)
  if notesB and #notesB >= 1 then
    assert_eq("multi-file: file B text", notesB[1].text, "note in file B")
  end

  numscull.remove(uri1, 1)
  numscull.remove(uri2, 2)
end

-----------------------------------------------------------------------
-- [Flows — Full CRUD]
-----------------------------------------------------------------------
print("\n[Flows — Full CRUD]")
do
  local numscull = require("numscull")

  -- Create a flow
  local result, err = numscull.flow_create("Test Flow", "a test flow")
  assert_true("flow/create", result ~= nil, err)
  local flow_id = nil
  if result and result.flow then
    flow_id = result.flow.info and result.flow.info.infoId
    assert_true("flow has infoId", flow_id ~= nil)
    assert_eq("flow name", result.flow.info.name, "Test Flow")
    assert_eq("flow description", result.flow.info.description, "a test flow")
    assert_eq("flow author", result.flow.info.author, TEST_IDENTITY)
  end

  -- Get all flows
  local get_all, err2 = numscull.flow_get_all()
  assert_true("flow/get/all", get_all ~= nil, err2)
  if get_all and get_all.flowInfos then
    assert_gte("flowInfos count >= 1", #get_all.flowInfos, 1)
  end

  -- Get single flow by ID
  if flow_id then
    local get_one, err3 = numscull.flow_get(flow_id)
    assert_true("flow/get by id", get_one ~= nil, err3)
    if get_one and get_one.flow then
      assert_eq("flow/get name", get_one.flow.info.name, "Test Flow")
    end
  end

  -- Set flow info (update metadata)
  if flow_id then
    local info_result, ie = numscull.flow_set_info(flow_id, "Renamed Flow", "new desc")
    assert_true("flow/set/info", info_result ~= nil, ie)
    if info_result and info_result.info then
      assert_eq("set_info name", info_result.info.name, "Renamed Flow")
      assert_eq("set_info description", info_result.info.description, "new desc")
    end

    -- Verify the rename stuck
    local verify, ve = numscull.flow_get_all()
    if verify and verify.flowInfos then
      local found = false
      for _, fi in ipairs(verify.flowInfos) do
        if fi.infoId == flow_id then
          assert_eq("renamed flow name", fi.name, "Renamed Flow")
          found = true
        end
      end
      assert_true("renamed flow found in get_all", found)
    end
  end

  -- Linked to (returns empty for mock)
  if flow_id then
    local linked, le = numscull.flow_linked_to(flow_id)
    assert_true("flow/linked/to", linked ~= nil, le)
    if linked then
      assert_eq("linked flowIds empty", #(linked.flowIds or {}), 0)
    end
  end

  -- Unlock
  if flow_id then
    local unlock_r, ue = numscull.flow_unlock(flow_id)
    assert_true("flow/unlock", unlock_r ~= nil, ue)
    if unlock_r then
      assert_eq("unlock returns flowId", unlock_r.flowId, flow_id)
    end
  end

  -- Remove flow
  if flow_id then
    local rem, re = numscull.flow_remove(flow_id)
    assert_true("flow/remove", rem ~= nil, re)

    -- Verify gone
    local after, ae = numscull.flow_get(flow_id)
    assert_nil("flow/get after remove is nil", after, "expected nil for removed flow")
  end
end

-----------------------------------------------------------------------
-- [Flows — Nodes]
-----------------------------------------------------------------------
print("\n[Flows — Nodes]")
do
  local numscull = require("numscull")
  local _, path, uri = open_test_file("flow_nodes.lua", "fn1\nfn2\nfn3\nfn4\nfn5\n")

  -- Create flow for node tests
  local cr, ce = numscull.flow_create("Node Flow", "flow for node tests")
  assert_true("node flow created", cr ~= nil, ce)
  local fid = cr and cr.flow and cr.flow.info and cr.flow.info.infoId

  if fid then
    -- Add first node
    local loc1 = { fileId = { uri = uri }, line = 1, startCol = 0, endCol = 3 }
    local n1, n1e = numscull.flow_add_node(loc1, "first node", "#ff0000", { flowId = fid })
    assert_true("add first node", n1 ~= nil, n1e)
    local node1_id = n1 and n1.nodeId

    -- Add second node as child of first
    local loc2 = { fileId = { uri = uri }, line = 3, startCol = 0, endCol = 3 }
    local n2, n2e = numscull.flow_add_node(loc2, "second node", "#00ff00", { flowId = fid, parentId = node1_id })
    assert_true("add second node (child of first)", n2 ~= nil, n2e)
    local node2_id = n2 and n2.nodeId
    assert_true("second node has different id", node2_id ~= nil and node2_id ~= node1_id)

    -- Fork node from first
    local loc3 = { fileId = { uri = uri }, line = 5, startCol = 0, endCol = 3 }
    local n3, n3e = numscull.flow_fork_node(loc3, "forked node", "#0000ff", node1_id)
    assert_true("fork node", n3 ~= nil, n3e)
    local node3_id = n3 and n3.nodeId

    -- Get flow and verify nodes and edges
    local flow, fe = numscull.flow_get(fid)
    assert_true("get flow with nodes", flow ~= nil, fe)
    if flow and flow.flow and flow.flow.nodes then
      local nodes = flow.flow.nodes
      -- Count nodes (keys may be numbers or strings depending on JSON)
      local count = 0
      for _ in pairs(nodes) do count = count + 1 end
      assert_eq("flow has 3 nodes", count, 3)

      -- Verify first node has outEdges to node2 and node3
      local first = nodes[node1_id] or nodes[tostring(node1_id)]
      if first then
        local out = first.outEdges or {}
        assert_eq("first node outEdges count", #out, 2)
      end
    end

    -- Set/update a node
    local set_r, set_e = numscull.flow_set_node(node2_id, {
      location = loc2,
      note = "updated second node",
      color = "#00ffff",
      outEdges = {},
      inEdges = { node1_id },
    })
    assert_true("set_node succeeds", set_r ~= nil, set_e)

    -- Verify update
    local flow2, f2e = numscull.flow_get(fid)
    if flow2 and flow2.flow and flow2.flow.nodes then
      local updated = flow2.flow.nodes[node2_id] or flow2.flow.nodes[tostring(node2_id)]
      if updated then
        assert_eq("set_node note updated", updated.note, "updated second node")
        assert_eq("set_node color updated", updated.color, "#00ffff")
      end
    end

    -- Remove a node
    local rm_n, rm_e = numscull.flow_remove_node(node3_id)
    assert_true("remove_node succeeds", rm_n ~= nil, rm_e)

    -- Verify node removed
    local flow3, f3e = numscull.flow_get(fid)
    if flow3 and flow3.flow and flow3.flow.nodes then
      local count = 0
      for _ in pairs(flow3.flow.nodes) do count = count + 1 end
      assert_eq("2 nodes after remove_node", count, 2)
    end

    -- Clean up flow
    numscull.flow_remove(fid)
  end

  close_buf()
end

-----------------------------------------------------------------------
-- [Flows — List Scratch Buffer]
-----------------------------------------------------------------------
print("\n[Flows — List Scratch Buffer]")
do
  local numscull = require("numscull")
  local flow_mod = require("numscull.flow")

  -- Create two flows for listing
  numscull.flow_create("List Flow A", "desc A")
  numscull.flow_create("List Flow B", "desc B")

  local orig_buf = api.nvim_get_current_buf()
  flow_mod.list()

  local list_buf = api.nvim_get_current_buf()
  assert_true("flow list: opened new buffer", list_buf ~= orig_buf)
  assert_eq("flow list: buftype nofile", vim.bo[list_buf].buftype, "nofile")
  assert_eq("flow list: filetype", vim.bo[list_buf].filetype, "numscull_flows")

  local lines = api.nvim_buf_get_lines(list_buf, 0, -1, false)
  assert_match("flow list: header", lines[1], "Flows")

  local found_a, found_b = false, false
  for _, l in ipairs(lines) do
    if l:find("List Flow A") then found_a = true end
    if l:find("List Flow B") then found_b = true end
  end
  assert_true("flow list: shows Flow A", found_a)
  assert_true("flow list: shows Flow B", found_b)

  close_buf()
end

-----------------------------------------------------------------------
-- [Flows — Show Detail]
-----------------------------------------------------------------------
print("\n[Flows — Show Detail]")
do
  local numscull = require("numscull")
  local flow_mod = require("numscull.flow")

  -- Create a flow and add a node
  local cr = numscull.flow_create("Detail Flow", "detail desc")
  local fid = cr and cr.flow and cr.flow.info and cr.flow.info.infoId

  if fid then
    local _, _, uri = open_test_file("flow_show.lua", "show1\nshow2\nshow3\n")
    local loc = { fileId = { uri = uri }, line = 2, startCol = 0, endCol = 4 }
    numscull.flow_add_node(loc, "show node", "#aabbcc", { flowId = fid })
    close_buf()

    local orig_buf = api.nvim_get_current_buf()
    flow_mod.show(fid)

    local show_buf = api.nvim_get_current_buf()
    assert_true("flow show: opened new buffer", show_buf ~= orig_buf)
    assert_eq("flow show: buftype nofile", vim.bo[show_buf].buftype, "nofile")
    assert_eq("flow show: filetype", vim.bo[show_buf].filetype, "numscull_flow")

    local lines = api.nvim_buf_get_lines(show_buf, 0, -1, false)
    assert_match("flow show: header has name", lines[1], "Detail Flow")

    local found_node = false
    for _, l in ipairs(lines) do
      if l:find("show node") then found_node = true end
    end
    assert_true("flow show: node visible", found_node)

    close_buf()
    numscull.flow_remove(fid)
  end
end

-----------------------------------------------------------------------
-- [Flows — add_node_at_cursor]
-----------------------------------------------------------------------
print("\n[Flows — add_node_at_cursor]")
do
  local numscull = require("numscull")
  local flow_mod = require("numscull.flow")

  local cr = numscull.flow_create("Cursor Node Flow", "test cursor add")
  local fid = cr and cr.flow and cr.flow.info and cr.flow.info.infoId

  if fid then
    local bufnr, path, uri = open_test_file("cursor_node.lua", "c1\nc2\nc3\n")
    api.nvim_win_set_cursor(0, { 2, 0 })

    -- Test location_at_cursor
    local loc = flow_mod.location_at_cursor(bufnr)
    assert_true("location_at_cursor returns table", loc ~= nil)
    if loc then
      assert_true("location has fileId", loc.fileId ~= nil)
      assert_eq("location line", loc.line, 2)
    end

    -- add_node_at_cursor (pass note directly to avoid input() prompt)
    flow_mod.add_node_at_cursor(fid, "cursor node", "#112233")

    -- Verify node was added
    local flow, fe = numscull.flow_get(fid)
    if flow and flow.flow and flow.flow.nodes then
      local count = 0
      local found = false
      for _, node in pairs(flow.flow.nodes) do
        count = count + 1
        if node.note == "cursor node" then found = true end
      end
      assert_gte("cursor node: at least 1 node", count, 1)
      assert_true("cursor node: correct note text", found)
    end

    close_buf()
    numscull.flow_remove(fid)
  end
end

-----------------------------------------------------------------------
-- [Flows — Error Cases]
-----------------------------------------------------------------------
print("\n[Flows — Error Cases]")
do
  local numscull = require("numscull")

  -- Get non-existent flow
  local r, err = numscull.flow_get(999999)
  assert_nil("get nonexistent flow returns nil", r, "expected nil for missing flow")
  assert_true("get nonexistent flow has error", err ~= nil)

  -- Remove node that doesn't exist
  local rn, rne = numscull.flow_remove_node(999999)
  assert_nil("remove nonexistent node returns nil", rn, "expected nil for missing node")

  -- Set node that doesn't exist
  local sn, sne = numscull.flow_set_node(999999, { note = "nope" })
  assert_nil("set nonexistent node returns nil", sn, "expected nil for missing node")
end

-----------------------------------------------------------------------
-- [Control — Remove Project]
-----------------------------------------------------------------------
print("\n[Control — Remove Project]")
do
  local control = require("numscull.control")
  local numscull = require("numscull")

  -- Create a temp project
  numscull.create_project("to-delete", "/tmp/del", TEST_IDENTITY)

  -- Verify it's in the list
  local before = numscull.list_projects()
  local found_before = false
  if before and before.projects then
    for _, p in ipairs(before.projects) do
      if p.name == "to-delete" then found_before = true end
    end
  end
  assert_true("remove: project exists before", found_before)

  -- Remove it
  local rm, rme = control.remove_project("to-delete")
  assert_true("remove project succeeds", rme == nil, rme)

  -- Verify it's gone
  local after = numscull.list_projects()
  local found_after = false
  if after and after.projects then
    for _, p in ipairs(after.projects) do
      if p.name == "to-delete" then found_after = true end
    end
  end
  assert_true("remove: project gone after", not found_after)
end

-----------------------------------------------------------------------
-- [Control — Exit and Reconnect]
-----------------------------------------------------------------------
print("\n[Control — Exit and Reconnect]")
do
  local numscull = require("numscull")
  local client = require("numscull.client")

  -- Graceful exit
  numscull.exit()
  assert_true("exit: client disconnected", not client.is_connected())

  -- Reconnect
  reload_numscull()
  numscull = require("numscull")
  numscull.setup({ config_dir = config_dir, identity = TEST_IDENTITY, auto_fetch = false })
  local ok, err = numscull.connect("127.0.0.1", TEST_PORT)
  assert_true("reconnect after exit", ok, err)

  -- Should be able to use the connection
  numscull.change_project("test-proj")
  local list, le = numscull.list_projects()
  assert_true("reconnect: list_projects works", le == nil, le)
end

-----------------------------------------------------------------------
-- [Notes — Disconnected Behavior]
-----------------------------------------------------------------------
print("\n[Notes — Disconnected Behavior]")
do
  local numscull = require("numscull")

  -- Disconnect
  numscull.disconnect()

  -- All APIs should return nil, "not connected"
  local r1, e1 = numscull.for_file("file://test")
  assert_nil("disconnected: for_file nil", r1)
  assert_match("disconnected: for_file error", e1, "not connected")

  local r2, e2 = numscull.set(make_note_input("file://x", 1, "t"))
  assert_nil("disconnected: set nil", r2)

  local r3, e3 = numscull.search("test")
  assert_nil("disconnected: search nil", r3)
  assert_match("disconnected: search error", e3, "not connected")

  local r4, e4 = numscull.flow_create("x", "y")
  assert_nil("disconnected: flow_create nil", r4)
  assert_match("disconnected: flow_create error", e4, "not connected")

  local r5, e5 = numscull.flow_get_all()
  assert_nil("disconnected: flow_get_all nil", r5)

  local r6, e6 = numscull.tag_count()
  assert_nil("disconnected: tag_count nil", r6)

  -- Reconnect for remaining tests
  reload_numscull()
  numscull = require("numscull")
  numscull.setup({ config_dir = config_dir, identity = TEST_IDENTITY, auto_fetch = false })
  numscull.connect("127.0.0.1", TEST_PORT)
  numscull.change_project("test-proj")
end

-----------------------------------------------------------------------
-- [Notes — No Active Project]
-- The mock server persists active_project across connections (per server
-- instance), so to test "no active project" we remove the project that
-- is currently active on the server side.
-----------------------------------------------------------------------
print("\n[Notes — No Active Project]")
do
  local numscull = require("numscull")
  local control = require("numscull.control")

  -- Remove the active project so the server has no active_project
  control.remove_project("test-proj")

  -- Now notes operations should return control/error
  local r, err = numscull.set(make_note_input("file://test", 1, "orphan"))
  assert_nil("no project: notes/set returns nil", r, "expected nil with no project")
  assert_true("no project: error message", err ~= nil)

  -- Re-create and re-activate for subsequent tests
  numscull.create_project("test-proj", "/tmp/test", TEST_IDENTITY)
  numscull.change_project("test-proj")
end

-----------------------------------------------------------------------
-- [Plugin — Command Registration]
-----------------------------------------------------------------------
print("\n[Plugin — Command Registration]")
do
  -- Load plugin files explicitly (headless -u NONE doesn't auto-source plugin/)
  vim.g.loaded_numscull = nil
  vim.cmd("runtime plugin/numscull.lua")

  local expected_cmds = {
    "NumscullConnect", "NumscullDisconnect", "NumscullProject", "NumscullListProjects",
    "NoteAdd", "NoteEdit", "NoteDelete", "NoteList", "NoteShow", "NoteToggle",
    "NoteSearch", "NoteSearchTags", "NoteTagCount",
    "FlowCreate", "FlowDelete", "FlowSelect", "FlowList", "FlowShow",
    "FlowAddNode", "FlowDeleteNode", "FlowNext", "FlowPrev",
    "FlowRemoveNode", "FlowRemove",
  }
  for _, cmd_name in ipairs(expected_cmds) do
    local cmd_exists = vim.fn.exists(":" .. cmd_name) >= 2
    assert_true("cmd: " .. cmd_name .. " registered", cmd_exists)
  end
end

-----------------------------------------------------------------------
-- [Highlight Groups]
-----------------------------------------------------------------------
print("\n[Highlight Groups]")
do
  -- notes.setup() creates these highlight groups
  local notes_mod = require("numscull.notes")
  notes_mod.setup({ icon = "N", max_line_len = 80 })

  local function hl_exists(name)
    local ok, hl = pcall(api.nvim_get_hl_by_name, name, true)
    return ok and hl ~= nil
  end

  assert_true("hl: NumscullHeader exists", hl_exists("NumscullHeader"))
  assert_true("hl: NumscullDim exists", hl_exists("NumscullDim"))
end

-----------------------------------------------------------------------
-- [Notes — Closest Note Finding]
-----------------------------------------------------------------------
print("\n[Notes — Closest Note Finding]")
do
  local numscull = require("numscull")
  local notes_mod = require("numscull.notes")
  local bufnr, path, uri = open_test_file("closest.lua",
    "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n")

  -- Add notes on lines 2 and 8
  numscull.set(make_note_input(uri, 2, "near top"))
  numscull.set(make_note_input(uri, 8, "near bottom"))
  numscull.for_file(uri)
  notes_mod.decorate(bufnr)

  -- Cursor at line 1 — closest should be line 2
  api.nvim_win_set_cursor(0, { 1, 0 })
  local cached = notes_mod.get_cached(uri)
  assert_true("closest: cache has 2 notes", cached ~= nil and #cached == 2)

  -- Cursor at line 5 — equidistant, should pick one (line 2 is dist 3, line 8 is dist 3)
  -- Implementation picks the one with smallest dist (first found with equal dist)
  api.nvim_win_set_cursor(0, { 5, 0 })

  -- Cursor at line 9 — closest should be line 8
  api.nvim_win_set_cursor(0, { 9, 0 })

  numscull.remove(uri, 2)
  numscull.remove(uri, 8)
  close_buf()
end

-----------------------------------------------------------------------
-- [Notes — Extmark Clamp to Buffer Length]
-----------------------------------------------------------------------
print("\n[Notes — Extmark Clamp to Buffer Length]")
do
  local numscull = require("numscull")
  local notes_mod = require("numscull.notes")
  -- File has 3 lines, but note is on line 10 — should clamp
  local bufnr, path, uri = open_test_file("clamp.lua", "a\nb\nc\n")

  numscull.set(make_note_input(uri, 10, "beyond end"))
  numscull.for_file(uri)
  notes_mod.decorate(bufnr)

  local ns_id = api.nvim_create_namespace("numscull_notes")
  local marks = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
  assert_gte("clamp: extmark placed", #marks, 1)
  if #marks >= 1 then
    -- Row should be clamped to last line (line 3 = row 2)
    local row = marks[1][2]
    assert_true("clamp: row <= 2 (last line)", row <= 2)
  end

  numscull.remove(uri, 10)
  close_buf()
end

-----------------------------------------------------------------------
-- [Notes — Multi-line Note Rendering]
-----------------------------------------------------------------------
print("\n[Notes — Multi-line Note Rendering]")
do
  local numscull = require("numscull")
  local notes_mod = require("numscull.notes")
  local bufnr, path, uri = open_test_file("multiline.lua", "x\ny\nz\n")

  numscull.set(make_note_input(uri, 1, "line one\nline two\nline three"))
  numscull.for_file(uri)
  notes_mod.decorate(bufnr)

  local ns_id = api.nvim_create_namespace("numscull_notes")
  local detail = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
  assert_gte("multiline: extmark placed", #detail, 1)
  if #detail >= 1 then
    local vl = detail[1][4].virt_lines or {}
    -- Multi-line note should have 3 virtual lines (header + 2 continuation)
    assert_eq("multiline: 3 virt_lines", #vl, 3)
    if #vl >= 3 then
      -- First line is header with "line one"
      assert_match("multiline: first virt_line", vl[1][1][1], "line one")
      -- Continuation lines are dimmed
      assert_match("multiline: second virt_line", vl[2][1][1], "line two")
      assert_match("multiline: third virt_line", vl[3][1][1], "line three")
      -- Continuation lines use NumscullDim highlight
      assert_eq("multiline: continuation hl", vl[2][1][2], "NumscullDim")
    end
  end

  numscull.remove(uri, 1)
  close_buf()
end

-----------------------------------------------------------------------
-- [Notes — Setup Config]
-----------------------------------------------------------------------
print("\n[Notes — Setup Config]")
do
  local notes_mod = require("numscull.notes")

  -- Reset to defaults first (earlier tests may have changed config)
  notes_mod.setup({ icon = "📝", max_line_len = 120 })
  assert_eq("notes config icon reset", notes_mod.config.icon, "📝")
  assert_eq("notes config max_line_len reset", notes_mod.config.max_line_len, 120)

  -- Override
  notes_mod.setup({ icon = "X", max_line_len = 80 })
  assert_eq("notes config icon override", notes_mod.config.icon, "X")
  assert_eq("notes config max_line_len override", notes_mod.config.max_line_len, 80)

  -- Reset back
  notes_mod.setup({ icon = "📝", max_line_len = 120 })
end

-----------------------------------------------------------------------
-- [Main Module — Setup Config]
-----------------------------------------------------------------------
print("\n[Main Module — Setup Config]")
do
  local numscull = require("numscull")

  -- Verify config fields set from setup
  assert_eq("config host", numscull.config.host, "127.0.0.1")
  assert_eq("config identity", numscull.config.identity, TEST_IDENTITY)
  assert_eq("config config_dir", numscull.config.config_dir, config_dir)
  assert_eq("config auto_fetch", numscull.config.auto_fetch, false)
end

-----------------------------------------------------------------------
-- [Flows — Multiple Flows]
-----------------------------------------------------------------------
print("\n[Flows — Multiple Flows]")
do
  local numscull = require("numscull")

  local cr1 = numscull.flow_create("Multi A", "first")
  local cr2 = numscull.flow_create("Multi B", "second")
  local cr3 = numscull.flow_create("Multi C", "third")

  local fid1 = cr1 and cr1.flow and cr1.flow.info and cr1.flow.info.infoId
  local fid2 = cr2 and cr2.flow and cr2.flow.info and cr2.flow.info.infoId
  local fid3 = cr3 and cr3.flow and cr3.flow.info and cr3.flow.info.infoId

  assert_true("multi flow: all created", fid1 ~= nil and fid2 ~= nil and fid3 ~= nil)
  assert_true("multi flow: unique ids", fid1 ~= fid2 and fid2 ~= fid3)

  local all = numscull.flow_get_all()
  if all and all.flowInfos then
    -- Should have at least 3 (plus any leftovers from earlier tests)
    assert_gte("multi flow: at least 3 in get_all", #all.flowInfos, 3)
  end

  -- Remove one and verify count changes
  if fid2 then
    numscull.flow_remove(fid2)
    local after = numscull.flow_get_all()
    if after and after.flowInfos then
      local found = false
      for _, fi in ipairs(after.flowInfos) do
        if fi.infoId == fid2 then found = true end
      end
      assert_true("multi flow: removed flow not in list", not found)
    end
  end

  -- Clean up
  if fid1 then numscull.flow_remove(fid1) end
  if fid3 then numscull.flow_remove(fid3) end
end

-----------------------------------------------------------------------
-- [Client — is_connected]
-----------------------------------------------------------------------
print("\n[Client — is_connected]")
do
  local client = require("numscull.client")
  assert_true("client is_connected", client.is_connected())
end

end -- if integration_ok

end -- if server_job

-----------------------------------------------------------------------
-- Cleanup
-----------------------------------------------------------------------
do
  local numscull_ok, numscull = pcall(require, "numscull")
  if numscull_ok and numscull then
    pcall(numscull.disconnect)
  end
  stop_mock_server()
end

-----------------------------------------------------------------------
print("\n=== Results ===")
print(string.format("  Passed: %d", passed))
print(string.format("  Failed: %d", failed))
print(string.format("  Skipped: %d", skipped))
print(string.format("  Total:  %d", passed + failed + skipped))

if #errors > 0 then
  print("\nFailed tests:")
  for _, e in ipairs(errors) do
    print(string.format("  - %s: %s", e.name, e.msg))
  end
end

fn.delete(config_dir, "rf")

if failed > 0 then
  print("\nTEST SUITE FAILED")
  os.exit(1)
else
  print("\nALL TESTS PASSED")
  os.exit(0)
end
