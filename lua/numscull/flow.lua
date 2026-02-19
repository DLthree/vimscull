-- numscull/flow.lua — flow module API + inline highlights, navigation, select UI

local M = {}
local api, fn = vim.api, vim.fn
local client = require("numscull.client")

local ns = api.nvim_create_namespace("numscull_flows")

-- Client-side active flow tracking
local state = {
  active_flow_id = nil, -- currently selected flow (server-side infoId)
  cached_flow = nil,    -- cached Flow object for the active flow
  node_order = {},      -- sorted list of {node_id, node} for navigation
}

-- Color palette for flow node highlights
M.palette = {
  { name = "Red",     hl = "FlowRed",     fg = "#ff5555", bg = "#3a1515" },
  { name = "Blue",    hl = "FlowBlue",    fg = "#8888ff", bg = "#15153a" },
  { name = "Green",   hl = "FlowGreen",   fg = "#55ff55", bg = "#153a15" },
  { name = "Yellow",  hl = "FlowYellow",  fg = "#ffff55", bg = "#3a3a15" },
  { name = "Cyan",    hl = "FlowCyan",    fg = "#55ffff", bg = "#153a3a" },
  { name = "Magenta", hl = "FlowMagenta", fg = "#ff55ff", bg = "#3a153a" },
}

M.config = {}

-- Map hex colors to highlight group names (created on demand)
local hex_hl_cache = {}

local function get_palette()
  return M.config.palette or M.palette
end

local function hl_setup()
  local palette = get_palette()
  for _, c in ipairs(palette) do
    api.nvim_set_hl(0, c.hl, { fg = c.fg, bg = c.bg, default = true })
  end
  api.nvim_set_hl(0, "FlowSelect", { link = "PmenuSel", default = true })
  api.nvim_set_hl(0, "FlowHeader", { link = "Title", default = true })
  api.nvim_set_hl(0, "NumscullDim", { link = "Comment", default = true })
end

--- Get or create a highlight group for a hex color.
local function hl_for_hex(hex)
  if not hex or hex == "" then hex = "#888888" end
  -- Check if it matches a palette entry
  local palette = get_palette()
  for _, c in ipairs(palette) do
    if c.fg == hex or c.hl == hex then return c.hl end
  end
  if hex_hl_cache[hex] then return hex_hl_cache[hex] end
  local name = "FlowHex_" .. hex:gsub("#", "")
  local r = tonumber(hex:sub(2, 3), 16) or 128
  local g = tonumber(hex:sub(4, 5), 16) or 128
  local b = tonumber(hex:sub(6, 7), 16) or 128
  local bg = string.format("#%02x%02x%02x", math.floor(r * 0.25), math.floor(g * 0.25), math.floor(b * 0.25))
  api.nvim_set_hl(0, name, { fg = hex, bg = bg })
  hex_hl_cache[hex] = name
  return name
end

--- Path to URI for file locations.
local function path_to_uri(path)
  if not path or path == "" then return nil end
  path = fn.fnamemodify(path, ":p")
  if path:sub(1, 1) ~= "/" then
    path = fn.getcwd() .. "/" .. path
  end
  return "file://" .. path
end

--- URI to file path.
local function uri_to_path(uri)
  if not uri then return nil end
  return uri:gsub("^file://", "")
end

--- Get current buffer URI.
local function buf_uri(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local name = api.nvim_buf_get_name(bufnr)
  if name == "" then return nil end
  return path_to_uri(name)
end

--- Get current buffer absolute file path.
local function buf_fpath(bufnr)
  local name = api.nvim_buf_get_name(bufnr or api.nvim_get_current_buf())
  if name == "" then return nil end
  return fn.fnamemodify(name, ":p")
end

--- Sort nodes by nodeId for stable ordering.
local function build_node_order(nodes)
  local ordered = {}
  for node_id, node in pairs(nodes or {}) do
    ordered[#ordered + 1] = { id = tonumber(node_id) or node_id, node = node }
  end
  table.sort(ordered, function(a, b) return a.id < b.id end)
  return ordered
end

--- Refresh the cached flow from server and rebuild node order.
local function refresh_active_flow()
  if not state.active_flow_id then
    state.cached_flow = nil
    state.node_order = {}
    return nil
  end
  if not client.is_connected() then return nil end
  local result, err = client.request("flow/get", { flowId = state.active_flow_id })
  if err or not result then
    state.cached_flow = nil
    state.node_order = {}
    return nil
  end
  state.cached_flow = result.flow
  state.node_order = build_node_order((result.flow or {}).nodes)
  return result.flow
end

--- Place highlight extmarks for the active flow in a buffer.
local function decorate_buf(bufnr)
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not state.cached_flow then return end
  local fpath = buf_fpath(bufnr)
  if not fpath then return end
  local lc = api.nvim_buf_line_count(bufnr)
  for _, entry in ipairs(state.node_order) do
    local node = entry.node
    local loc = node.location or {}
    local node_path = uri_to_path((loc.fileId or {}).uri)
    if node_path == fpath then
      local row = math.min(math.max((loc.line or 1) - 1, 0), lc - 1)
      local line_text = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      local col_s = math.min(loc.startCol or 0, #line_text)
      local col_e = math.min(loc.endCol or 0, #line_text)
      local hl = hl_for_hex(node.color)
      api.nvim_buf_set_extmark(bufnr, ns, row, col_s, {
        end_row = row,
        end_col = col_e,
        hl_group = hl,
      })
    end
  end
end

--- Decorate all loaded buffers.
local function decorate_all_bufs()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and buf_fpath(buf) then
      decorate_buf(buf)
    end
  end
end

--- Setup highlight groups and autocommands for flow decoration.
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  hl_setup()
  local grp = api.nvim_create_augroup("NumscullFlows", { clear = true })
  api.nvim_create_autocmd("BufReadPost", {
    group = grp,
    callback = function(ev) decorate_buf(ev.buf) end,
  })
end

--- Get the active flow ID.
function M.get_active_flow_id()
  return state.active_flow_id
end

--- Get the cached active flow.
function M.get_active_flow()
  return state.cached_flow
end

--- Get the ordered node list for navigation.
function M.get_node_order()
  return state.node_order
end

-----------------------------------------------------------------------
-- Server RPC wrappers
-----------------------------------------------------------------------

--- Create a flow.
function M.create(name, description, created_date)
  if not client.is_connected() then return nil, "not connected" end
  created_date = created_date or os.date("!%Y-%m-%dT%H:%M:%SZ")
  local result, err = client.request("flow/create", {
    name = name,
    description = description or "",
    createdDate = created_date,
  })
  if result and result.flow and result.flow.info then
    state.active_flow_id = result.flow.info.infoId
    refresh_active_flow()
    decorate_all_bufs()
  end
  return result, err
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
  local result, err = client.request("flow/add/node", params)
  if result and state.active_flow_id then
    refresh_active_flow()
    decorate_all_bufs()
  end
  return result, err
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
  local result, err = client.request("flow/fork/node", params)
  if result and state.active_flow_id then
    refresh_active_flow()
    decorate_all_bufs()
  end
  return result, err
end

--- Update a node.
function M.set_node(node_id, node)
  if not client.is_connected() then return nil, "not connected" end
  local result, err = client.request("flow/set/node", { nodeId = node_id, node = node })
  if result and state.active_flow_id then
    refresh_active_flow()
    decorate_all_bufs()
  end
  return result, err
end

--- Remove a node.
function M.remove_node(node_id)
  if not client.is_connected() then return nil, "not connected" end
  local result, err = client.request("flow/remove/node", { nodeId = node_id })
  if result and state.active_flow_id then
    refresh_active_flow()
    decorate_all_bufs()
  end
  return result, err
end

--- Remove a flow.
function M.remove(flow_id)
  if not client.is_connected() then return nil, "not connected" end
  local result, err = client.request("flow/remove", { flowId = flow_id })
  if result and state.active_flow_id == flow_id then
    state.active_flow_id = nil
    state.cached_flow = nil
    state.node_order = {}
    decorate_all_bufs()
  end
  return result, err
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

-----------------------------------------------------------------------
-- Interactive commands (ported from local flows)
-----------------------------------------------------------------------

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

--- Build TextDocumentRange from visual selection marks.
function M.location_from_visual(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local uri = buf_uri(bufnr)
  if not uri then return nil end
  local start_pos = fn.getpos("'<")
  local end_pos = fn.getpos("'>")
  return {
    fileId = { uri = uri },
    line = start_pos[2],
    startCol = start_pos[3] - 1,
    endCol = end_pos[3],
  }
end

--- Add node at cursor to flow (interactive).
function M.add_node_at_cursor(flow_id, note, color)
  local loc = M.location_at_cursor()
  if not loc then
    vim.notify("[numscull] buffer has no file", vim.log.levels.WARN)
    return
  end
  color = color or "#888888"
  local fid = flow_id or state.active_flow_id
  local opts = fid and { flowId = fid } or {}

  local function do_add(n)
    if not n then return end
    local result, err = M.add_node(loc, n, color, opts)
    if err then
      vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.notify("[numscull] node added", vim.log.levels.INFO)
  end

  if note then
    do_add(note)
  else
    vim.ui.input({ prompt = "Node note: " }, do_add)
  end
end

--- Add node from visual selection (interactive — prompts for color via vim.ui.select).
function M.add_node_visual(flow_id)
  if not client.is_connected() then
    vim.notify("[numscull] not connected", vim.log.levels.ERROR)
    return
  end
  local loc = M.location_from_visual()
  if not loc then
    vim.notify("[numscull] buffer has no file", vim.log.levels.WARN)
    return
  end
  local fid = flow_id or state.active_flow_id
  if not fid then
    vim.notify("[numscull] no active flow — create one first", vim.log.levels.WARN)
    return
  end

  local color_names = {}
  local palette = get_palette()
  for _, c in ipairs(palette) do
    color_names[#color_names + 1] = c.name
  end

  vim.ui.select(color_names, { prompt = "Pick node color:" }, function(choice)
    if not choice then return end
    local color = "#888888"
    for _, c in ipairs(palette) do
      if c.name == choice then color = c.fg; break end
    end
    vim.ui.input({ prompt = "Node note: " }, function(note)
      if not note then return end
      local result, err = M.add_node(loc, note, color, { flowId = fid })
      if err then
        vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify(string.format("[numscull] node added (line %d)", loc.line), vim.log.levels.INFO)
    end)
  end)
end

--- Delete the active flow (with vim.ui.select confirmation).
function M.delete()
  if not client.is_connected() then
    vim.notify("[numscull] not connected", vim.log.levels.ERROR)
    return
  end
  if not state.active_flow_id then
    vim.notify("[numscull] no active flow", vim.log.levels.WARN)
    return
  end
  local flow = state.cached_flow
  local name = (flow and flow.info and flow.info.name) or "?"
  vim.ui.select({ "Yes", "No" }, {
    prompt = string.format("Delete flow '%s'?", name),
  }, function(choice)
    if choice ~= "Yes" then return end
    local result, err = M.remove(state.active_flow_id)
    if err then
      vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.notify("[numscull] flow deleted", vim.log.levels.INFO)
  end)
end

--- Remove closest node near cursor from the active flow.
function M.delete_node()
  if not client.is_connected() then
    vim.notify("[numscull] not connected", vim.log.levels.ERROR)
    return
  end
  if not state.active_flow_id or #state.node_order == 0 then
    vim.notify("[numscull] no active flow or no nodes", vim.log.levels.WARN)
    return
  end
  local fpath = buf_fpath(api.nvim_get_current_buf())
  if not fpath then return end
  local cursor_line = api.nvim_win_get_cursor(0)[1]

  local best_entry, best_dist = nil, math.huge
  for _, entry in ipairs(state.node_order) do
    local loc = entry.node.location or {}
    local node_path = uri_to_path((loc.fileId or {}).uri)
    if node_path == fpath then
      local dist = math.abs((loc.line or 1) - cursor_line)
      if dist < best_dist then best_entry, best_dist = entry, dist end
    end
  end
  if not best_entry then
    vim.notify("[numscull] no node near cursor in this file", vim.log.levels.WARN)
    return
  end
  local result, err = M.remove_node(best_entry.id)
  if err then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.notify("[numscull] node removed", vim.log.levels.INFO)
end

--- Navigate to next node in active flow.
function M.next()
  if not state.active_flow_id or #state.node_order == 0 then
    vim.notify("[numscull] no active flow or no nodes", vim.log.levels.WARN)
    return
  end

  local fpath = buf_fpath(api.nvim_get_current_buf())
  local cursor = api.nvim_win_get_cursor(0)
  local current_idx = nil
  local best_dist = math.huge

  for i, entry in ipairs(state.node_order) do
    local loc = entry.node.location or {}
    local node_path = uri_to_path((loc.fileId or {}).uri)
    if node_path == fpath then
      local dist = math.abs((loc.line or 1) - cursor[1])
      if dist < best_dist then current_idx, best_dist = i, dist end
    end
  end

  local target_idx
  if current_idx and current_idx < #state.node_order then
    target_idx = current_idx + 1
  else
    target_idx = 1
  end

  local target = state.node_order[target_idx]
  if not target then return end
  local loc = target.node.location or {}
  local target_path = uri_to_path((loc.fileId or {}).uri)

  if target_path and target_path ~= fpath then
    vim.cmd("edit " .. fn.fnameescape(target_path))
  end
  pcall(api.nvim_win_set_cursor, 0, { loc.line or 1, loc.startCol or 0 })
  vim.notify(string.format("[numscull] node %d/%d", target_idx, #state.node_order), vim.log.levels.INFO)
end

--- Navigate to previous node in active flow.
function M.prev()
  if not state.active_flow_id or #state.node_order == 0 then
    vim.notify("[numscull] no active flow or no nodes", vim.log.levels.WARN)
    return
  end

  local fpath = buf_fpath(api.nvim_get_current_buf())
  local cursor = api.nvim_win_get_cursor(0)
  local current_idx = nil
  local best_dist = math.huge

  for i, entry in ipairs(state.node_order) do
    local loc = entry.node.location or {}
    local node_path = uri_to_path((loc.fileId or {}).uri)
    if node_path == fpath then
      local dist = math.abs((loc.line or 1) - cursor[1])
      if dist < best_dist then current_idx, best_dist = i, dist end
    end
  end

  local target_idx
  if current_idx and current_idx > 1 then
    target_idx = current_idx - 1
  else
    target_idx = #state.node_order
  end

  local target = state.node_order[target_idx]
  if not target then return end
  local loc = target.node.location or {}
  local target_path = uri_to_path((loc.fileId or {}).uri)

  if target_path and target_path ~= fpath then
    vim.cmd("edit " .. fn.fnameescape(target_path))
  end
  pcall(api.nvim_win_set_cursor, 0, { loc.line or 1, loc.startCol or 0 })
  vim.notify(string.format("[numscull] node %d/%d", target_idx, #state.node_order), vim.log.levels.INFO)
end

--- Switch active flow by ID (fetch and decorate).
function M.activate(flow_id)
  state.active_flow_id = flow_id
  refresh_active_flow()
  decorate_all_bufs()
end

--- Floating window to select, create, or delete flows.
function M.select()
  if not client.is_connected() then
    vim.notify("[numscull] not connected", vim.log.levels.ERROR)
    return
  end

  local result, err = M.get_all()
  if err then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local infos = result.flowInfos or {}

  if #infos == 0 then
    vim.notify("[numscull] no flows — use :FlowCreate to create one", vim.log.levels.INFO)
    return
  end

  local lines = { " Flows", " <CR>=select  n=new  d=delete  q=close", "" }
  for i, info in ipairs(infos) do
    local marker = (info.infoId == state.active_flow_id) and " * " or "   "
    local node_info = (info.description or ""):sub(1, 30)
    lines[#lines + 1] = string.format("%s%d. %s — %s", marker, i, info.name or "?", node_info)
  end

  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, #l) end
  width = math.max(width + 4, 40)
  local height = #lines + 1

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  local win_opts = {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Flow Select ",
    title_pos = "center",
  }
  local win = api.nvim_open_win(buf, true, win_opts)

  api.nvim_buf_add_highlight(buf, -1, "FlowHeader", 0, 0, -1)
  api.nvim_buf_add_highlight(buf, -1, "NumscullDim", 1, 0, -1)
  for i, info in ipairs(infos) do
    if info.infoId == state.active_flow_id then
      api.nvim_buf_add_highlight(buf, -1, "FlowSelect", i + 1, 0, -1)
    end
  end

  local function close()
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  end

  local function select_flow(idx)
    if idx >= 1 and idx <= #infos then
      M.activate(infos[idx].infoId)
      close()
      vim.notify("[numscull] active: " .. (infos[idx].name or "?"), vim.log.levels.INFO)
    end
  end

  for i = 1, 9 do
    api.nvim_buf_set_keymap(buf, "n", tostring(i), "", {
      noremap = true, silent = true,
      callback = function() select_flow(i) end,
    })
  end

  api.nvim_buf_set_keymap(buf, "n", "<CR>", "", {
    noremap = true, silent = true,
    callback = function()
      local row = api.nvim_win_get_cursor(0)[1]
      local idx = row - 2
      select_flow(idx)
    end,
  })

  api.nvim_buf_set_keymap(buf, "n", "n", "", {
    noremap = true, silent = true,
    callback = function()
      close()
      vim.ui.input({ prompt = "Flow name: " }, function(name)
        if not name or name == "" then return end
        vim.ui.input({ prompt = "Description: " }, function(desc)
          local r, e = M.create(name, desc or "")
          if e then
            vim.notify("[numscull] " .. tostring(e), vim.log.levels.ERROR)
          else
            vim.notify("[numscull] flow created: " .. name, vim.log.levels.INFO)
          end
        end)
      end)
    end,
  })

  api.nvim_buf_set_keymap(buf, "n", "d", "", {
    noremap = true, silent = true,
    callback = function() close(); M.delete() end,
  })

  api.nvim_buf_set_keymap(buf, "n", "q", "", { noremap = true, silent = true, callback = close })
  api.nvim_buf_set_keymap(buf, "n", "<Esc>", "", { noremap = true, silent = true, callback = close })
end

--- Helper: set common UI buffer options and close keymaps.
local function setup_ui_buf(sbuf)
  vim.bo[sbuf].buftype = "nofile"
  vim.bo[sbuf].bufhidden = "wipe"
  vim.bo[sbuf].swapfile = false
  vim.bo[sbuf].modifiable = false
  vim.wo[0].cursorline = true
  local kopts = { noremap = true, silent = true }
  api.nvim_buf_set_keymap(sbuf, "n", "q", "", vim.tbl_extend("force", kopts, {
    callback = function() vim.cmd("bwipeout!") end,
  }))
  api.nvim_buf_set_keymap(sbuf, "n", "<Esc>", "", vim.tbl_extend("force", kopts, {
    callback = function() vim.cmd("bwipeout!") end,
  }))
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
  local legend = "<CR>=select  d=delete  r=refresh  q=close"
  local lines = { "Flows", legend, "" }
  local select_map = {}  -- row -> infoId
  for _, info in ipairs(infos) do
    local marker = (info.infoId == state.active_flow_id) and " * " or "   "
    lines[#lines + 1] = string.format("%s%d  %s — %s",
      marker, info.infoId or 0, info.name or "?", (info.description or ""):sub(1, 40))
    select_map[#lines] = info.infoId
  end
  vim.cmd("botright new")
  local sbuf = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
  vim.bo[sbuf].filetype = "numscull_flows"
  setup_ui_buf(sbuf)

  -- Highlights
  api.nvim_buf_add_highlight(sbuf, -1, "FlowHeader", 0, 0, -1)
  api.nvim_buf_add_highlight(sbuf, -1, "NumscullDim", 1, 0, -1)
  for i, info in ipairs(infos) do
    local row = i + 2  -- 0-indexed: header(0), legend(1), blank(2), entries start at 3
    if info.infoId == state.active_flow_id then
      api.nvim_buf_add_highlight(sbuf, -1, "FlowSelect", row, 0, -1)
    end
  end

  -- Keymaps
  local kopts = { noremap = true, silent = true }
  api.nvim_buf_set_keymap(sbuf, "n", "<CR>", "", vim.tbl_extend("force", kopts, {
    callback = function()
      local fid = select_map[api.nvim_win_get_cursor(0)[1]]
      if fid then
        M.activate(fid)
        vim.cmd("bwipeout!")
        vim.notify("[numscull] active flow changed", vim.log.levels.INFO)
      end
    end,
  }))
  api.nvim_buf_set_keymap(sbuf, "n", "d", "", vim.tbl_extend("force", kopts, {
    callback = function()
      vim.cmd("bwipeout!")
      M.delete()
    end,
  }))
  api.nvim_buf_set_keymap(sbuf, "n", "r", "", vim.tbl_extend("force", kopts, {
    callback = function()
      pcall(vim.cmd, "bwipeout!")
      M.list()
    end,
  }))
end

--- Show flow details in scratch buffer.
function M.show(flow_id)
  flow_id = flow_id or state.active_flow_id
  if not flow_id then
    vim.notify("[numscull] no flow specified and no active flow", vim.log.levels.WARN)
    return
  end
  local result, err = M.get(flow_id)
  if err then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local flow = result.flow or {}
  local info = flow.info or {}
  local nodes = flow.nodes or {}
  local legend = "<CR>=jump  q=close"
  local lines = {
    "# " .. (info.name or "Flow") .. " (id=" .. tostring(flow_id) .. ")",
    legend,
    (info.description or ""):sub(1, 80),
    "",
    "## Nodes",
    "",
  }
  local header_lines = #lines
  local ordered = build_node_order(nodes)
  for _, entry in ipairs(ordered) do
    local node = entry.node
    if type(node) ~= "table" then goto continue end
    local loc = type(node.location) == "table" and node.location or {}
    local file_id = type(loc.fileId) == "table" and loc.fileId or {}
    local uri = tostring(file_id.uri or "?")
    local rel = fn.fnamemodify(uri_to_path(uri) or "?", ":~:.")
    local line = tonumber(loc.line) or 0
    lines[#lines + 1] = string.format("  %s  %s:%d [%s] — %s",
      tostring(entry.id), rel, line, tostring(node.color or "?"), tostring(node.note or ""):sub(1, 50))
    ::continue::
  end
  vim.cmd("botright new")
  local sbuf = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
  vim.bo[sbuf].filetype = "numscull_flow"
  setup_ui_buf(sbuf)

  -- Highlights
  api.nvim_buf_add_highlight(sbuf, -1, "FlowHeader", 0, 0, -1)
  api.nvim_buf_add_highlight(sbuf, -1, "NumscullDim", 1, 0, -1)

  -- <CR> jumps to node location
  local kopts = { noremap = true, silent = true }
  api.nvim_buf_set_keymap(sbuf, "n", "<CR>", "", vim.tbl_extend("force", kopts, {
    callback = function()
      local row = api.nvim_win_get_cursor(0)[1]
      local idx = row - header_lines
      if idx >= 1 and idx <= #ordered then
        local node = ordered[idx].node
        local loc = node.location or {}
        local path = uri_to_path((loc.fileId or {}).uri)
        if path then
          vim.cmd("wincmd p")
          if buf_fpath(api.nvim_get_current_buf()) ~= path then
            vim.cmd("edit " .. fn.fnameescape(path))
          end
          pcall(api.nvim_win_set_cursor, 0, { loc.line or 1, loc.startCol or 0 })
        end
      end
    end,
  }))
end

return M
