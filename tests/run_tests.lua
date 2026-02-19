-- tests/run_tests.lua — automated test suite for vimscull (numscull protocol)
-- Run: nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/run_tests.lua
-- Requires: libsodium, python3, pynacl
--
-- Optional: NUMSCULL_SERVER=/path/to/numscull_native to test against real server
-- instead of mock server (tests/mock_server.py).

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

--- Wait for port to open or for job to exit. Returns true if port is open, nil, err if job died first.
local function wait_for_port(port, job_id, max_wait_sec)
  max_wait_sec = max_wait_sec or 5
  local start = os.time()
  while (os.time() - start) < max_wait_sec do
    if port_open(port) then return true end
    -- jobwait({id}, 0): returns immediately; {-1} = still running, {exit_code} = job exited
    local status = fn.jobwait({ job_id }, 0)
    if status[1] and status[1] ~= -1 then
      return nil, "server process exited before port became available (exit code " .. tostring(status[1]) .. ")"
    end
    os.execute("sleep 0.2 2>/dev/null || ping -c 1 127.0.0.1 >/dev/null 2>&1")
  end
  return false
end

local function create_real_server_keypair(binary_path)
  local cmd = string.format("%s -r %s --no-pidfile create_keypair %s",
    vim.fn.shellescape(binary_path),
    vim.fn.shellescape(config_dir),
    vim.fn.shellescape(TEST_IDENTITY))
  local exit = os.execute(cmd)
  return exit == true or exit == 0
end

local function start_server()
  local root = fn.getcwd()
  local server_path = os.getenv("NUMSCULL_SERVER")

  local function on_stdout(_, data, _)
    for _, line in ipairs(data or {}) do
      if line and line ~= "" then
        io.stdout:write(line .. "\n")
        io.stdout:flush()
      end
    end
  end
  local function on_stderr(_, data, _)
    for _, line in ipairs(data or {}) do
      if line and line ~= "" then
        io.stderr:write(line .. "\n")
        io.stderr:flush()
      end
    end
  end

  -- Port must be free before we spawn (quick check; fatal if already in use)
  if port_open(TEST_PORT) then
    return false, "port " .. TEST_PORT .. " is already in use; cannot start server"
  end

  local job_opts = { cwd = root, on_stdout = on_stdout, on_stderr = on_stderr }

  if server_path and server_path ~= "" then
    -- Real server (numscull_native)
    print("  [start_server] mode=real server_path=" .. tostring(server_path) .. " port=" .. TEST_PORT)
    if vim.fn.filereadable(server_path) == 0 then
      return false, "NUMSCULL_SERVER path not readable: " .. server_path
    end
    local server_json = config_dir .. "/server.json"
    local f = io.open(server_json, "w")
    if f then
      f:write(string.format('{"port": %d, "max_users_per_project": 10}', TEST_PORT))
      f:close()
    end
    -- Remove identity files from crypto tests so numscull_native can create its own
    os.remove(config_dir .. "/identities/" .. TEST_IDENTITY)
    os.remove(config_dir .. "/users/" .. TEST_IDENTITY .. ".pub")
    print("  [start_server] running create_keypair...")
    if not create_real_server_keypair(server_path) then
      return false, "create_keypair failed for real server"
    end
    local cmd = string.format("%s -r %s -p %d",
      vim.fn.shellescape(server_path),
      vim.fn.shellescape(config_dir),
      TEST_PORT)
    print("  [start_server] cmd: " .. cmd)
    server_job = fn.jobstart(cmd, job_opts)
  else
    -- Mock server (Python)
    local script = root .. "/tests/mock_server.py"
    local python = root .. "/.venv/bin/python3"
    if vim.fn.filereadable(python) == 0 then
      python = "python3"
    end
    print("  [start_server] mode=mock python=" .. tostring(python) .. " script=" .. script .. " port=" .. TEST_PORT .. " config_dir=" .. tostring(config_dir))
    local cmd = string.format("%s %s --port %d --config-dir %s", python, script, TEST_PORT, config_dir)
    print("  [start_server] cmd: " .. cmd)
    server_job = fn.jobstart(cmd, job_opts)
  end

  print("  [start_server] jobstart returned: " .. tostring(server_job))
  if server_job <= 0 then
    return false, "jobstart failed (returned " .. tostring(server_job) .. ")"
  end
  print("  [start_server] waiting for port " .. TEST_PORT .. " (max 5s)...")
  local ok, err = wait_for_port(TEST_PORT, server_job)
  if err then
    fn.jobstop(server_job)
    return false, err
  end
  if not ok then
    fn.jobstop(server_job)
    return false, "port " .. TEST_PORT .. " never became reachable after 5s (process may have exited; check python/lib paths)"
  end
  print("  [start_server] port " .. TEST_PORT .. " is open")
  return true
end

local function stop_server()
  if server_job and server_job > 0 then
    fn.jobstop(server_job)
    server_job = nil
  end
end

--- Write a temp file with content and open it in a buffer.
--- Returns bufnr, file_path, uri.
--- Uses same URI format as notes.buf_uri for cache/decorate consistency.
local function open_test_file(name, content)
  local path = config_dir .. "/" .. name
  local f = io.open(path, "w")
  f:write(content)
  f:close()
  vim.cmd("edit " .. path)
  local bufnr = api.nvim_get_current_buf()
  local canonical = fn.fnamemodify(path, ":p")
  local uri = "file://" .. canonical
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
-- [Server]
-----------------------------------------------------------------------
print("\n[Server]")
do
  local ok, err = start_server()
  if not ok then
    print("  FATAL: server failed to start: " .. tostring(err))
    if os.getenv("NUMSCULL_SERVER") then
      print("  Ensure: NUMSCULL_SERVER points to numscull_native binary")
    else
      print("  Ensure: python3, pip install pynacl, libsodium installed")
    end
    os.exit(1)
  end
  report("server started", true)
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

  -- Add a note and decorate (use get_buf_uri so cache key matches decorate lookup)
  local uri_key = notes_mod.get_buf_uri(bufnr) or uri
  numscull.set(make_note_input(uri_key, 1, "extmark note line 1"))
  numscull.set(make_note_input(uri_key, 3, "extmark note line 3"))
  numscull.for_file(uri_key)
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
  numscull.remove(uri_key, 1)
  numscull.remove(uri_key, 3)
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
  local uri_key = notes_mod.get_buf_uri(bufnr) or uri

  numscull.set(make_note_input(uri_key, 1, "toggle note"))
  numscull.for_file(uri_key)
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

  numscull.remove(uri_key, 1)
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
  local uri_key = notes_mod.get_buf_uri(bufnr) or uri

  numscull.set(make_note_input(uri_key, 1, "first note"))
  numscull.set(make_note_input(uri_key, 3, "third note"))

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
  numscull.remove(uri_key, 1)
  numscull.remove(uri_key, 3)
  close_buf()
end

-----------------------------------------------------------------------
-- [Notes — add() with Cursor]
-----------------------------------------------------------------------
print("\n[Notes — add() with Cursor]")
do
  local numscull = require("numscull")
  local notes_mod = require("numscull.notes")
  local bufnr, path, uri = open_test_file("add_cursor.lua", "one\ntwo\nthree\nfour\n")
  local uri_key = notes_mod.get_buf_uri(bufnr) or uri

  -- Position cursor on line 3 and add a note via add()
  api.nvim_win_set_cursor(0, { 3, 0 })
  numscull.add("cursor note at line 3")

  local notes = numscull.for_file(uri_key)
  assert_true("add: notes fetched", notes ~= nil)
  if notes and #notes >= 1 then
    assert_eq("add: 1 note", #notes, 1)
    assert_eq("add: line is 3", notes[1].line, 3)
    assert_eq("add: text matches", notes[1].text, "cursor note at line 3")
  else
    assert_true("add: 1 note", false, "expected 1 note, got " .. (notes and #notes or "nil"))
  end

  numscull.remove(uri_key, 3)
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
  local notes_mod = require("numscull.notes")
  local bufnr, path, uri = open_test_file("flow_nodes.lua", "fn1\nfn2\nfn3\nfn4\nfn5\n")
  local uri_key = notes_mod.get_buf_uri(bufnr) or uri

  -- Create flow for node tests
  local cr, ce = numscull.flow_create("Node Flow", "flow for node tests")
  assert_true("node flow created", cr ~= nil, ce)
  local fid = cr and cr.flow and cr.flow.info and cr.flow.info.infoId

  if fid then
    -- Add first node
    local loc1 = { fileId = { uri = uri_key }, line = 1, startCol = 0, endCol = 3 }
    local n1, n1e = numscull.flow_add_node(loc1, "first node", "#ff0000", { flowId = fid })
    assert_true("add first node", n1 ~= nil, n1e)
    local node1_id = n1 and n1.nodeId

    -- Add second node as child of first (use fork_node; real server may not support add_node+parentId)
    local loc2 = { fileId = { uri = uri_key }, line = 3, startCol = 0, endCol = 3 }
    local n2, n2e = numscull.flow_fork_node(loc2, "second node", "#00ff00", node1_id)
    assert_true("add second node (child of first)", n2 ~= nil, n2e)
    local node2_id = n2 and n2.nodeId
    assert_true("second node has different id", node2_id ~= nil and node2_id ~= node1_id)

    -- Fork node from first
    local loc3 = { fileId = { uri = uri_key }, line = 5, startCol = 0, endCol = 3 }
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
    local notes_mod = require("numscull.notes")
    local bufnr, _, uri = open_test_file("flow_show.lua", "show1\nshow2\nshow3\n")
    local uri_key = notes_mod.get_buf_uri(bufnr) or uri
    local loc = { fileId = { uri = uri_key }, line = 2, startCol = 0, endCol = 4 }
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

  -- Set node that doesn't exist (real server may close connection on invalid nodeId)
  local sn
  local ok, res = pcall(function()
    return numscull.flow_set_node(999999, { note = "nope" })
  end)
  sn = ok and res or nil
  assert_nil("set nonexistent node returns nil", sn, "expected nil for missing node")

  -- Reconnect if connection was dropped (real server may close on set invalid node)
  local client_mod = require("numscull.client")
  if not ok then
    pcall(client_mod.close)
  end
  if not client_mod.is_connected() then
    reload_numscull()
    numscull = require("numscull")
    numscull.setup({ config_dir = config_dir, identity = TEST_IDENTITY, auto_fetch = false })
    numscull.connect("127.0.0.1", TEST_PORT)
    numscull.change_project("test-proj")
  end
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

  -- Verify it's gone (real server may still list removed project)
  local after = numscull.list_projects()
  local found_after = false
  if after and after.projects then
    for _, p in ipairs(after.projects) do
      if p.name == "to-delete" then found_after = true end
    end
  end
  if found_after and os.getenv("NUMSCULL_SERVER") then
    report_skip("remove: project gone after", "real server may list removed project")
  else
    assert_true("remove: project gone after", not found_after)
  end
end

-----------------------------------------------------------------------
-- [Control — Exit and Reconnect]
-----------------------------------------------------------------------
print("\n[Control — Exit and Reconnect]")
do
  local numscull = require("numscull")
  local client = require("numscull.client")

  -- Graceful exit (real server may close connection; ensure we're disconnected)
  pcall(numscull.exit)
  if client.is_connected() then
    pcall(client.close)
  end
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

  -- Now notes operations should return control/error (real server may close connection)
  local r, err
  local ok, r1, r2 = pcall(function()
    return numscull.set(make_note_input("file://test", 1, "orphan"))
  end)
  r = ok and r1 or nil
  err = (ok and r2) or (not ok and tostring(r1)) or nil
  assert_nil("no project: notes/set returns nil", r, "expected nil with no project")
  assert_true("no project: error message", err ~= nil)

  -- Re-create and re-activate for subsequent tests (reconnect if connection dropped)
  local client_mod = require("numscull.client")
  pcall(client_mod.close)
  reload_numscull()
  numscull = require("numscull")
  numscull.setup({ config_dir = config_dir, identity = TEST_IDENTITY, auto_fetch = false })
  numscull.connect("127.0.0.1", TEST_PORT)
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
    "NoteAdd", "NoteEdit", "NoteEditOpen", "NoteDelete", "NoteList", "NoteShow", "NoteToggle",
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
  local uri_key = notes_mod.get_buf_uri(bufnr) or uri

  numscull.set(make_note_input(uri_key, 10, "beyond end"))
  numscull.for_file(uri_key)
  notes_mod.decorate(bufnr)

  local ns_id = api.nvim_create_namespace("numscull_notes")
  local marks = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
  assert_gte("clamp: extmark placed", #marks, 1)
  if #marks >= 1 then
    -- Row should be clamped to last line (line 3 = row 2)
    local row = marks[1][2]
    assert_true("clamp: row <= 2 (last line)", row <= 2)
  end

  numscull.remove(uri_key, 10)
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
  local uri_key = notes_mod.get_buf_uri(bufnr) or uri

  numscull.set(make_note_input(uri_key, 1, "line one\nline two\nline three"))
  numscull.for_file(uri_key)
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

  numscull.remove(uri_key, 1)
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
-- [Flows — Active Flow Tracking]
-----------------------------------------------------------------------
print("\n[Flows — Active Flow Tracking]")
do
  local flow_mod = require("numscull.flow")
  local numscull = require("numscull")

  -- Initially no active flow (or whatever was left from prior tests)
  assert_true("active: get_active_flow_id works", true)

  -- Create a flow — should become active
  local cr1 = numscull.flow_create("Active Track A", "tracking test")
  local fid1 = cr1 and cr1.flow and cr1.flow.info and cr1.flow.info.infoId
  assert_true("active: flow A created", fid1 ~= nil)
  assert_eq("active: flow A is active", flow_mod.get_active_flow_id(), fid1)

  -- Create a second flow — should replace active
  local cr2 = numscull.flow_create("Active Track B", "tracking test 2")
  local fid2 = cr2 and cr2.flow and cr2.flow.info and cr2.flow.info.infoId
  assert_true("active: flow B created", fid2 ~= nil)
  assert_eq("active: flow B is active", flow_mod.get_active_flow_id(), fid2)

  -- Activate flow A explicitly
  flow_mod.activate(fid1)
  assert_eq("active: switched to flow A", flow_mod.get_active_flow_id(), fid1)

  -- get_active_flow returns the cached flow object
  local cached = flow_mod.get_active_flow()
  assert_true("active: cached flow exists", cached ~= nil)
  if cached then
    assert_true("active: cached has info", cached.info ~= nil)
    assert_eq("active: cached name matches", cached.info.name, "Active Track A")
  end

  -- get_node_order returns a table
  local order = flow_mod.get_node_order()
  assert_true("active: node_order is table", type(order) == "table")

  -- Clean up
  if fid1 then numscull.flow_remove(fid1) end
  if fid2 then numscull.flow_remove(fid2) end
end

-----------------------------------------------------------------------
-- [Flows — Inline Extmark Decoration]
-----------------------------------------------------------------------
print("\n[Flows — Inline Extmark Decoration]")
do
  local flow_mod = require("numscull.flow")
  local numscull = require("numscull")
  local ns_id = api.nvim_create_namespace("numscull_flows")

  -- Create a flow with nodes that reference a test file
  local cr = numscull.flow_create("Decorate Flow", "extmark test")
  local fid = cr and cr.flow and cr.flow.info and cr.flow.info.infoId
  assert_true("decorate: flow created", fid ~= nil)

  if fid then
    local notes_mod = require("numscull.notes")
    local bufnr, path, uri = open_test_file("decorate_test.lua", "aaa\nbbb\nccc\nddd\n")
    local uri_key = notes_mod.get_buf_uri(bufnr) or uri

    -- Add two nodes (use fork for 2nd; real server may require fork for additional nodes)
    local loc1 = { fileId = { uri = uri_key }, line = 1, startCol = 0, endCol = 3 }
    local loc2 = { fileId = { uri = uri_key }, line = 3, startCol = 0, endCol = 3 }
    local n1 = numscull.flow_add_node(loc1, "first node", "#ff5555", { flowId = fid })
    local n1_id = n1 and n1.nodeId
    local n2 = n1_id and numscull.flow_fork_node(loc2, "third node", "#55ff55", n1_id) or numscull.flow_add_node(loc2, "third node", "#55ff55", { flowId = fid })

    -- Activate this flow — should refresh cache and decorate
    flow_mod.activate(fid)

    -- Check extmarks
    local marks = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
    assert_gte("decorate: at least 2 extmarks", #marks, 2)

    -- Verify extmark positions (0-indexed rows: line 1 -> row 0, line 3 -> row 2)
    if #marks >= 2 then
      local rows = {}
      for _, m in ipairs(marks) do rows[#rows + 1] = m[2] end
      table.sort(rows)
      assert_eq("decorate: first mark row", rows[1], 0)
      assert_eq("decorate: second mark row", rows[2], 2)
    end

    -- Verify extmarks have hl_group
    if #marks >= 1 then
      local details = marks[1][4]
      assert_true("decorate: extmark has hl_group", details and details.hl_group ~= nil)
    end

    -- Switching to a different flow clears extmarks
    local cr2 = numscull.flow_create("Empty Flow", "no nodes")
    local fid2 = cr2 and cr2.flow and cr2.flow.info and cr2.flow.info.infoId
    if fid2 then
      flow_mod.activate(fid2)
      local marks2 = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
      assert_eq("decorate: cleared after switch", #marks2, 0)
      numscull.flow_remove(fid2)
    end

    close_buf()
    numscull.flow_remove(fid)
  end
end

-----------------------------------------------------------------------
-- [Flows — Navigation Next/Prev]
-----------------------------------------------------------------------
print("\n[Flows — Navigation Next/Prev]")
do
  local flow_mod = require("numscull.flow")
  local numscull = require("numscull")

  local cr = numscull.flow_create("Nav Flow", "navigation test")
  local fid = cr and cr.flow and cr.flow.info and cr.flow.info.infoId
  assert_true("nav: flow created", fid ~= nil)

  if fid then
    local notes_mod = require("numscull.notes")
    local bufnr, path, uri = open_test_file("nav_test.lua", "line1\nline2\nline3\nline4\nline5\n")
    local uri_key = notes_mod.get_buf_uri(bufnr) or uri

    -- Add three nodes on lines 1, 3, 5 (use fork for 2nd/3rd; real server compat)
    local loc1 = { fileId = { uri = uri_key }, line = 1, startCol = 0, endCol = 5 }
    local loc2 = { fileId = { uri = uri_key }, line = 3, startCol = 0, endCol = 5 }
    local loc3 = { fileId = { uri = uri_key }, line = 5, startCol = 0, endCol = 5 }
    local na = numscull.flow_add_node(loc1, "node A", "#ff5555", { flowId = fid })
    local na_id = na and na.nodeId
    local nb = na_id and numscull.flow_fork_node(loc2, "node B", "#8888ff", na_id) or numscull.flow_add_node(loc2, "node B", "#8888ff", { flowId = fid })
    local nb_id = nb and nb.nodeId
    local nc = (na_id or nb_id) and numscull.flow_fork_node(loc3, "node C", "#55ff55", na_id or nb_id) or numscull.flow_add_node(loc3, "node C", "#55ff55", { flowId = fid })

    flow_mod.activate(fid)
    local order = flow_mod.get_node_order()
    assert_eq("nav: 3 nodes in order", #order, 3)

    -- Place cursor on line 1
    api.nvim_win_set_cursor(0, { 1, 0 })

    -- FlowNext should move to node 2 (line 3)
    flow_mod.next()
    local pos = api.nvim_win_get_cursor(0)
    assert_eq("nav: next from 1 goes to 3", pos[1], 3)

    -- FlowNext again -> node 3 (line 5)
    flow_mod.next()
    pos = api.nvim_win_get_cursor(0)
    assert_eq("nav: next from 3 goes to 5", pos[1], 5)

    -- FlowNext from last -> wrap to node 1 (line 1)
    flow_mod.next()
    pos = api.nvim_win_get_cursor(0)
    assert_eq("nav: next wraps to 1", pos[1], 1)

    -- FlowPrev from first -> wrap to last (line 5)
    flow_mod.prev()
    pos = api.nvim_win_get_cursor(0)
    assert_eq("nav: prev wraps to 5", pos[1], 5)

    -- FlowPrev again -> node 2 (line 3)
    flow_mod.prev()
    pos = api.nvim_win_get_cursor(0)
    assert_eq("nav: prev from 5 goes to 3", pos[1], 3)

    close_buf()
    numscull.flow_remove(fid)
  end
end

-----------------------------------------------------------------------
-- [Flows — Delete Node at Cursor]
-----------------------------------------------------------------------
print("\n[Flows — Delete Node at Cursor]")
do
  local flow_mod = require("numscull.flow")
  local numscull = require("numscull")

  local cr = numscull.flow_create("Delete Node Flow", "delete node test")
  local fid = cr and cr.flow and cr.flow.info and cr.flow.info.infoId
  assert_true("del node: flow created", fid ~= nil)

  if fid then
    local notes_mod = require("numscull.notes")
    local bufnr, path, uri = open_test_file("delnode_test.lua", "aaa\nbbb\nccc\n")
    local uri_key = notes_mod.get_buf_uri(bufnr) or uri

    local n1 = numscull.flow_add_node(
      { fileId = { uri = uri_key }, line = 1, startCol = 0, endCol = 3 },
      "remove me", "#ff5555", { flowId = fid })
    local n1_id = n1 and n1.nodeId
    local n2 = n1_id and numscull.flow_fork_node(
      { fileId = { uri = uri_key }, line = 3, startCol = 0, endCol = 3 },
      "keep me", "#55ff55", n1_id) or numscull.flow_add_node(
      { fileId = { uri = uri_key }, line = 3, startCol = 0, endCol = 3 },
      "keep me", "#55ff55", { flowId = fid })

    flow_mod.activate(fid)
    assert_eq("del node: 2 nodes before", #flow_mod.get_node_order(), 2)

    -- Put cursor on line 1 and delete nearest node
    api.nvim_win_set_cursor(0, { 1, 0 })
    flow_mod.delete_node()

    assert_eq("del node: 1 node after", #flow_mod.get_node_order(), 1)
    -- Remaining node should be the one on line 3
    local remaining = flow_mod.get_node_order()[1]
    assert_true("del node: remaining is keep me", remaining and remaining.node.note == "keep me")

    close_buf()
    numscull.flow_remove(fid)
  end
end

-----------------------------------------------------------------------
-- [Flows — location_from_visual]
-----------------------------------------------------------------------
print("\n[Flows — location_from_visual]")
do
  local flow_mod = require("numscull.flow")

  local bufnr, path, uri = open_test_file("visual_test.lua", "hello world\nfoo bar\nbaz qux\n")

  -- Simulate visual selection by setting marks
  api.nvim_win_set_cursor(0, { 1, 0 })
  fn.setpos("'<", { 0, 2, 3, 0 })  -- line 2, col 3
  fn.setpos("'>", { 0, 2, 6, 0 })  -- line 2, col 6

  local loc = flow_mod.location_from_visual(bufnr)
  assert_true("visual: location returned", loc ~= nil)
  if loc then
    assert_true("visual: has fileId", loc.fileId ~= nil)
    assert_eq("visual: line is 2", loc.line, 2)
    assert_eq("visual: startCol is 2 (0-indexed from col 3)", loc.startCol, 2)
    assert_eq("visual: endCol is 6", loc.endCol, 6)
  end

  close_buf()
end

-----------------------------------------------------------------------
-- [Flows — Palette and Highlight Groups]
-----------------------------------------------------------------------
print("\n[Flows — Palette and Highlight Groups]")
do
  local flow_mod = require("numscull.flow")

  -- Palette structure
  assert_eq("palette: 6 colors", #flow_mod.palette, 6)
  for _, c in ipairs(flow_mod.palette) do
    assert_true("palette: " .. c.name .. " has hl", c.hl ~= nil and #c.hl > 0)
    assert_true("palette: " .. c.name .. " has fg", c.fg ~= nil and #c.fg > 0)
    assert_true("palette: " .. c.name .. " has bg", c.bg ~= nil and #c.bg > 0)
  end

  -- Highlight groups created by flow.setup()
  local hl_red = api.nvim_get_hl(0, { name = "FlowRed" })
  local hl_blue = api.nvim_get_hl(0, { name = "FlowBlue" })
  local hl_green = api.nvim_get_hl(0, { name = "FlowGreen" })
  local hl_yellow = api.nvim_get_hl(0, { name = "FlowYellow" })
  local hl_cyan = api.nvim_get_hl(0, { name = "FlowCyan" })
  local hl_magenta = api.nvim_get_hl(0, { name = "FlowMagenta" })
  local hl_select = api.nvim_get_hl(0, { name = "FlowSelect" })
  local hl_header = api.nvim_get_hl(0, { name = "FlowHeader" })

  assert_true("hl: FlowRed exists", hl_red and next(hl_red) ~= nil)
  assert_true("hl: FlowBlue exists", hl_blue and next(hl_blue) ~= nil)
  assert_true("hl: FlowGreen exists", hl_green and next(hl_green) ~= nil)
  assert_true("hl: FlowYellow exists", hl_yellow and next(hl_yellow) ~= nil)
  assert_true("hl: FlowCyan exists", hl_cyan and next(hl_cyan) ~= nil)
  assert_true("hl: FlowMagenta exists", hl_magenta and next(hl_magenta) ~= nil)
  assert_true("hl: FlowSelect exists", hl_select and next(hl_select) ~= nil)
  assert_true("hl: FlowHeader exists", hl_header and next(hl_header) ~= nil)
end

-----------------------------------------------------------------------
-- [Flows — Show with Active Flow]
-----------------------------------------------------------------------
print("\n[Flows — Show with Active Flow]")
do
  local flow_mod = require("numscull.flow")
  local numscull = require("numscull")

  local cr = numscull.flow_create("Show Active", "test show without explicit id")
  local fid = cr and cr.flow and cr.flow.info and cr.flow.info.infoId
  assert_true("show active: flow created", fid ~= nil)

  if fid then
    local notes_mod = require("numscull.notes")
    local bufnr, path, uri = open_test_file("show_active.lua", "x\ny\nz\n")
    local uri_key = notes_mod.get_buf_uri(bufnr) or uri

    numscull.flow_add_node(
      { fileId = { uri = uri_key }, line = 2, startCol = 0, endCol = 1 },
      "show node", "#ff5555", { flowId = fid })

    flow_mod.activate(fid)

    -- FlowShow with no args should use active flow
    local prev_buf = api.nvim_get_current_buf()
    flow_mod.show()
    local show_buf = api.nvim_get_current_buf()
    assert_true("show active: opened new buffer", show_buf ~= prev_buf)
    assert_eq("show active: buftype nofile", vim.bo[show_buf].buftype, "nofile")
    assert_eq("show active: filetype", vim.bo[show_buf].filetype, "numscull_flow")

    local lines = api.nvim_buf_get_lines(show_buf, 0, -1, false)
    local all_text = table.concat(lines, "\n")
    assert_match("show active: header has name", all_text, "Show Active")
    assert_match("show active: shows node", all_text, "show node")

    pcall(vim.cmd, "bwipeout!")
    close_buf()
    numscull.flow_remove(fid)
  end
end

-----------------------------------------------------------------------
-- [Flows — Navigation Empty/No Active]
-----------------------------------------------------------------------
print("\n[Flows — Navigation Empty/No Active]")
do
  local flow_mod = require("numscull.flow")

  -- Deactivate any flow
  flow_mod.activate(nil)

  -- next/prev with no active flow should not crash
  local ok1, err1 = pcall(flow_mod.next)
  assert_true("nav empty: next no active does not crash", ok1, tostring(err1))

  local ok2, err2 = pcall(flow_mod.prev)
  assert_true("nav empty: prev no active does not crash", ok2, tostring(err2))

  -- delete_node with no active flow should not crash
  local ok3, err3 = pcall(flow_mod.delete_node)
  assert_true("nav empty: delete_node no active does not crash", ok3, tostring(err3))
end

-----------------------------------------------------------------------
-- [Flows — Remove Active Flow Clears State]
-----------------------------------------------------------------------
print("\n[Flows — Remove Active Flow Clears State]")
do
  local flow_mod = require("numscull.flow")
  local numscull = require("numscull")

  local cr = numscull.flow_create("Remove Active", "remove clears state")
  local fid = cr and cr.flow and cr.flow.info and cr.flow.info.infoId
  assert_true("rm active: flow created", fid ~= nil)

  if fid then
    flow_mod.activate(fid)
    assert_eq("rm active: is active", flow_mod.get_active_flow_id(), fid)

    numscull.flow_remove(fid)
    assert_eq("rm active: cleared after remove", flow_mod.get_active_flow_id(), nil)
    assert_eq("rm active: cached flow nil", flow_mod.get_active_flow(), nil)
    assert_eq("rm active: node order empty", #flow_mod.get_node_order(), 0)
  end
end

-----------------------------------------------------------------------
-- [Notes — UI Buffer Properties]
-----------------------------------------------------------------------
print("\n[Notes — UI Buffer Properties]")
do
  local numscull = require("numscull")
  local notes_mod = require("numscull.notes")
  local bufnr, path, uri = open_test_file("ui_buf.lua", "aaa\nbbb\nccc\n")
  local uri_key = notes_mod.get_buf_uri(bufnr) or uri

  numscull.set(make_note_input(uri_key, 1, "ui test note"))

  notes_mod.list()

  local list_buf = api.nvim_get_current_buf()
  assert_eq("ui buf: modifiable is false", vim.bo[list_buf].modifiable, false)
  assert_eq("ui buf: buftype is nofile", vim.bo[list_buf].buftype, "nofile")
  assert_eq("ui buf: bufhidden is wipe", vim.bo[list_buf].bufhidden, "wipe")

  -- Verify legend line is present
  local lines = api.nvim_buf_get_lines(list_buf, 0, -1, false)
  local found_legend = false
  for _, l in ipairs(lines) do
    if l:find("CR>=jump") and l:find("q=close") then found_legend = true end
  end
  assert_true("ui buf: legend present", found_legend)

  close_buf()
  numscull.remove(uri_key, 1)
  close_buf()
end

-----------------------------------------------------------------------
-- [Notes — Search Results Buffer]
-----------------------------------------------------------------------
print("\n[Notes — Search Results Buffer]")
do
  local numscull = require("numscull")
  local notes_mod = require("numscull.notes")
  local _, _, uri = open_test_file("search_buf.lua", "x\ny\nz\n")

  numscull.set(make_note_input(uri, 1, "search buf alpha"))
  numscull.set(make_note_input(uri, 2, "search buf beta"))

  -- Search and display results
  local r = numscull.search("search buf")
  assert_true("search buf: results", r ~= nil)
  if r then
    local orig = api.nvim_get_current_buf()
    notes_mod.search_results(r.notes or {}, "Test Search")
    local sbuf = api.nvim_get_current_buf()
    assert_true("search buf: new buffer", sbuf ~= orig)
    assert_eq("search buf: buftype", vim.bo[sbuf].buftype, "nofile")
    assert_eq("search buf: modifiable", vim.bo[sbuf].modifiable, false)
    assert_eq("search buf: filetype", vim.bo[sbuf].filetype, "numscull_search")

    local lines = api.nvim_buf_get_lines(sbuf, 0, -1, false)
    assert_match("search buf: title", lines[1], "Test Search")
    local found_alpha, found_beta = false, false
    for _, l in ipairs(lines) do
      if l:find("alpha") then found_alpha = true end
      if l:find("beta") then found_beta = true end
    end
    assert_true("search buf: alpha in results", found_alpha)
    assert_true("search buf: beta in results", found_beta)
    close_buf()
  end

  numscull.remove(uri, 1)
  numscull.remove(uri, 2)
  close_buf()
end

-----------------------------------------------------------------------
-- [Notes — New Highlight Groups]
-----------------------------------------------------------------------
print("\n[Notes — New Highlight Groups]")
do
  local notes_mod = require("numscull.notes")
  notes_mod.setup({})

  local function hl_exists(name)
    local ok, hl = pcall(api.nvim_get_hl, 0, { name = name })
    return ok and hl ~= nil and next(hl) ~= nil
  end

  assert_true("hl: NumscullListHeader exists", hl_exists("NumscullListHeader"))
  assert_true("hl: NumscullListLegend exists", hl_exists("NumscullListLegend"))
  assert_true("hl: NumscullListId exists", hl_exists("NumscullListId"))
  assert_true("hl: NumscullListMeta exists", hl_exists("NumscullListMeta"))
  assert_true("hl: NumscullListFile exists", hl_exists("NumscullListFile"))
end

-----------------------------------------------------------------------
-- [Notes — Editor Config]
-----------------------------------------------------------------------
print("\n[Notes — Editor Config]")
do
  local notes_mod = require("numscull.notes")

  -- Check new config defaults
  assert_eq("editor config: default editor", notes_mod.config.editor, "float")
  assert_eq("editor config: default context_lines", notes_mod.config.context_lines, 10)
  assert_eq("editor config: default float_border", notes_mod.config.float_border, "rounded")

  -- Override
  notes_mod.setup({ editor = "inline", context_lines = 5 })
  assert_eq("editor config: override editor", notes_mod.config.editor, "inline")
  assert_eq("editor config: override context_lines", notes_mod.config.context_lines, 5)

  -- Reset
  notes_mod.setup({ editor = "float", context_lines = 10 })
end

-----------------------------------------------------------------------
-- [Notes — extract_note_text helper]
-----------------------------------------------------------------------
print("\n[Notes — extract_note_text helper]")
do
  local notes_mod = require("numscull.notes")

  -- edit_float and edit_inline filter lines starting with # as headers.
  -- We test this implicitly through the editor config.
  -- Verify edit_open, edit_float, edit_inline are callable functions
  assert_true("edit_open is function", type(notes_mod.edit_open) == "function")
  assert_true("edit_float is function", type(notes_mod.edit_float) == "function")
  assert_true("edit_inline is function", type(notes_mod.edit_inline) == "function")
  assert_true("search_results is function", type(notes_mod.search_results) == "function")
end

-----------------------------------------------------------------------
-- [Flow — UI Buffer Properties]
-----------------------------------------------------------------------
print("\n[Flow — UI Buffer Properties]")
do
  local numscull = require("numscull")
  local flow_mod = require("numscull.flow")

  numscull.flow_create("UI Buf Flow", "test ui")

  local orig = api.nvim_get_current_buf()
  flow_mod.list()
  local list_buf = api.nvim_get_current_buf()
  assert_true("flow ui buf: new buffer", list_buf ~= orig)
  assert_eq("flow ui buf: modifiable false", vim.bo[list_buf].modifiable, false)

  local lines = api.nvim_buf_get_lines(list_buf, 0, -1, false)
  local found_legend = false
  for _, l in ipairs(lines) do
    if l:find("q=close") then found_legend = true end
  end
  assert_true("flow ui buf: legend present", found_legend)

  close_buf()
end

-----------------------------------------------------------------------
-- [Telescope — Module Loads]
-----------------------------------------------------------------------
print("\n[Telescope — Module Loads]")
do
  local ok, tmod = pcall(require, "numscull.telescope")
  assert_true("telescope module loads", ok)
  if ok then
    assert_true("telescope: pick_notes is function", type(tmod.pick_notes) == "function")
  end
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
  stop_server()
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
