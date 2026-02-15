-- flows.lua — persistent code flow highlighting with parent/child navigation
-- Pure Lua, Neovim 0.9+, no external dependencies.
local M = {}
local api, fn = vim.api, vim.fn

M.config = {
  storage_path = nil, -- auto-detected
}

local ns = api.nvim_create_namespace("flows")

local state = {
  flows = {},           -- array of flow objects
  active_flow_id = nil, -- which flow is currently selected
}
local loaded_bufs = {} -- tracks decorated buffers

-- Color palette for flow node highlights
M.palette = {
  { name = "Red",     hl = "FlowRed",     fg = "#ff5555", bg = "#3a1515" },
  { name = "Blue",    hl = "FlowBlue",    fg = "#8888ff", bg = "#15153a" },
  { name = "Green",   hl = "FlowGreen",   fg = "#55ff55", bg = "#153a15" },
  { name = "Yellow",  hl = "FlowYellow",  fg = "#ffff55", bg = "#3a3a15" },
  { name = "Cyan",    hl = "FlowCyan",    fg = "#55ffff", bg = "#153a3a" },
  { name = "Magenta", hl = "FlowMagenta", fg = "#ff55ff", bg = "#3a153a" },
}

local function uuid()
  return ("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end)
end

local function git_root()
  local out = fn.systemlist("git rev-parse --show-toplevel 2>/dev/null")
  if vim.v.shell_error == 0 and out[1] and out[1] ~= "" then return out[1] end
  return nil
end

local function storage_path()
  if M.config.storage_path then return M.config.storage_path end
  local root = git_root()
  if root then return root .. "/.audit/flows.json" end
  return fn.stdpath("state") .. "/flows.json"
end

local function ensure_parent(path)
  fn.mkdir(fn.fnamemodify(path, ":h"), "p")
end

local function load_all()
  local f = io.open(storage_path(), "r")
  if not f then state = { flows = {}, active_flow_id = nil }; return end
  local raw = f:read("*a"); f:close()
  local ok, data = pcall(vim.json.decode, raw)
  if ok and type(data) == "table" then
    state.flows = data.flows or {}
    state.active_flow_id = data.active_flow_id
  else
    state = { flows = {}, active_flow_id = nil }
  end
end

local function save_all()
  local path = storage_path()
  ensure_parent(path)
  local f = io.open(path, "w")
  if not f then vim.notify("[flows] cannot write " .. path, vim.log.levels.ERROR); return end
  f:write(vim.json.encode({
    flows = state.flows,
    active_flow_id = state.active_flow_id,
  }))
  f:close()
end

local function hl_setup()
  for _, c in ipairs(M.palette) do
    api.nvim_set_hl(0, c.hl, { fg = c.fg, bg = c.bg, default = true })
  end
  api.nvim_set_hl(0, "FlowSelect", { link = "PmenuSel", default = true })
  api.nvim_set_hl(0, "FlowHeader", { link = "Title", default = true })
end

local function get_active_flow()
  if not state.active_flow_id then return nil end
  for _, flow in ipairs(state.flows) do
    if flow.id == state.active_flow_id then return flow end
  end
  return nil
end

local function buf_fpath(bufnr)
  local name = api.nvim_buf_get_name(bufnr)
  if name == "" then return nil end
  return fn.fnamemodify(name, ":p")
end

-- Place highlight extmarks for the active flow in a buffer
local function decorate_buf(bufnr)
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local flow = get_active_flow()
  if not flow then return end
  local fpath = buf_fpath(bufnr)
  if not fpath then return end
  local lc = api.nvim_buf_line_count(bufnr)
  for _, node in ipairs(flow.nodes) do
    if node.file == fpath then
      local row = math.min(math.max((node.line or 1) - 1, 0), lc - 1)
      local line_text = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      local col_s = math.min(node.col_start or 0, #line_text)
      local col_e = math.min(node.col_end or 0, #line_text)
      node._extmark_id = api.nvim_buf_set_extmark(bufnr, ns, row, col_s, {
        end_row = row,
        end_col = col_e,
        hl_group = node.color or "FlowRed",
      })
    end
  end
end

local function decorate_all_bufs()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and buf_fpath(buf) then
      loaded_bufs[buf] = true
      decorate_buf(buf)
    end
  end
end

-- Public getters for testing and external use
function M.get_active_flow()
  return get_active_flow()
end

function M.get_flows()
  return state.flows
end

function M.get_active_flow_id()
  return state.active_flow_id
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  hl_setup()
  load_all()
  local grp = api.nvim_create_augroup("Flows", { clear = true })
  api.nvim_create_autocmd("BufReadPost", { group = grp, callback = function(ev)
    loaded_bufs[ev.buf] = true
    decorate_buf(ev.buf)
  end })
  api.nvim_create_autocmd("BufWritePost", { group = grp, callback = function(ev)
    if loaded_bufs[ev.buf] then
      save_all()
    end
  end })
end

-- Create a new flow
function M.create(name)
  if not name or name == "" then
    name = fn.input("Flow name: ")
    if name == "" then return end
  end
  local flow = {
    id = uuid(),
    name = name,
    nodes = {},
  }
  table.insert(state.flows, flow)
  state.active_flow_id = flow.id
  save_all()
  decorate_all_bufs()
  vim.notify("[flows] created flow: " .. name, vim.log.levels.INFO)
end

-- Delete the active flow
function M.delete()
  local flow = get_active_flow()
  if not flow then vim.notify("[flows] no active flow", vim.log.levels.WARN); return end
  local ok = fn.input(string.format("Delete flow '%s'? (y/N): ", flow.name))
  if ok ~= "y" and ok ~= "Y" then return end
  for i, f in ipairs(state.flows) do
    if f.id == flow.id then
      table.remove(state.flows, i)
      break
    end
  end
  state.active_flow_id = nil
  save_all()
  decorate_all_bufs()
  vim.notify("[flows] flow deleted", vim.log.levels.INFO)
end

-- Add a node from visual selection or programmatic opts
-- opts (optional): { line, col_start, col_end, color }
function M.add_node(opts)
  opts = opts or {}
  local bufnr = api.nvim_get_current_buf()
  local fpath = buf_fpath(bufnr)
  if not fpath then vim.notify("[flows] buffer has no file", vim.log.levels.WARN); return end
  local flow = get_active_flow()
  if not flow then vim.notify("[flows] no active flow — create one first", vim.log.levels.WARN); return end

  local line, col_start, col_end
  if opts.line then
    -- Programmatic call
    line = opts.line
    col_start = opts.col_start or 0
    col_end = opts.col_end or 0
  else
    -- Read from visual selection marks
    local start_pos = fn.getpos("'<")
    local end_pos = fn.getpos("'>")
    line = start_pos[2]
    col_start = start_pos[3] - 1 -- 0-indexed
    col_end = end_pos[3]         -- exclusive end
  end

  local color = opts.color
  if not color then
    local prompt = "Pick color: "
    for i, c in ipairs(M.palette) do
      prompt = prompt .. string.format("%d=%s ", i, c.name)
    end
    local choice = fn.input(prompt)
    local idx = tonumber(choice)
    color = "FlowRed"
    if idx and idx >= 1 and idx <= #M.palette then
      color = M.palette[idx].hl
    end
  end

  local node = {
    id = uuid(),
    file = fpath,
    line = line,
    col_start = col_start,
    col_end = col_end,
    color = color,
  }
  table.insert(flow.nodes, node)
  save_all()
  decorate_buf(bufnr)
  vim.notify(string.format("[flows] node added (line %d, %s)", line, color), vim.log.levels.INFO)
end

-- Remove the closest node in the active flow from cursor position
function M.delete_node()
  local bufnr = api.nvim_get_current_buf()
  local fpath = buf_fpath(bufnr)
  if not fpath then return end
  local flow = get_active_flow()
  if not flow then vim.notify("[flows] no active flow", vim.log.levels.WARN); return end

  local cursor_line = api.nvim_win_get_cursor(0)[1]
  local best_idx, best_dist = nil, math.huge
  for i, node in ipairs(flow.nodes) do
    if node.file == fpath then
      local dist = math.abs((node.line or 1) - cursor_line)
      if dist < best_dist then best_idx, best_dist = i, dist end
    end
  end
  if not best_idx then vim.notify("[flows] no node near cursor in this file", vim.log.levels.WARN); return end
  table.remove(flow.nodes, best_idx)
  save_all()
  decorate_buf(bufnr)
  vim.notify("[flows] node removed", vim.log.levels.INFO)
end

-- Navigate to the next node (child) in the active flow
function M.next()
  local flow = get_active_flow()
  if not flow or #flow.nodes == 0 then
    vim.notify("[flows] no active flow or no nodes", vim.log.levels.WARN); return
  end

  local bufnr = api.nvim_get_current_buf()
  local fpath = buf_fpath(bufnr)
  local cursor = api.nvim_win_get_cursor(0)
  local current_idx = nil
  local best_dist = math.huge

  for i, node in ipairs(flow.nodes) do
    if node.file == fpath then
      local dist = math.abs((node.line or 1) - cursor[1])
      if dist < best_dist then current_idx, best_dist = i, dist end
    end
  end

  local target_idx
  if current_idx and current_idx < #flow.nodes then
    target_idx = current_idx + 1
  else
    target_idx = 1 -- wrap around
  end

  local target = flow.nodes[target_idx]
  if not target then return end

  if target.file ~= fpath then
    vim.cmd("edit " .. fn.fnameescape(target.file))
  end
  pcall(api.nvim_win_set_cursor, 0, { target.line or 1, target.col_start or 0 })
  vim.notify(string.format("[flows] node %d/%d", target_idx, #flow.nodes), vim.log.levels.INFO)
end

-- Navigate to the previous node (parent) in the active flow
function M.prev()
  local flow = get_active_flow()
  if not flow or #flow.nodes == 0 then
    vim.notify("[flows] no active flow or no nodes", vim.log.levels.WARN); return
  end

  local bufnr = api.nvim_get_current_buf()
  local fpath = buf_fpath(bufnr)
  local cursor = api.nvim_win_get_cursor(0)
  local current_idx = nil
  local best_dist = math.huge

  for i, node in ipairs(flow.nodes) do
    if node.file == fpath then
      local dist = math.abs((node.line or 1) - cursor[1])
      if dist < best_dist then current_idx, best_dist = i, dist end
    end
  end

  local target_idx
  if current_idx and current_idx > 1 then
    target_idx = current_idx - 1
  else
    target_idx = #flow.nodes -- wrap around
  end

  local target = flow.nodes[target_idx]
  if not target then return end

  if target.file ~= fpath then
    vim.cmd("edit " .. fn.fnameescape(target.file))
  end
  pcall(api.nvim_win_set_cursor, 0, { target.line or 1, target.col_start or 0 })
  vim.notify(string.format("[flows] node %d/%d", target_idx, #flow.nodes), vim.log.levels.INFO)
end

-- UI: floating window to select or create flows
function M.select()
  if #state.flows == 0 then
    vim.notify("[flows] no flows exist — creating new one", vim.log.levels.INFO)
    M.create()
    return
  end

  local lines = { " Flows (press number to select, n=new, d=delete, q=quit)", "" }
  for i, flow in ipairs(state.flows) do
    local marker = (flow.id == state.active_flow_id) and " * " or "   "
    lines[#lines + 1] = string.format("%s%d. %s (%d nodes)", marker, i, flow.name, #flow.nodes)
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
  for i, flow in ipairs(state.flows) do
    if flow.id == state.active_flow_id then
      api.nvim_buf_add_highlight(buf, -1, "FlowSelect", i + 1, 0, -1)
    end
  end

  local function close()
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  end

  local function select_flow(idx)
    if idx >= 1 and idx <= #state.flows then
      state.active_flow_id = state.flows[idx].id
      save_all()
      decorate_all_bufs()
      close()
      vim.notify("[flows] active: " .. state.flows[idx].name, vim.log.levels.INFO)
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
    callback = function() close(); M.create() end,
  })

  api.nvim_buf_set_keymap(buf, "n", "d", "", {
    noremap = true, silent = true,
    callback = function() close(); M.delete() end,
  })

  api.nvim_buf_set_keymap(buf, "n", "q", "", { noremap = true, silent = true, callback = close })
  api.nvim_buf_set_keymap(buf, "n", "<Esc>", "", { noremap = true, silent = true, callback = close })
end

-- List nodes in the active flow in a scratch buffer
function M.list()
  local flow = get_active_flow()
  if not flow then vim.notify("[flows] no active flow", vim.log.levels.WARN); return end
  if #flow.nodes == 0 then vim.notify("[flows] no nodes in flow", vim.log.levels.INFO); return end

  local lines = { "# Flow: " .. flow.name .. " (" .. #flow.nodes .. " nodes)", "" }
  for i, node in ipairs(flow.nodes) do
    local rel = fn.fnamemodify(node.file, ":~:.")
    lines[#lines + 1] = string.format("%d. %s:%d:%d-%d [%s]",
      i, rel, node.line or 0, (node.col_start or 0) + 1, node.col_end or 0, node.color or "?")
  end

  vim.cmd("botright new")
  local sbuf = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
  vim.bo[sbuf].buftype = "nofile"
  vim.bo[sbuf].bufhidden = "wipe"
  vim.bo[sbuf].swapfile = false
  vim.bo[sbuf].filetype = "flow_list"

  api.nvim_buf_set_keymap(sbuf, "n", "<CR>", "", {
    noremap = true, silent = true,
    callback = function()
      local row = api.nvim_win_get_cursor(0)[1]
      local idx = row - 2
      if idx >= 1 and idx <= #flow.nodes then
        local node = flow.nodes[idx]
        vim.cmd("wincmd p")
        if buf_fpath(api.nvim_get_current_buf()) ~= node.file then
          vim.cmd("edit " .. fn.fnameescape(node.file))
        end
        pcall(api.nvim_win_set_cursor, 0, { node.line or 1, node.col_start or 0 })
      end
    end,
  })
end

return M
