-- plugin/flows.lua — loader for flows
-- Neovim 0.9+

if vim.g.loaded_flows then return end
vim.g.loaded_flows = 1

local flows = require("flows")

-- User commands
vim.api.nvim_create_user_command("FlowCreate", function(opts)
  flows.create(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "Create a new flow" })

vim.api.nvim_create_user_command("FlowDelete", function()
  flows.delete()
end, { desc = "Delete the active flow" })

vim.api.nvim_create_user_command("FlowSelect", function()
  flows.select()
end, { desc = "Open flow selection UI" })

vim.api.nvim_create_user_command("FlowAddNode", function()
  flows.add_node()
end, { range = true, desc = "Add visual selection as flow node" })

vim.api.nvim_create_user_command("FlowDeleteNode", function()
  flows.delete_node()
end, { desc = "Delete closest flow node" })

vim.api.nvim_create_user_command("FlowNext", function()
  flows.next()
end, { desc = "Jump to next (child) flow node" })

vim.api.nvim_create_user_command("FlowPrev", function()
  flows.prev()
end, { desc = "Jump to previous (parent) flow node" })

vim.api.nvim_create_user_command("FlowList", function()
  flows.list()
end, { desc = "List nodes in the active flow" })
