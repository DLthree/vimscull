-- numscull/flow.lua — flow module API + scratch buffer display

local M = {}
local api, fn = vim.api, vim.fn
local client = require("numscull.client")

--- Path to URI for file locations.
local function path_to_uri(path)
  if not path or path == "" then return nil end
  path = fn.fnamemodify(path, ":p")
  if path:sub(1, 1) ~= "/" then
    path = fn.getcwd() .. "/" .. path
  end
  return "file://" .. path
end

--- Get current buffer URI.
local function buf_uri(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local name = api.nvim_buf_get_name(bufnr)
  if name == "" then return nil end
  return path_to_uri(name)
end

--- Create a flow.
function M.create(name, description, created_date)
  if not client.is_connected() then return nil, "not connected" end
  created_date = created_date or os.date("!%Y-%m-%dT%H:%M:%SZ")
  return client.request("flow/create", {
    name = name,
    description = description or "",
    createdDate = created_date,
  })
end

--- Get all flows.
function M.get_all()
  if not client.is_connected() then return nil, "not connected" end
  return client.request("flow/get/all", {})
end

--- Get a flow by ID.
function M.get(flow_id)
  if not client.is_connected() then return nil, "not connected" end
  return client.request("flow/get", { flowId = flow_id })
end

--- Update entire flow.
function M.set(flow)
  if not client.is_connected() then return nil, "not connected" end
  return client.request("flow/set", { flow = flow })
end

--- Update flow metadata.
function M.set_info(flow_id, name, description, modified_date)
  if not client.is_connected() then return nil, "not connected" end
  modified_date = modified_date or os.date("!%Y-%m-%dT%H:%M:%SZ")
  return client.request("flow/set/info", {
    flowId = flow_id,
    name = name,
    description = description or "",
    modifiedDate = modified_date,
  })
end

--- Add node to flow.
function M.add_node(location, note, color, opts)
  if not client.is_connected() then return nil, "not connected" end
  opts = opts or {}
  local params = {
    location = location,
    note = note or "",
    color = color or "#888888",
  }
  if opts.flowId then params.flowId = opts.flowId end
  if opts.parentId then params.parentId = opts.parentId end
  if opts.childId then params.childId = opts.childId end
  if opts.name then params.name = opts.name end
  if opts.link then params.link = opts.link end
  if opts.orphaned then params.orphaned = opts.orphaned end
  return client.request("flow/add/node", params)
end

--- Fork node from parent.
function M.fork_node(location, note, color, parent_id, opts)
  if not client.is_connected() then return nil, "not connected" end
  opts = opts or {}
  local params = {
    location = location,
    note = note or "",
    color = color or "#888888",
    parentId = parent_id,
  }
  if opts.name then params.name = opts.name end
  if opts.link then params.link = opts.link end
  if opts.orphaned then params.orphaned = opts.orphaned end
  return client.request("flow/fork/node", params)
end

--- Update a node.
function M.set_node(node_id, node)
  if not client.is_connected() then return nil, "not connected" end
  return client.request("flow/set/node", { nodeId = node_id, node = node })
end

--- Remove a node.
function M.remove_node(node_id)
  if not client.is_connected() then return nil, "not connected" end
  return client.request("flow/remove/node", { nodeId = node_id })
end

--- Remove a flow.
function M.remove(flow_id)
  if not client.is_connected() then return nil, "not connected" end
  return client.request("flow/remove", { flowId = flow_id })
end

--- Get flows linked to a flow.
function M.linked_to(flow_id)
  if not client.is_connected() then return nil, "not connected" end
  return client.request("flow/linked/to", { flowId = flow_id })
end

--- Unlock a flow.
function M.unlock(flow_id)
  if not client.is_connected() then return nil, "not connected" end
  return client.request("flow/unlock", { flowId = flow_id })
end

--- Build TextDocumentRange from cursor position.
function M.location_at_cursor(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local uri = buf_uri(bufnr)
  if not uri then return nil end
  local row, col = unpack(api.nvim_win_get_cursor(0))
  return {
    fileId = { uri = uri },
    line = row,
    startCol = col,
    endCol = math.max(col, 1),
  }
end

--- List all flows in scratch buffer.
function M.list()
  local result, err = M.get_all()
  if err then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local infos = result.flowInfos or {}
  if #infos == 0 then
    vim.notify("[numscull] no flows", vim.log.levels.INFO)
    return
  end
  local lines = { "# Flows", "" }
  for _, info in ipairs(infos) do
    lines[#lines + 1] = string.format("  %d  %s — %s",
      info.infoId or 0, info.name or "?", (info.description or ""):sub(1, 40))
  end
  vim.cmd("botright new")
  local sbuf = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
  vim.bo[sbuf].buftype = "nofile"
  vim.bo[sbuf].bufhidden = "wipe"
  vim.bo[sbuf].swapfile = false
  vim.bo[sbuf].filetype = "numscull_flows"
end

--- Show flow details in scratch buffer.
function M.show(flow_id)
  local result, err = M.get(flow_id)
  if err then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local flow = result.flow or {}
  local info = flow.info or {}
  local nodes = flow.nodes or {}
  local lines = {
    "# " .. (info.name or "Flow") .. " (id=" .. tostring(flow_id) .. ")",
    (info.description or ""):sub(1, 80),
    "",
    "## Nodes",
    "",
  }
  for node_id, node in pairs(nodes) do
    local loc = node.location or {}
    local uri = (loc.fileId or {}).uri or "?"
    local line = loc.line or 0
    lines[#lines + 1] = string.format("  %s  %s L%d — %s",
      tostring(node_id), (node.name or ""):sub(1, 12), line, (node.note or ""):sub(1, 50))
  end
  vim.cmd("botright new")
  local sbuf = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
  vim.bo[sbuf].buftype = "nofile"
  vim.bo[sbuf].bufhidden = "wipe"
  vim.bo[sbuf].swapfile = false
  vim.bo[sbuf].filetype = "numscull_flow"
end

--- Add node at cursor to flow.
function M.add_node_at_cursor(flow_id, note, color)
  local loc = M.location_at_cursor()
  if not loc then
    vim.notify("[numscull] buffer has no file", vim.log.levels.WARN)
    return
  end
  note = note or fn.input("Node note: ")
  color = color or "#888888"
  local opts = flow_id and { flowId = flow_id } or {}
  local result, err = M.add_node(loc, note, color, opts)
  if err then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.notify("[numscull] node added", vim.log.levels.INFO)
end

return M
