-- numscull/init.lua — main entry: setup, config, autocommands, public API

local M = {}
local api = vim.api
local control = require("numscull.control")
local notes = require("numscull.notes")
local flow = require("numscull.flow")
local client = require("numscull.client")

-- Demo logging helper (enabled via NUMSCULL_DEMO env var).
-- Writes to both the terminal (captured in asciinema .cast) and a log file
-- so validation can use whichever source is more convenient.
local _demo_log_path = nil
local function demo_log(func_name, status)
  if os.getenv("NUMSCULL_DEMO") ~= "1" then return end

  local msg = string.format("[NUMSCULL_DEMO] %s: %s", func_name, status)

  -- Terminal echo (appears in .cast output even though redraw clears it)
  api.nvim_echo({{msg, "Comment"}}, false, {})
  vim.cmd("redraw")

  -- Append to log file (more reliable for automated validation)
  if not _demo_log_path then
    local cfg = os.getenv("NUMSCULL_CONFIG_DIR")
    if cfg then _demo_log_path = cfg .. "/demo.log" end
  end
  if _demo_log_path then
    local f = io.open(_demo_log_path, "a")
    if f then
      f:write(msg .. "\n")
      f:close()
    end
  end
end

M.config = {
  host = "127.0.0.1",
  port = 5000,
  identity = nil,
  config_dir = nil,
  project = nil,
  icon = "📝",
  max_line_len = 120,
  auto_connect = false,
  auto_fetch = true,
  quick_connect_auto = false, -- Auto-connect from .numscull/config on startup
  editor = "float",           -- "float" (two-pane) or "inline" (single-pane with virt_lines)
  context_lines = 10,
  float_border = "rounded",
  float_width = 0.8,
  float_height = 0.7,
  split_direction = "vertical",
  palette = nil,              -- Custom palette for flow colors (falls back to default)
  note_template = "",         -- Template for new notes (empty by default)
  mappings = {
    note_add = "<leader>na",
    note_edit = "<leader>ne",
    flow_add_node_here = nil, -- Optional mapping for FlowAddNodeHere
    flow_select = nil,        -- Optional mapping for FlowSelect
  },
}

local augroup = nil

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  notes.setup({
    icon = M.config.icon,
    max_line_len = M.config.max_line_len,
    editor = M.config.editor,
    context_lines = M.config.context_lines,
    float_border = M.config.float_border,
    float_width = M.config.float_width,
    float_height = M.config.float_height,
    split_direction = M.config.split_direction,
    note_template = M.config.note_template,
    mappings = M.config.mappings,
  })
  flow.setup({
    palette = M.config.palette,
  })

  augroup = api.nvim_create_augroup("Numscull", { clear = true })
  if M.config.auto_fetch then
    api.nvim_create_autocmd("BufReadPost", {
      group = augroup,
      callback = function(ev)
        notes.fetch_and_decorate(ev.buf)
      end,
    })
  end

  if M.config.auto_connect and M.config.identity and M.config.config_dir then
    M.connect()
  end
  
  -- Auto-connect from .numscull/config if enabled
  if M.config.quick_connect_auto then
    M.quick_connect(false)  -- false = don't save
  end
end

--- Connect and initialize (control/init + key exchange).
function M.connect(host, port)
  demo_log("NumscullConnect", "START")
  host = host or M.config.host
  port = port or M.config.port
  local identity = M.config.identity or os.getenv("USER") or "unknown"
  local config_dir = M.config.config_dir
  if not config_dir then
    demo_log("NumscullConnect", "FAILED: config_dir required")
    return nil, "config_dir required for init (path to identities/)"
  end
  local pcall_ok, result, err = pcall(control.init, host, port, identity, nil, config_dir)
  if not pcall_ok then
    demo_log("NumscullConnect", "FAILED: " .. tostring(result))
    return nil, tostring(result)
  end
  if not result then
    demo_log("NumscullConnect", "FAILED: " .. tostring(err))
    return nil, err
  end
  if M.config.project then
    control.change_project(M.config.project)
  end
  demo_log("NumscullConnect", "END")
  return true
end

--- Disconnect.
function M.disconnect()
  demo_log("NumscullDisconnect", "START")
  control.disconnect()
  demo_log("NumscullDisconnect", "END")
end

--- Exit (control/exit + close).
function M.exit()
  demo_log("NumscullExit", "START")
  control.exit()
  demo_log("NumscullExit", "END")
end

--- Change project.
function M.change_project(name)
  demo_log("NumscullProject", "START")
  local result, err = control.change_project(name)
  demo_log("NumscullProject", result and "END" or ("FAILED: " .. tostring(err)))
  return result, err
end

--- List projects.
function M.list_projects()
  return control.list_projects()
end

--- Create project.
function M.create_project(name, repository, owner_identity)
  return control.create_project(name, repository, owner_identity or M.config.identity or "unknown")
end

--- Load configuration from .numscull/config file.
--- Returns config table or nil, err.
local function load_config_file(config_path)
  local f = io.open(config_path, "r")
  if not f then
    return nil, "config file not found"
  end
  local content = f:read("*a")
  f:close()
  
  local config = {}
  for line in content:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.+)$")
    if key and value then
      key = key:gsub("^%s*(.-)%s*$", "%1")
      value = value:gsub("^%s*(.-)%s*$", "%1")
      config[key] = value
    end
  end
  return config
end

--- Save configuration to .numscull/config file.
--- Returns true or nil, err.
local function save_config_file(config_path, config)
  -- Ensure directory exists
  local dir = config_path:match("^(.*)/[^/]+$")
  if dir then
    vim.fn.mkdir(dir, "p")
  end
  
  local f = io.open(config_path, "w")
  if not f then
    return nil, "could not write config file"
  end
  
  for key, value in pairs(config) do
    f:write(string.format("%s=%s\n", key, value))
  end
  f:close()
  return true
end

--- Quick connect: read from .numscull/config and connect.
--- Optionally saves settings back if save_config is true.
function M.quick_connect(save_config)
  local config_path = vim.fn.getcwd() .. "/.numscull/config"
  local cfg, err = load_config_file(config_path)
  
  if not cfg then
    return nil, err
  end
  
  local host = cfg.host or M.config.host
  local port = tonumber(cfg.port) or M.config.port
  local project_name = cfg.project
  
  local ok, err2 = M.connect(host, port)
  if not ok then
    return nil, err2
  end
  
  if project_name then
    local result, err3 = control.change_project(project_name)
    if not result then
      return nil, err3
    end
    M.config.project = project_name
  end
  
  if save_config then
    local cfg_to_save = {
      host = tostring(host),
      port = tostring(port),
    }
    if project_name then
      cfg_to_save.project = project_name
    end
    save_config_file(config_path, cfg_to_save)
  end
  
  return true
end

--- Get status information for statusline/winbar.
--- Returns status string with connection state and current flow.
function M.status()
  local parts = {}
  
  -- Connection indicator
  if control.is_connected and control.is_connected() then
    parts[#parts + 1] = M.config.icon
  elseif client.is_connected() then
    parts[#parts + 1] = M.config.icon
  end
  
  -- Current flow
  local flow_id = flow.get_active_flow_id()
  if flow_id then
    local active_flow = flow.get_active_flow()
    if active_flow and active_flow.info and active_flow.info.name then
      parts[#parts + 1] = active_flow.info.name
    else
      parts[#parts + 1] = "flow#" .. tostring(flow_id)
    end
  end
  
  return table.concat(parts, " ")
end

--- Notes API (re-export with demo logging).
M.add = function(...)
  demo_log("NoteAdd", "START")
  local result = notes.add(...)
  demo_log("NoteAdd", "END")
  return result
end

M.add_here = function(...)
  demo_log("NoteAddHere", "START")
  local result = notes.add_here(...)
  demo_log("NoteAddHere", "END")
  return result
end

M.edit = function(...)
  demo_log("NoteEdit", "START")
  local result = notes.edit(...)
  demo_log("NoteEdit", "END")
  return result
end

M.edit_here = function(...)
  demo_log("NoteEditHere", "START")
  local result = notes.edit_here(...)
  demo_log("NoteEditHere", "END")
  return result
end

M.edit_open = function(...)
  demo_log("NoteEditOpen", "START")
  local result = notes.edit_open(...)
  demo_log("NoteEditOpen", "END")
  return result
end

M.edit_float = notes.edit_float
M.edit_inline = notes.edit_inline

M.delete = function(...)
  demo_log("NoteDelete", "START")
  local result = notes.delete(...)
  demo_log("NoteDelete", "END")
  return result
end

M.show = function(...)
  demo_log("NoteShow", "START")
  local result = notes.show(...)
  demo_log("NoteShow", "END")
  return result
end

M.list = function(...)
  demo_log("NoteList", "START")
  local result = notes.list(...)
  demo_log("NoteList", "END")
  return result
end

M.toggle = notes.toggle
M.for_file = notes.for_file
M.set = notes.set
M.remove = notes.remove

M.search = function(...)
  demo_log("NoteSearch", "START")
  local result, err = notes.search(...)
  demo_log("NoteSearch", result and "END" or ("FAILED: " .. tostring(err)))
  return result, err
end

M.search_tags = notes.search_tags
M.search_columns = notes.search_columns
M.tag_count = notes.tag_count
M.search_results = notes.search_results

--- Flow API (re-export with demo logging).
M.flow_create = function(...)
  demo_log("FlowCreate", "START")
  local result, err = flow.create(...)
  demo_log("FlowCreate", result and "END" or ("FAILED: " .. tostring(err)))
  return result, err
end

M.flow_get_all = flow.get_all
M.flow_get = flow.get
M.flow_set = flow.set
M.flow_set_info = flow.set_info

M.flow_add_node = function(...)
  demo_log("FlowAddNode", "START")
  local result = flow.add_node(...)
  demo_log("FlowAddNode", "END")
  return result
end

M.flow_add_node_here = function(...)
  demo_log("FlowAddNodeHere", "START")
  local result = flow.add_node_here(...)
  demo_log("FlowAddNodeHere", "END")
  return result
end

M.flow_fork_node = flow.fork_node
M.flow_set_node = flow.set_node
M.flow_remove_node = flow.remove_node
M.flow_remove = flow.remove
M.flow_linked_to = flow.linked_to
M.flow_unlock = flow.unlock

M.flow_list = function(...)
  demo_log("FlowList", "START")
  local result = flow.list(...)
  demo_log("FlowList", "END")
  return result
end

M.flow_show = flow.show
M.flow_add_node_at_cursor = flow.add_node_at_cursor

M.flow_add_node_visual = function(...)
  demo_log("FlowAddNode", "START (visual)")
  local result, err = flow.add_node_visual(...)
  demo_log("FlowAddNode", result and "END" or ("FAILED: " .. tostring(err)))
  return result, err
end
M.flow_delete = flow.delete
M.flow_delete_node = flow.delete_node
M.flow_select = flow.select
M.flow_activate = flow.activate
M.flow_next = flow.next
M.flow_prev = flow.prev

return M
