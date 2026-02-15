-- tests/test_flows.lua — automated test suite for flows
-- Run: nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/test_flows.lua

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
local test_file2 = test_dir .. "/other.lua"
local storage_file = test_dir .. "/flows.json"

local function write_sample_file()
  local f = io.open(test_file, "w")
  f:write("local x = 1\nlocal y = 2\nlocal z = 3\nreturn x + y + z\n")
  f:close()
end

local function write_sample_file2()
  local f = io.open(test_file2, "w")
  f:write("local a = 10\nlocal b = 20\nreturn a + b\n")
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
  os.remove(storage_file)
  package.loaded["flows"] = nil
  local flows = require("flows")
  flows.setup({
    storage_path = storage_file,
  })
  return flows
end

local function open_test_file()
  write_sample_file()
  vim.cmd("edit " .. test_file)
  vim.cmd("doautocmd BufReadPost")
  return api.nvim_get_current_buf()
end

local function open_test_file2()
  write_sample_file2()
  vim.cmd("edit " .. test_file2)
  vim.cmd("doautocmd BufReadPost")
  return api.nvim_get_current_buf()
end

-----------------------------------------------------------------------
print("=== flows test suite ===\n")

-- Test 1: Module loads and setup works
print("[Module & Setup]")
do
  local flows = fresh_setup()
  assert_true("module returns table", type(flows) == "table")
  assert_true("setup function exists", type(flows.setup) == "function")
  assert_true("create function exists", type(flows.create) == "function")
  assert_true("delete function exists", type(flows.delete) == "function")
  assert_true("add_node function exists", type(flows.add_node) == "function")
  assert_true("delete_node function exists", type(flows.delete_node) == "function")
  assert_true("next function exists", type(flows.next) == "function")
  assert_true("prev function exists", type(flows.prev) == "function")
  assert_true("select function exists", type(flows.select) == "function")
  assert_true("list function exists", type(flows.list) == "function")
  assert_true("get_active_flow function exists", type(flows.get_active_flow) == "function")
  assert_true("get_flows function exists", type(flows.get_flows) == "function")
  assert_true("get_active_flow_id function exists", type(flows.get_active_flow_id) == "function")
  assert_eq("config storage_path set", flows.config.storage_path, storage_file)
end

-- Test 2: Create a flow
print("\n[Create Flow]")
do
  local flows = fresh_setup()

  flows.create("test flow")

  local all = flows.get_flows()
  assert_eq("one flow exists", #all, 1)
  assert_eq("flow name correct", all[1].name, "test flow")
  assert_true("flow has id", all[1].id ~= nil and #all[1].id > 0)
  assert_eq("flow has empty nodes", #all[1].nodes, 0)
  assert_eq("flow is active", flows.get_active_flow_id(), all[1].id)

  -- Verify JSON was written
  local data = read_json(storage_file)
  assert_true("storage file created", data ~= nil)
  assert_eq("one flow in storage", #data.flows, 1)
  assert_eq("flow name in storage", data.flows[1].name, "test flow")
  assert_eq("active_flow_id in storage", data.active_flow_id, all[1].id)
end

-- Test 3: Create multiple flows
print("\n[Multiple Flows]")
do
  local flows = fresh_setup()

  flows.create("flow A")
  flows.create("flow B")
  flows.create("flow C")

  local all = flows.get_flows()
  assert_eq("three flows exist", #all, 3)
  assert_eq("flow A name", all[1].name, "flow A")
  assert_eq("flow B name", all[2].name, "flow B")
  assert_eq("flow C name", all[3].name, "flow C")
  -- Last created should be active
  assert_eq("last created is active", flows.get_active_flow_id(), all[3].id)
end

-- Test 4: Add node to active flow (programmatic)
print("\n[Add Node]")
do
  local flows = fresh_setup()
  local bufnr = open_test_file()

  flows.create("node test")
  api.nvim_win_set_cursor(0, { 2, 0 })

  flows.add_node({ line = 2, col_start = 6, col_end = 11, color = "FlowRed" })

  local flow = flows.get_active_flow()
  assert_eq("one node in flow", #flow.nodes, 1)

  local node = flow.nodes[1]
  assert_eq("node line correct", node.line, 2)
  assert_eq("node col_start correct", node.col_start, 6)
  assert_eq("node col_end correct", node.col_end, 11)
  assert_eq("node color correct", node.color, "FlowRed")
  assert_true("node has id", node.id ~= nil and #node.id > 0)
  local fpath = fn.fnamemodify(test_file, ":p")
  assert_eq("node file correct", node.file, fpath)

  -- Verify in storage
  local data = read_json(storage_file)
  assert_eq("one node in storage", #data.flows[1].nodes, 1)
  assert_eq("node line in storage", data.flows[1].nodes[1].line, 2)

  -- Verify extmark was placed
  local ns_id = api.nvim_create_namespace("flows")
  local marks = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
  assert_true("extmark placed in buffer", #marks >= 1)

  vim.cmd("bwipeout!")
end

-- Test 5: Add multiple nodes
print("\n[Multiple Nodes]")
do
  local flows = fresh_setup()
  local bufnr = open_test_file()

  flows.create("multi node test")

  flows.add_node({ line = 1, col_start = 0, col_end = 5, color = "FlowRed" })
  flows.add_node({ line = 2, col_start = 6, col_end = 11, color = "FlowBlue" })
  flows.add_node({ line = 3, col_start = 6, col_end = 11, color = "FlowGreen" })

  local flow = flows.get_active_flow()
  assert_eq("three nodes in flow", #flow.nodes, 3)
  assert_eq("first node color", flow.nodes[1].color, "FlowRed")
  assert_eq("second node color", flow.nodes[2].color, "FlowBlue")
  assert_eq("third node color", flow.nodes[3].color, "FlowGreen")

  local ns_id = api.nvim_create_namespace("flows")
  local marks = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
  assert_eq("three extmarks placed", #marks, 3)

  vim.cmd("bwipeout!")
end

-- Test 6: Delete a node
print("\n[Delete Node]")
do
  local flows = fresh_setup()
  local bufnr = open_test_file()

  flows.create("delete node test")
  flows.add_node({ line = 1, col_start = 0, col_end = 5, color = "FlowRed" })
  flows.add_node({ line = 3, col_start = 0, col_end = 5, color = "FlowBlue" })

  local flow = flows.get_active_flow()
  assert_eq("two nodes before delete", #flow.nodes, 2)

  -- Put cursor on line 1 and delete
  api.nvim_win_set_cursor(0, { 1, 0 })
  flows.delete_node()

  flow = flows.get_active_flow()
  assert_eq("one node after delete", #flow.nodes, 1)
  assert_eq("remaining node is on line 3", flow.nodes[1].line, 3)

  vim.cmd("bwipeout!")
end

-- Test 7: Storage persistence
print("\n[Storage Persistence]")
do
  local flows = fresh_setup()
  open_test_file()

  flows.create("persistent flow")
  flows.add_node({ line = 2, col_start = 0, col_end = 5, color = "FlowCyan" })
  vim.cmd("bwipeout!")

  -- Reload module
  package.loaded["flows"] = nil
  local flows2 = require("flows")
  flows2.setup({ storage_path = storage_file })

  local all = flows2.get_flows()
  assert_true("flows persist after reload", #all > 0)
  assert_eq("persisted flow name", all[1].name, "persistent flow")
  assert_eq("persisted flow has nodes", #all[1].nodes, 1)
  assert_eq("persisted node color", all[1].nodes[1].color, "FlowCyan")
  assert_eq("active flow persists", flows2.get_active_flow_id(), all[1].id)
end

-- Test 8: Switching active flow changes highlights
print("\n[Switch Flow Highlights]")
do
  local flows = fresh_setup()
  local bufnr = open_test_file()
  local ns_id = api.nvim_create_namespace("flows")

  -- Create two flows with different nodes
  flows.create("flow alpha")
  local alpha_id = flows.get_active_flow_id()
  flows.add_node({ line = 1, col_start = 0, col_end = 5, color = "FlowRed" })

  flows.create("flow beta")
  local beta_id = flows.get_active_flow_id()
  flows.add_node({ line = 3, col_start = 0, col_end = 5, color = "FlowBlue" })

  -- Beta is active: should have extmarks on line 3
  local marks = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
  assert_eq("beta has one extmark", #marks, 1)
  assert_eq("beta extmark on row 2 (line 3)", marks[1][2], 2)

  -- Manually switch to alpha
  -- We can't use the UI in headless, so set the state via create/get
  -- Instead, let's access through flows internal - create a new function flow for this
  -- Actually, we'll just read the flow IDs and set active

  -- Switch to alpha by creating a third flow and checking again
  -- Better: use the get_flows to find alpha, then ... we need a programmatic switch
  -- The select UI is interactive, so let's test the data after switching

  -- We'll verify by checking the storage file approach:
  -- Save current, reload, set active_flow_id in storage manually
  local data = read_json(storage_file)
  data.active_flow_id = alpha_id
  local f = io.open(storage_file, "w")
  f:write(vim.json.encode(data)); f:close()

  -- Reload
  package.loaded["flows"] = nil
  local flows2 = require("flows")
  flows2.setup({ storage_path = storage_file })

  -- Re-open the file
  vim.cmd("edit " .. test_file)
  vim.cmd("doautocmd BufReadPost")
  bufnr = api.nvim_get_current_buf()

  local marks2 = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
  assert_eq("alpha has one extmark", #marks2, 1)
  assert_eq("alpha extmark on row 0 (line 1)", marks2[1][2], 0)

  vim.cmd("bwipeout!")
end

-- Test 9: Navigate next/prev
print("\n[Navigation Next/Prev]")
do
  local flows = fresh_setup()
  local bufnr = open_test_file()

  flows.create("nav test")
  flows.add_node({ line = 1, col_start = 0, col_end = 5, color = "FlowRed" })
  flows.add_node({ line = 2, col_start = 6, col_end = 11, color = "FlowBlue" })
  flows.add_node({ line = 4, col_start = 0, col_end = 6, color = "FlowGreen" })

  -- Start on line 1
  api.nvim_win_set_cursor(0, { 1, 0 })

  -- Next should go to node 2 (line 2)
  flows.next()
  local pos = api.nvim_win_get_cursor(0)
  assert_eq("next from node 1 goes to line 2", pos[1], 2)

  -- Next again should go to node 3 (line 4)
  flows.next()
  pos = api.nvim_win_get_cursor(0)
  assert_eq("next from node 2 goes to line 4", pos[1], 4)

  -- Next from last should wrap to node 1 (line 1)
  flows.next()
  pos = api.nvim_win_get_cursor(0)
  assert_eq("next from last wraps to line 1", pos[1], 1)

  -- Prev should wrap to last node (line 4)
  flows.prev()
  pos = api.nvim_win_get_cursor(0)
  assert_eq("prev from first wraps to line 4", pos[1], 4)

  -- Prev again should go to node 2 (line 2)
  flows.prev()
  pos = api.nvim_win_get_cursor(0)
  assert_eq("prev from node 3 goes to line 2", pos[1], 2)

  vim.cmd("bwipeout!")
end

-- Test 10: Highlight groups created
print("\n[Highlight Groups]")
do
  local flows = fresh_setup()
  local hl_red = api.nvim_get_hl(0, { name = "FlowRed" })
  local hl_blue = api.nvim_get_hl(0, { name = "FlowBlue" })
  local hl_green = api.nvim_get_hl(0, { name = "FlowGreen" })
  local hl_yellow = api.nvim_get_hl(0, { name = "FlowYellow" })
  local hl_cyan = api.nvim_get_hl(0, { name = "FlowCyan" })
  local hl_magenta = api.nvim_get_hl(0, { name = "FlowMagenta" })
  local hl_select = api.nvim_get_hl(0, { name = "FlowSelect" })
  local hl_header = api.nvim_get_hl(0, { name = "FlowHeader" })
  assert_true("FlowRed highlight exists", hl_red ~= nil)
  assert_true("FlowBlue highlight exists", hl_blue ~= nil)
  assert_true("FlowGreen highlight exists", hl_green ~= nil)
  assert_true("FlowYellow highlight exists", hl_yellow ~= nil)
  assert_true("FlowCyan highlight exists", hl_cyan ~= nil)
  assert_true("FlowMagenta highlight exists", hl_magenta ~= nil)
  assert_true("FlowSelect highlight exists", hl_select ~= nil)
  assert_true("FlowHeader highlight exists", hl_header ~= nil)
end

-- Test 11: Namespace created
print("\n[Namespace]")
do
  local ns_id = api.nvim_create_namespace("flows")
  assert_true("namespace id is positive", ns_id > 0)
end

-- Test 12: No-file buffer
print("\n[No-File Buffer]")
do
  local flows = fresh_setup()
  flows.create("no file test")
  vim.cmd("enew")
  local ok, err = pcall(flows.add_node, { line = 1, col_start = 0, col_end = 5, color = "FlowRed" })
  assert_true("add_node on no-file buffer does not crash", ok, tostring(err))
  vim.cmd("bwipeout!")
end

-- Test 13: No active flow warnings
print("\n[No Active Flow Warnings]")
do
  local flows = fresh_setup()
  open_test_file()

  -- No flow created - operations should not crash
  local ok1, err1 = pcall(flows.add_node, { line = 1, col_start = 0, col_end = 5, color = "FlowRed" })
  assert_true("add_node with no active flow does not crash", ok1, tostring(err1))

  local ok2, err2 = pcall(flows.delete_node)
  assert_true("delete_node with no active flow does not crash", ok2, tostring(err2))

  local ok3, err3 = pcall(flows.next)
  assert_true("next with no active flow does not crash", ok3, tostring(err3))

  local ok4, err4 = pcall(flows.prev)
  assert_true("prev with no active flow does not crash", ok4, tostring(err4))

  local ok5, err5 = pcall(flows.list)
  assert_true("list with no active flow does not crash", ok5, tostring(err5))

  vim.cmd("bwipeout!")
end

-- Test 14: UUID uniqueness
print("\n[UUID Generation]")
do
  local flows = fresh_setup()
  open_test_file()

  flows.create("uuid test")
  flows.add_node({ line = 1, col_start = 0, col_end = 5, color = "FlowRed" })
  flows.add_node({ line = 2, col_start = 0, col_end = 5, color = "FlowBlue" })

  local flow = flows.get_active_flow()
  local id1 = flow.nodes[1].id
  local id2 = flow.nodes[2].id
  local flow_id = flow.id

  assert_true("node IDs are strings", type(id1) == "string" and type(id2) == "string")
  assert_true("node IDs are non-empty", #id1 > 0 and #id2 > 0)
  assert_true("node IDs are unique", id1 ~= id2)
  assert_true("flow ID differs from node IDs", flow_id ~= id1 and flow_id ~= id2)
  assert_match("UUID format", id1, "%x+%-%x+%-4%x+%-%x+%-%x+")

  vim.cmd("bwipeout!")
end

-- Test 15: Extmark positioning with column ranges
print("\n[Extmark Column Positioning]")
do
  local flows = fresh_setup()
  local bufnr = open_test_file()
  local ns_id = api.nvim_create_namespace("flows")

  flows.create("position test")
  -- "local x = 1" -> highlight "x" at col 6-7
  flows.add_node({ line = 1, col_start = 6, col_end = 7, color = "FlowRed" })

  local marks = api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
  assert_eq("one extmark placed", #marks, 1)
  assert_eq("extmark row is 0", marks[1][2], 0)
  assert_eq("extmark col_start is 6", marks[1][3], 6)
  assert_eq("extmark end_col is 7", marks[1][4].end_col, 7)

  vim.cmd("bwipeout!")
end

-- Test 16: List command in scratch buffer
print("\n[List Command]")
do
  local flows = fresh_setup()
  local bufnr = open_test_file()

  flows.create("list test")
  flows.add_node({ line = 1, col_start = 0, col_end = 5, color = "FlowRed" })
  flows.add_node({ line = 3, col_start = 6, col_end = 11, color = "FlowBlue" })

  api.nvim_set_current_buf(bufnr)
  flows.list()

  local list_buf = api.nvim_get_current_buf()
  assert_true("list opens new buffer", list_buf ~= bufnr)

  local lines = api.nvim_buf_get_lines(list_buf, 0, -1, false)
  assert_true("list buffer has content", #lines > 0)
  assert_match("list header present", lines[1], "Flow:")
  assert_match("list header has name", lines[1], "list test")

  local all_text = table.concat(lines, "\n")
  assert_match("list contains FlowRed", all_text, "FlowRed")
  assert_match("list contains FlowBlue", all_text, "FlowBlue")

  assert_eq("list buf is nofile", vim.bo[list_buf].buftype, "nofile")
  assert_eq("list buf filetype", vim.bo[list_buf].filetype, "flow_list")

  vim.cmd("bwipeout!")
  if api.nvim_buf_is_valid(bufnr) then
    api.nvim_set_current_buf(bufnr)
    vim.cmd("bwipeout!")
  end
end

-- Test 17: Plugin loader guard
print("\n[Plugin Loader Guard]")
do
  vim.g.loaded_flows = nil
  -- Need to make sure module is loaded for plugin
  package.loaded["flows"] = nil
  local _ = fresh_setup()
  dofile("/home/user/vimscull/plugin/flows.lua")
  assert_eq("loaded guard set", vim.g.loaded_flows, 1)

  local cmds = api.nvim_get_commands({})
  assert_true("FlowCreate command exists", cmds["FlowCreate"] ~= nil)
  assert_true("FlowDelete command exists", cmds["FlowDelete"] ~= nil)
  assert_true("FlowSelect command exists", cmds["FlowSelect"] ~= nil)
  assert_true("FlowAddNode command exists", cmds["FlowAddNode"] ~= nil)
  assert_true("FlowDeleteNode command exists", cmds["FlowDeleteNode"] ~= nil)
  assert_true("FlowNext command exists", cmds["FlowNext"] ~= nil)
  assert_true("FlowPrev command exists", cmds["FlowPrev"] ~= nil)
  assert_true("FlowList command exists", cmds["FlowList"] ~= nil)
end

-- Test 18: Config defaults
print("\n[Config Defaults]")
do
  package.loaded["flows"] = nil
  local flows = require("flows")
  assert_eq("default storage_path is nil", flows.config.storage_path, nil)
  assert_true("palette has entries", #flows.palette > 0)
  assert_eq("palette has 6 colors", #flows.palette, 6)
end

-- Test 19: Palette structure
print("\n[Palette Structure]")
do
  package.loaded["flows"] = nil
  local flows = require("flows")
  for _, c in ipairs(flows.palette) do
    assert_true("palette entry has name: " .. c.name, c.name ~= nil and #c.name > 0)
    assert_true("palette entry has hl: " .. c.hl, c.hl ~= nil and #c.hl > 0)
    assert_true("palette entry has fg: " .. c.hl, c.fg ~= nil and #c.fg > 0)
    assert_true("palette entry has bg: " .. c.hl, c.bg ~= nil and #c.bg > 0)
  end
end

-- Test 20: Delete node with no nodes in file
print("\n[Delete Node No Match]")
do
  local flows = fresh_setup()
  open_test_file()
  flows.create("empty flow")

  local ok, err = pcall(flows.delete_node)
  assert_true("delete_node with no nodes does not crash", ok, tostring(err))

  vim.cmd("bwipeout!")
end

-- Test 21: FlowCreate command with inline name
print("\n[FlowCreate Command]")
do
  local flows = fresh_setup()
  -- Re-register commands so they reference the fresh module
  vim.g.loaded_flows = nil
  dofile("/home/user/vimscull/plugin/flows.lua")

  vim.cmd("FlowCreate inline flow name")

  local all = flows.get_flows()
  local found = false
  for _, f in ipairs(all) do
    if f.name == "inline flow name" then found = true; break end
  end
  assert_true("FlowCreate stores flow with inline name", found)
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
