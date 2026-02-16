-- tests/run_tests.lua — automated test suite for vimscull (numscull protocol)
-- Run: nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/run_tests.lua
-- Requires: libsodium, python3, pynacl

local api = vim.api
local fn = vim.fn
local uv = vim.uv

local passed, failed, skipped, errors = 0, 0, 0, {}
local TEST_PORT = 5111
local TEST_IDENTITY = "test-client"
local server_job = nil
local config_dir = nil

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

local function assert_true(name, val, msg)
  if val then
    report(name, true)
  else
    report(name, false, msg or "expected truthy value")
  end
end

local function assert_match(name, str, pattern)
  if type(str) == "string" and str:find(pattern) then
    report(name, true)
  else
    report(name, false, string.format("expected match for %q in %q", pattern, tostring(str)))
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
  -- Use jobstart; server runs in background
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

-----------------------------------------------------------------------
print("=== vimscull (numscull) test suite ===\n")

-- Test 0: Crypto loads (libsodium)
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
  end
end

-- Setup config dir and keypair
config_dir = fn.tempname()
fn.mkdir(config_dir, "p")
fn.mkdir(config_dir .. "/identities", "p")
fn.mkdir(config_dir .. "/users", "p")

do
  local crypto = require("numscull.crypto")
  if not crypto._load_error then
    local pk, sk = crypto.generate_x25519_keypair()
    crypto.write_keypair(config_dir, TEST_IDENTITY, pk, sk)
    report("test keypair written", true)
  else
    report("test keypair written", false, "crypto not available")
  end
end

-- Start mock server
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
  -- Integration tests
  print("\n[Connect & Init]")
  do
    package.loaded["numscull.client"] = nil
    package.loaded["numscull.control"] = nil
    package.loaded["numscull.notes"] = nil
    package.loaded["numscull.flow"] = nil
    package.loaded["numscull.init"] = nil
    local numscull = require("numscull")
    numscull.setup({ config_dir = config_dir, identity = TEST_IDENTITY, auto_fetch = false })
    local ok, err = numscull.connect("127.0.0.1", TEST_PORT)
    assert_true("connect + init", ok, err)
    local proj_result, proj_err = numscull.create_project("test-proj", "/tmp/test", TEST_IDENTITY)
    assert_true("create project", proj_err == nil, proj_err)
    local chg_ok, chg_err = numscull.change_project("test-proj")
    assert_true("change project", chg_err == nil, chg_err)
    integration_ok = true
  end

  if integration_ok then
  print("\n[Notes]")
  do
    local numscull = require("numscull")
    local test_file = config_dir .. "/sample.lua"
    local f = io.open(test_file, "w")
    f:write("local x = 1\nlocal y = 2\nlocal z = 3\nreturn x + y + z\n")
    f:close()
    vim.cmd("edit " .. test_file)
    local bufnr = api.nvim_get_current_buf()
    api.nvim_win_set_cursor(0, { 2, 0 })
    local uri = "file://" .. test_file
    local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local note_input = {
      location = { fileId = { uri = uri }, line = 2 },
      text = "test note #tag1",
      createdDate = now,
      modifiedDate = now,
    }
    local note, err = numscull.set(note_input)
    assert_true("notes/set", note ~= nil, err)
    if note then
      assert_eq("note text", note.text, "test note #tag1")
      assert_eq("note author", note.author, TEST_IDENTITY)
    end
    local notes, err2 = numscull.for_file(uri)
    assert_true("notes/for/file", notes ~= nil, err2)
    if notes then
      assert_true("notes returned", #notes >= 1)
    end
    local tag_result, err3 = numscull.tag_count()
    assert_true("notes/tag/count", tag_result ~= nil, err3)
    local ok_remove, err4 = numscull.remove(uri, 2)
    assert_true("notes/remove", ok_remove ~= nil, err4)
    local notes_after = numscull.for_file(uri)
    assert_true("notes empty after remove", notes_after and #notes_after == 0)
    vim.cmd("bwipeout!")
  end

  print("\n[Flows]")
  do
    local numscull = require("numscull")
    local result, err = numscull.flow_create("Test Flow", "description")
    assert_true("flow/create", result ~= nil, err)
    if result and result.flow then
      local fid = result.flow.info and result.flow.info.infoId
      assert_true("flow has infoId", fid ~= nil)
      local get_all, err2 = numscull.flow_get_all()
      assert_true("flow/get/all", get_all ~= nil, err2)
      if get_all and get_all.flowInfos then
        assert_true("flowInfos non-empty", #get_all.flowInfos >= 1)
      end
    end
  end

  print("\n[Extmarks]")
  do
    local numscull = require("numscull")
    local test_file = config_dir .. "/sample2.lua"
    local f = io.open(test_file, "w")
    f:write("local a = 1\nlocal b = 2\nreturn a + b\n")
    f:close()
    vim.cmd("edit " .. test_file)
    local bufnr = api.nvim_get_current_buf()
    api.nvim_win_set_cursor(0, { 1, 0 })
    numscull.add("extmark test note")
    local ns_id = api.nvim_create_namespace("numscull_notes")
    local marks = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
    assert_true("extmark placed", #marks >= 1)
    vim.cmd("bwipeout!")
  end

  end
  require("numscull").disconnect()
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
