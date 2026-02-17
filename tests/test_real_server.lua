#!/usr/bin/env nvim -l
-- Minimal test against numscull_native: Connect, ListProjects, CreateProject, ChangeProject, AddNote.
-- Run with server: ../mockscull/numscull_native -r mockscull/sample-config -p 5111
-- Then: nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/test_real_server.lua

local fn = vim.fn
local api = vim.api
local root = fn.getcwd()
local config_dir = root .. "/mockscull/sample-config"
local identity = "python-client"
local port = 5111

local numscull = require("numscull")
numscull.setup({ config_dir = config_dir, identity = identity, auto_fetch = false })

print("1. Connecting to 127.0.0.1:" .. port .. " ...")
local ok, err = numscull.connect("127.0.0.1", port)
if not ok then
  print("   FAIL: " .. tostring(err))
  os.exit(1)
end
print("   OK")

print("2. List projects ...")
local list, list_err = numscull.list_projects()
if list_err then
  print("   FAIL: " .. tostring(list_err))
  numscull.disconnect()
  os.exit(1)
end
local projects = list.projects or {}
print("   OK: " .. #projects .. " project(s)")

local proj_name = "test-proj"
if #projects == 0 then
  print("3. Create project '" .. proj_name .. "' ...")
  local _, create_err = numscull.create_project(proj_name, "/tmp/test", identity)
  if create_err then
    print("   FAIL: " .. tostring(create_err))
    numscull.disconnect()
    os.exit(1)
  end
  print("   OK")
else
  proj_name = projects[1].name or proj_name
  print("3. Using existing project '" .. proj_name .. "'")
end

print("4. Change to project '" .. proj_name .. "' ...")
local chg_ok, chg_err = numscull.change_project(proj_name)
if not chg_ok then
  print("   FAIL: " .. tostring(chg_err))
  numscull.disconnect()
  os.exit(1)
end
print("   OK")

print("5. Add note ...")
local path = config_dir .. "/test_note.lua"
local f = io.open(path, "w")
f:write("line1\nline2\nline3\n")
f:close()
vim.cmd("edit " .. path)
api.nvim_win_set_cursor(0, { 2, 0 })

local uri = "file://" .. path
local note, note_err = numscull.set({
  location = { fileId = { uri = uri }, line = 2 },
  text = "hello world",
  createdDate = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  modifiedDate = os.date("!%Y-%m-%dT%H:%M:%SZ"),
})

if not note then
  print("   FAIL: " .. tostring(note_err))
  numscull.disconnect()
  os.exit(1)
end
print("   OK: " .. note.text)

numscull.disconnect()
print("\nAll steps passed.")
