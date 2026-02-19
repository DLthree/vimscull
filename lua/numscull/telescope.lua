-- numscull/telescope.lua — optional Telescope adapter (no hard dependency)

local M = {}

--- Open a Telescope picker for note search results.
--- Falls back to notes.search_results() if Telescope is not installed.
--- @param results table[] — raw note objects from server
--- @param title string — picker title
--- @return boolean — true if Telescope was used, false if fallback
function M.pick_notes(results, title)
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then return false end

  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local fn = vim.fn

  pickers.new({}, {
    prompt_title = title or "Notes",
    finder = finders.new_table({
      results = results,
      entry_maker = function(raw_note)
        local loc = raw_note.location or {}
        local file_id = loc.fileId or {}
        local uri = file_id.uri or ""
        local path = uri:gsub("^file://", "")
        local rel = fn.fnamemodify(path, ":~:.")
        local line = loc.line or 1
        local text = (raw_note.text or ""):gsub("\n", " | ")
        return {
          value = raw_note,
          display = string.format("%s:%d  %s", rel, line, text),
          ordinal = text .. " " .. rel,
          filename = path,
          lnum = line,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = conf.grep_previewer({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          vim.cmd("edit " .. fn.fnameescape(entry.filename))
          pcall(vim.api.nvim_win_set_cursor, 0, { entry.lnum, 0 })
        end
      end)
      return true
    end,
  }):find()

  return true
end

return M
