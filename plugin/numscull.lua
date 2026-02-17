-- plugin/numscull.lua — loader for numscull (Numscull protocol client)

if vim.g.loaded_numscull then return end
vim.g.loaded_numscull = 1

local numscull = require("numscull")

-- Setup with defaults
numscull.setup()

-- Connection
vim.api.nvim_create_user_command("NumscullConnect", function(opts)
  local arg_str = opts.args or ""
  local host = numscull.config.host
  local port = numscull.config.port
  
  if arg_str ~= "" then
    local args = vim.split(arg_str, "%s+")
    -- Filter out empty strings from split result
    local non_empty_args = {}
    for _, arg in ipairs(args) do
      if arg ~= "" then
        table.insert(non_empty_args, arg)
      end
    end
    
    if #non_empty_args > 0 then
      -- Check if first arg is :port format
      if non_empty_args[1]:match("^:%d+$") then
        port = tonumber(non_empty_args[1]:sub(2))
      -- Check if first arg is numeric (port only)
      elseif tonumber(non_empty_args[1]) and #non_empty_args == 1 then
        port = tonumber(non_empty_args[1])
      -- Otherwise treat as host
      else
        host = non_empty_args[1]
        if #non_empty_args > 1 then
          port = tonumber(non_empty_args[2]) or port
        end
      end
    end
  end
  
  local ok, err = numscull.connect(host, port)
  if not ok then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
  else
    vim.notify("[numscull] connected", vim.log.levels.INFO)
  end
end, { nargs = "?", desc = "Connect to Numscull server and init" })

vim.api.nvim_create_user_command("NumscullDisconnect", function()
  numscull.disconnect()
  vim.notify("[numscull] disconnected", vim.log.levels.INFO)
end, { desc = "Disconnect from Numscull server" })

vim.api.nvim_create_user_command("NumscullProject", function(opts)
  if opts.args == "" then return end
  local ok, err = numscull.change_project(opts.args)
  if not ok then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
  else
    vim.notify("[numscull] project: " .. opts.args, vim.log.levels.INFO)
  end
end, { nargs = 1, desc = "Change active project" })

vim.api.nvim_create_user_command("NumscullListProjects", function()
  local result, err = numscull.list_projects()
  if err then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local projects = result.projects or {}
  if #projects == 0 then
    vim.notify("[numscull] no projects", vim.log.levels.INFO)
    return
  end
  for _, p in ipairs(projects) do
    vim.notify(string.format("  %s — %s", p.name or "?", p.repository or "?"), vim.log.levels.INFO)
  end
end, { desc = "List projects" })

-- Notes
vim.api.nvim_create_user_command("NoteAdd", function(opts)
  numscull.add(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "Add note at cursor" })

vim.api.nvim_create_user_command("NoteEdit", function()
  numscull.edit()
end, { desc = "Edit closest note" })

vim.api.nvim_create_user_command("NoteDelete", function()
  numscull.delete()
end, { desc = "Delete closest note" })

vim.api.nvim_create_user_command("NoteList", function()
  numscull.list()
end, { desc = "List notes for current file" })

vim.api.nvim_create_user_command("NoteShow", function()
  numscull.show()
end, { desc = "Show full text of closest note" })

vim.api.nvim_create_user_command("NoteToggle", function()
  numscull.toggle()
end, { desc = "Toggle note annotation visibility" })

vim.api.nvim_create_user_command("NoteSearch", function(opts)
  if opts.args == "" then
    vim.notify("[numscull] usage: NoteSearch <text>", vim.log.levels.WARN)
    return
  end
  local result, err = numscull.search(opts.args)
  if err then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local notes = result.notes or {}
  vim.notify(string.format("[numscull] %d notes found", #notes), vim.log.levels.INFO)
  -- TODO: display in scratch buffer
end, { nargs = 1, desc = "Search notes by text" })

vim.api.nvim_create_user_command("NoteSearchTags", function(opts)
  if opts.args == "" then
    vim.notify("[numscull] usage: NoteSearchTags <tag>", vim.log.levels.WARN)
    return
  end
  local result, err = numscull.search_tags(opts.args)
  if err then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local notes = result.notes or {}
  vim.notify(string.format("[numscull] %d notes with tag", #notes), vim.log.levels.INFO)
end, { nargs = 1, desc = "Search notes by tag" })

vim.api.nvim_create_user_command("NoteTagCount", function()
  local result, err = numscull.tag_count()
  if err then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local tags = result.tags or {}
  for _, t in ipairs(tags) do
    vim.notify(string.format("  #%s: %d", t.tag or "?", t.count or 0), vim.log.levels.INFO)
  end
end, { desc = "Show tag counts" })

-- Flows
vim.api.nvim_create_user_command("FlowCreate", function(opts)
  local args = vim.split(opts.args or "", "%s+", { plain = true })
  local name = args[1] or vim.fn.input("Flow name: ")
  if name == "" then return end
  local desc = args[2] or ""
  if #args > 2 then
    desc = table.concat(args, " ", 2)
  end
  local result, err = numscull.flow_create(name, desc)
  if err then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.notify("[numscull] flow created", vim.log.levels.INFO)
end, { nargs = "*", desc = "Create a flow" })

vim.api.nvim_create_user_command("FlowList", function()
  numscull.flow_list()
end, { desc = "List all flows" })

vim.api.nvim_create_user_command("FlowShow", function(opts)
  if opts.args == "" then
    vim.notify("[numscull] usage: FlowShow <flow_id>", vim.log.levels.WARN)
    return
  end
  numscull.flow_show(tonumber(opts.args))
end, { nargs = 1, desc = "Show flow details" })

vim.api.nvim_create_user_command("FlowAddNode", function(opts)
  local flow_id = opts.args ~= "" and tonumber(opts.args) or nil
  numscull.flow_add_node_at_cursor(flow_id)
end, { nargs = "?", desc = "Add node at cursor" })

vim.api.nvim_create_user_command("FlowRemoveNode", function(opts)
  if opts.args == "" then
    vim.notify("[numscull] usage: FlowRemoveNode <node_id>", vim.log.levels.WARN)
    return
  end
  local result, err = numscull.flow_remove_node(tonumber(opts.args))
  if err then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
  else
    vim.notify("[numscull] node removed", vim.log.levels.INFO)
  end
end, { nargs = 1, desc = "Remove a flow node" })

vim.api.nvim_create_user_command("FlowRemove", function(opts)
  if opts.args == "" then
    vim.notify("[numscull] usage: FlowRemove <flow_id>", vim.log.levels.WARN)
    return
  end
  local result, err = numscull.flow_remove(tonumber(opts.args))
  if err then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
  else
    vim.notify("[numscull] flow removed", vim.log.levels.INFO)
  end
end, { nargs = 1, desc = "Remove a flow" })
