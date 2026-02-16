-- numscull/init.lua — main entry: setup, config, autocommands, public API

local M = {}
local api = vim.api
local control = require("numscull.control")
local notes = require("numscull.notes")
local flow = require("numscull.flow")

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
}

local augroup = nil

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  notes.setup({ icon = M.config.icon, max_line_len = M.config.max_line_len })

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
  local ok, err = control.init(host, port, identity, nil, config_dir)
  if not ok then
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

--- Notes API (re-export).
M.add = notes.add
M.edit = notes.edit
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

--- Flow API (re-export).
M.flow_create = flow.create
M.flow_get_all = flow.get_all
M.flow_get = flow.get
M.flow_set = flow.set
M.flow_set_info = flow.set_info
M.flow_add_node = flow.add_node
M.flow_fork_node = flow.fork_node
M.flow_set_node = flow.set_node
M.flow_remove_node = flow.remove_node
M.flow_remove = flow.remove
M.flow_linked_to = flow.linked_to
M.flow_unlock = flow.unlock
M.flow_list = flow.list
M.flow_show = flow.show
M.flow_add_node_at_cursor = flow.add_node_at_cursor

return M
