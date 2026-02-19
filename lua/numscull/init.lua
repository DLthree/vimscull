-- numscull/init.lua — main entry: setup, config, autocommands, public API

local M = {}
local api = vim.api
local control = require("numscull.control")
local notes = require("numscull.notes")
local flow = require("numscull.flow")
local client = require("numscull.client")

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
end

--- Connect and initialize (control/init + key exchange).
function M.connect(host, port)
  host = host or M.config.host
  port = port or M.config.port
  local identity = M.config.identity or os.getenv("USER") or "unknown"
  local config_dir = M.config.config_dir
  if not config_dir then
    return nil, "config_dir required for init (path to identities/)"
  end
  local pcall_ok, result, err = pcall(control.init, host, port, identity, nil, config_dir)
  if not pcall_ok then
    return nil, tostring(result)
  end
  if not result then
    return nil, err
  end
  if M.config.project then
    control.change_project(M.config.project)
  end
  return true
end

--- Disconnect.
function M.disconnect()
  control.disconnect()
end

--- Exit (control/exit + close).
function M.exit()
  control.exit()
end

--- Change project.
function M.change_project(name)
  return control.change_project(name)
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

--- Quick connect: connect to server and optionally open a project.
--- Optionally saves settings to .numscull/config if save_config is true.
function M.quick_connect(host, port, project_name, save_config)
  host = host or M.config.host
  port = port or M.config.port
  
  local ok, err = M.connect(host, port)
  if not ok then
    return nil, err
  end
  
  if project_name then
    local result, err2 = control.change_project(project_name)
    if not result then
      return nil, err2
    end
    M.config.project = project_name
  end
  
  if save_config then
    local config_path = vim.fn.getcwd() .. "/.numscull/config"
    local cfg = {
      host = tostring(host),
      port = tostring(port),
    }
    if project_name then
      cfg.project = project_name
    end
    save_config_file(config_path, cfg)
  end
  
  return true
end

--- Quick connect auto: read .numscull/config and auto-connect.
function M.quick_connect_auto()
  local config_path = vim.fn.getcwd() .. "/.numscull/config"
  local cfg, err = load_config_file(config_path)
  
  if not cfg then
    return nil, err
  end
  
  local host = cfg.host or M.config.host
  local port = tonumber(cfg.port) or M.config.port
  local project_name = cfg.project
  
  return M.quick_connect(host, port, project_name, false)
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

--- Notes API (re-export).
M.add = notes.add
M.add_here = notes.add_here
M.edit = notes.edit
M.edit_here = notes.edit_here
M.edit_open = notes.edit_open
M.edit_float = notes.edit_float
M.edit_inline = notes.edit_inline
M.delete = notes.delete
M.show = notes.show
M.list = notes.list
M.toggle = notes.toggle
M.for_file = notes.for_file
M.set = notes.set
M.remove = notes.remove
M.search = notes.search
M.search_tags = notes.search_tags
M.search_columns = notes.search_columns
M.tag_count = notes.tag_count
M.search_results = notes.search_results

--- Flow API (re-export).
M.flow_create = flow.create
M.flow_get_all = flow.get_all
M.flow_get = flow.get
M.flow_set = flow.set
M.flow_set_info = flow.set_info
M.flow_add_node = flow.add_node
M.flow_add_node_here = flow.add_node_here
M.flow_fork_node = flow.fork_node
M.flow_set_node = flow.set_node
M.flow_remove_node = flow.remove_node
M.flow_remove = flow.remove
M.flow_linked_to = flow.linked_to
M.flow_unlock = flow.unlock
M.flow_list = flow.list
M.flow_show = flow.show
M.flow_add_node_at_cursor = flow.add_node_at_cursor
M.flow_add_node_visual = flow.add_node_visual
M.flow_delete = flow.delete
M.flow_delete_node = flow.delete_node
M.flow_select = flow.select
M.flow_activate = flow.activate
M.flow_next = flow.next
M.flow_prev = flow.prev

return M
