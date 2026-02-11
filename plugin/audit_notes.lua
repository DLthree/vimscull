-- plugin/audit_notes.lua — loader for audit_notes
-- Neovim 0.9+

if vim.g.loaded_audit_notes then return end
vim.g.loaded_audit_notes = 1

local audit = require("audit_notes")

-- User commands
vim.api.nvim_create_user_command("AuditAdd", function()
  audit.add()
end, { desc = "Add an audit note below the cursor line" })

vim.api.nvim_create_user_command("AuditAddHere", function(opts)
  audit.add(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "Add an audit note with inline text" })

vim.api.nvim_create_user_command("AuditEdit", function()
  audit.edit()
end, { desc = "Edit the closest audit note" })

vim.api.nvim_create_user_command("AuditDelete", function()
  audit.delete()
end, { desc = "Delete the closest audit note (with confirmation)" })

vim.api.nvim_create_user_command("AuditList", function()
  audit.list()
end, { desc = "List all audit notes in this file" })

vim.api.nvim_create_user_command("AuditToggle", function()
  audit.toggle()
end, { desc = "Toggle audit annotation visibility" })

vim.api.nvim_create_user_command("AuditShow", function()
  audit.show()
end, { desc = "Echo the full text of the closest audit note" })

vim.api.nvim_create_user_command("AuditExport", function()
  audit.export()
end, { desc = "Export notes for this file to .audit/<file>.md" })
