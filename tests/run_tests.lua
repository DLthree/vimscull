-- tests/run_tests.lua — automated test suite for vimscull (audit_notes)
-- Run: nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/run_tests.lua

local api = vim.api
local fn = vim.fn

local passed, failed, errors = 0, 0, {}

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

-- Helpers
local test_dir = fn.tempname()
fn.mkdir(test_dir, "p")
local test_file = test_dir .. "/sample.lua"
local storage_file = test_dir .. "/notes.json"

local function write_sample_file()
  local f = io.open(test_file, "w")
  f:write("local x = 1\nlocal y = 2\nlocal z = 3\nreturn x + y + z\n")
  f:close()
end

local function read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local raw = f:read("*a"); f:close()
  local ok, data = pcall(vim.json.decode, raw)
  return ok and data or nil
end

local function fresh_setup()
  -- Remove any existing storage
  os.remove(storage_file)
  -- Reload the module fresh
  package.loaded["audit_notes"] = nil
  local audit = require("audit_notes")
  audit.setup({
    storage_path = storage_file,
    author = "tester",
    autosave = true,
    icon = ">>",
    max_line_len = 80,
  })
  return audit
end

local function open_test_file()
  write_sample_file()
  vim.cmd("edit " .. test_file)
  -- Trigger BufReadPost autocmd manually since headless edit might not fire it
  vim.cmd("doautocmd BufReadPost")
  return api.nvim_get_current_buf()
end

-----------------------------------------------------------------------
print("=== vimscull (audit_notes) test suite ===\n")

-- Test 1: Module loads and setup works
print("[Module & Setup]")
do
  local audit = fresh_setup()
  assert_true("module returns table", type(audit) == "table")
  assert_true("setup function exists", type(audit.setup) == "function")
  assert_true("add function exists", type(audit.add) == "function")
  assert_true("edit function exists", type(audit.edit) == "function")
  assert_true("delete function exists", type(audit.delete) == "function")
  assert_true("show function exists", type(audit.show) == "function")
  assert_true("list function exists", type(audit.list) == "function")
  assert_true("toggle function exists", type(audit.toggle) == "function")
  assert_true("export function exists", type(audit.export) == "function")
  assert_eq("config author set", audit.config.author, "tester")
  assert_eq("config storage_path set", audit.config.storage_path, storage_file)
  assert_eq("config icon set", audit.config.icon, ">>")
  assert_eq("config max_line_len set", audit.config.max_line_len, 80)
  assert_eq("config autosave set", audit.config.autosave, true)
end

-- Test 2: Add a note
print("\n[Add Note]")
do
  local audit = fresh_setup()
  local bufnr = open_test_file()

  -- Place cursor on line 2
  api.nvim_win_set_cursor(0, { 2, 0 })

  -- Add a note programmatically
  audit.add("This is a test note")

  -- Verify JSON was written
  local data = read_json(storage_file)
  assert_true("storage file created", data ~= nil)

  local fpath = fn.fnamemodify(test_file, ":p")
  assert_true("file key exists in storage", data[fpath] ~= nil)
  assert_eq("one note stored", #data[fpath], 1)

  local note = data[fpath][1]
  assert_eq("note text correct", note.text, "This is a test note")
  assert_eq("note author correct", note.author, "tester")
  assert_eq("note line correct", note.line, 2)
  assert_true("note has id", note.id ~= nil and #note.id > 0)
  assert_true("note has timestamp", note.timestamp ~= nil and #note.timestamp > 0)
  assert_match("timestamp ISO format", note.timestamp, "%d%d%d%d%-%d%d%-%d%dT")

  -- Verify extmarks were placed
  local marks = api.nvim_buf_get_extmarks(bufnr, api.nvim_create_namespace("audit_notes"), 0, -1, {})
  assert_true("extmark placed in buffer", #marks >= 1)

  vim.cmd("bwipeout!")
end

-- Test 3: Add multiple notes
print("\n[Multiple Notes]")
do
  local audit = fresh_setup()
  local bufnr = open_test_file()

  api.nvim_win_set_cursor(0, { 1, 0 })
  audit.add("First note")

  api.nvim_win_set_cursor(0, { 3, 0 })
  audit.add("Second note")

  api.nvim_win_set_cursor(0, { 4, 0 })
  audit.add("Third note")

  local data = read_json(storage_file)
  local fpath = fn.fnamemodify(test_file, ":p")
  assert_eq("three notes stored", #data[fpath], 3)

  -- Check each note
  local texts = {}
  for _, n in ipairs(data[fpath]) do texts[n.text] = n.line end
  assert_eq("first note on line 1", texts["First note"], 1)
  assert_eq("second note on line 3", texts["Second note"], 3)
  assert_eq("third note on line 4", texts["Third note"], 4)

  -- Verify all extmarks
  local marks = api.nvim_buf_get_extmarks(bufnr, api.nvim_create_namespace("audit_notes"), 0, -1, {})
  assert_eq("three extmarks placed", #marks, 3)

  vim.cmd("bwipeout!")
end

-- Test 4: Newline substitution in note text
print("\n[Newline Substitution]")
do
  local audit = fresh_setup()
  open_test_file()

  api.nvim_win_set_cursor(0, { 1, 0 })
  audit.add("line one\\nline two\\nline three")

  local data = read_json(storage_file)
  local fpath = fn.fnamemodify(test_file, ":p")
  local note = data[fpath][1]
  assert_eq("newlines substituted", note.text, "line one\nline two\nline three")

  vim.cmd("bwipeout!")
end

-- Test 5: Toggle visibility
print("\n[Toggle Visibility]")
do
  local audit = fresh_setup()
  local bufnr = open_test_file()

  api.nvim_win_set_cursor(0, { 1, 0 })
  audit.add("visible note")

  local ns_id = api.nvim_create_namespace("audit_notes")
  local marks_before = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
  assert_true("extmarks present before toggle", #marks_before >= 1)

  -- Toggle off
  audit.toggle()
  local marks_after = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
  assert_eq("extmarks cleared after toggle off", #marks_after, 0)

  -- Toggle back on
  audit.toggle()
  local marks_restored = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
  assert_true("extmarks restored after toggle on", #marks_restored >= 1)

  vim.cmd("bwipeout!")
end

-- Test 6: No note near cursor warnings
print("\n[No Note Warnings]")
do
  local audit = fresh_setup()
  open_test_file()

  -- No notes added - calling show/edit should not crash
  local ok1, err1 = pcall(audit.show)
  assert_true("show with no notes does not crash", ok1, tostring(err1))

  local ok2, err2 = pcall(audit.edit)
  assert_true("edit with no notes does not crash", ok2, tostring(err2))

  vim.cmd("bwipeout!")
end

-- Test 7: Export to markdown
print("\n[Export]")
do
  local audit = fresh_setup()
  open_test_file()

  api.nvim_win_set_cursor(0, { 1, 0 })
  audit.add("Export note one")
  api.nvim_win_set_cursor(0, { 3, 0 })
  audit.add("Export note two")

  audit.export()

  -- Find the export file
  local fpath = fn.fnamemodify(test_file, ":~:.")
  -- The export goes to git_root/.audit/ or cwd/.audit/
  -- Since we're not in a git repo context for the test file, it uses cwd
  local cwd = fn.getcwd()
  local export_path = cwd .. "/.audit/" .. fpath .. ".md"

  local ef = io.open(export_path, "r")
  if ef then
    local content = ef:read("*a"); ef:close()
    assert_match("export has header", content, "# Audit notes:")
    assert_match("export has note one", content, "Export note one")
    assert_match("export has note two", content, "Export note two")
    assert_match("export has author", content, "tester")
    assert_match("export has line numbers", content, "Line %d+")
    -- Clean up
    os.remove(export_path)
  else
    -- The export might use git root detection; check alternate paths
    -- In headless mode, git_root() may or may not work
    report("export file created", false, "could not find export file at " .. export_path)
  end

  vim.cmd("bwipeout!")
end

-- Test 8: Storage persistence (save and reload)
print("\n[Storage Persistence]")
do
  local audit = fresh_setup()
  open_test_file()

  api.nvim_win_set_cursor(0, { 2, 0 })
  audit.add("Persistent note")
  vim.cmd("bwipeout!")

  -- Reload module and verify notes persist
  package.loaded["audit_notes"] = nil
  local audit2 = require("audit_notes")
  audit2.setup({
    storage_path = storage_file,
    author = "tester",
    autosave = true,
    icon = ">>",
    max_line_len = 80,
  })

  local data = read_json(storage_file)
  local fpath = fn.fnamemodify(test_file, ":p")
  assert_true("notes persist after reload", data[fpath] ~= nil and #data[fpath] > 0)
  assert_eq("persisted note text correct", data[fpath][1].text, "Persistent note")
end

-- Test 9: Config defaults
print("\n[Config Defaults]")
do
  package.loaded["audit_notes"] = nil
  local audit = require("audit_notes")
  -- Before setup, check defaults
  assert_eq("default storage_path is nil", audit.config.storage_path, nil)
  assert_eq("default author is nil", audit.config.author, nil)
  assert_eq("default autosave is true", audit.config.autosave, true)
  assert_eq("default icon", audit.config.icon, "📝")
  assert_eq("default max_line_len", audit.config.max_line_len, 120)
end

-- Test 10: Highlight groups created
print("\n[Highlight Groups]")
do
  local audit = fresh_setup()
  -- Check if highlight groups exist
  local hl_header = api.nvim_get_hl(0, { name = "AuditHeader" })
  local hl_dim = api.nvim_get_hl(0, { name = "AuditDim" })
  assert_true("AuditHeader highlight exists", hl_header ~= nil)
  assert_true("AuditDim highlight exists", hl_dim ~= nil)
end

-- Test 11: Namespace created
print("\n[Namespace]")
do
  local ns_id = api.nvim_create_namespace("audit_notes")
  assert_true("namespace id is positive", ns_id > 0)
end

-- Test 12: Add note to buffer with no file name
print("\n[No-File Buffer]")
do
  local audit = fresh_setup()
  vim.cmd("enew")
  -- Should not crash, just warn
  local ok, err = pcall(audit.add, "note on no-file buffer")
  assert_true("add to no-file buffer does not crash", ok, tostring(err))
  vim.cmd("bwipeout!")
end

-- Test 13: Notes attach to correct line after decorating
print("\n[Extmark Positioning]")
do
  local audit = fresh_setup()
  local bufnr = open_test_file()
  local ns_id = api.nvim_create_namespace("audit_notes")

  api.nvim_win_set_cursor(0, { 1, 0 })
  audit.add("Note on line 1")

  api.nvim_win_set_cursor(0, { 3, 0 })
  audit.add("Note on line 3")

  local marks = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
  -- Marks should be sorted by position
  table.sort(marks, function(a, b) return a[2] < b[2] end)

  assert_eq("first extmark on row 0 (line 1)", marks[1][2], 0)
  assert_eq("second extmark on row 2 (line 3)", marks[2][2], 2)

  vim.cmd("bwipeout!")
end

-- Test 14: UUID uniqueness
print("\n[UUID Generation]")
do
  -- Access the uuid function indirectly by adding multiple notes and checking IDs
  local audit = fresh_setup()
  open_test_file()

  api.nvim_win_set_cursor(0, { 1, 0 })
  audit.add("Note A")
  api.nvim_win_set_cursor(0, { 2, 0 })
  audit.add("Note B")

  local data = read_json(storage_file)
  local fpath = fn.fnamemodify(test_file, ":p")
  local id1 = data[fpath][1].id
  local id2 = data[fpath][2].id

  assert_true("UUIDs are strings", type(id1) == "string" and type(id2) == "string")
  assert_true("UUIDs are non-empty", #id1 > 0 and #id2 > 0)
  assert_true("UUIDs are unique", id1 ~= id2)
  assert_match("UUID format", id1, "%x+%-%x+%-4%x+%-%x+%-%x+")

  vim.cmd("bwipeout!")
end

-- Test 15: List command in scratch buffer
print("\n[List Command]")
do
  local audit = fresh_setup()
  local bufnr = open_test_file()

  api.nvim_win_set_cursor(0, { 1, 0 })
  audit.add("Listed note one")
  api.nvim_win_set_cursor(0, { 2, 0 })
  audit.add("Listed note two")

  -- Focus back on test buffer
  api.nvim_set_current_buf(bufnr)

  -- Call list - it opens a new split
  audit.list()

  -- The new buffer should be the current one
  local list_buf = api.nvim_get_current_buf()
  assert_true("list opens new buffer", list_buf ~= bufnr)

  local lines = api.nvim_buf_get_lines(list_buf, 0, -1, false)
  assert_true("list buffer has content", #lines > 0)
  assert_match("list header present", lines[1], "Audit notes")

  -- Check content
  local all_text = table.concat(lines, "\n")
  assert_match("list contains note one", all_text, "Listed note one")
  assert_match("list contains note two", all_text, "Listed note two")

  -- Check buffer settings
  assert_eq("list buf is nofile", vim.bo[list_buf].buftype, "nofile")
  assert_eq("list buf filetype", vim.bo[list_buf].filetype, "audit_list")

  vim.cmd("bwipeout!")
  -- also close the original buffer
  if api.nvim_buf_is_valid(bufnr) then
    api.nvim_set_current_buf(bufnr)
    vim.cmd("bwipeout!")
  end
end

-- Test 16: Plugin loader guard
print("\n[Plugin Loader Guard]")
do
  -- The plugin/audit_notes.lua sets vim.g.loaded_audit_notes
  -- Simulate it
  vim.g.loaded_audit_notes = nil
  dofile("/home/user/vimscull/plugin/audit_notes.lua")
  assert_eq("loaded guard set", vim.g.loaded_audit_notes, 1)

  -- Verify user commands exist
  local cmds = api.nvim_get_commands({})
  assert_true("AuditAdd command exists", cmds["AuditAdd"] ~= nil)
  assert_true("AuditAddHere command exists", cmds["AuditAddHere"] ~= nil)
  assert_true("AuditEdit command exists", cmds["AuditEdit"] ~= nil)
  assert_true("AuditDelete command exists", cmds["AuditDelete"] ~= nil)
  assert_true("AuditList command exists", cmds["AuditList"] ~= nil)
  assert_true("AuditToggle command exists", cmds["AuditToggle"] ~= nil)
  assert_true("AuditShow command exists", cmds["AuditShow"] ~= nil)
  assert_true("AuditExport command exists", cmds["AuditExport"] ~= nil)
end

-- Test 17: AuditAddHere command with inline text
print("\n[AuditAddHere Command]")
do
  local audit = fresh_setup()
  open_test_file()

  api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("AuditAddHere quick inline note")

  local data = read_json(storage_file)
  local fpath = fn.fnamemodify(test_file, ":p")
  -- Find the note with the inline text
  local found = false
  if data[fpath] then
    for _, n in ipairs(data[fpath]) do
      if n.text == "quick inline note" then
        found = true
        break
      end
    end
  end
  assert_true("AuditAddHere stores note", found)

  vim.cmd("bwipeout!")
end

-----------------------------------------------------------------------
-- Summary
print("\n=== Results ===")
print(string.format("  Passed: %d", passed))
print(string.format("  Failed: %d", failed))
print(string.format("  Total:  %d", passed + failed))

if #errors > 0 then
  print("\nFailed tests:")
  for _, e in ipairs(errors) do
    print(string.format("  - %s: %s", e.name, e.msg))
  end
end

-- Clean up temp dir
fn.delete(test_dir, "rf")

-- Exit with proper code
if failed > 0 then
  print("\nTEST SUITE FAILED")
  os.exit(1)
else
  print("\nALL TESTS PASSED")
  os.exit(0)
end
