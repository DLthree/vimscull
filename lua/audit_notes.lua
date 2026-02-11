-- audit_notes.lua — persistent collaborative audit annotations via extmarks
-- Pure Lua, Neovim 0.9+, no external dependencies.
local M = {}
local api, fn = vim.api, vim.fn

M.config = {
  storage_path = nil,   -- auto-detected
  author       = nil,   -- auto-detected
  autosave     = true,
  icon         = "📝",
  max_line_len = 120,
}

local ns = api.nvim_create_namespace("audit_notes")
local notes_by_file = {}  -- abs_path -> {note, ...}
local visible = true
local loaded_bufs = {}    -- tracks decorated buffers

local function uuid()
  return ("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end)
end

local function get_author()
  return M.config.author or vim.g.audit_author or os.getenv("USER") or "unknown"
end

local function git_root()
  local out = fn.systemlist("git rev-parse --show-toplevel 2>/dev/null")
  if vim.v.shell_error == 0 and out[1] and out[1] ~= "" then return out[1] end
  return nil
end

local function storage_path()
  if M.config.storage_path then return M.config.storage_path end
  local root = git_root()
  if root then return root .. "/.audit/notes.json" end
  return fn.stdpath("state") .. "/audit-notes.json"
end

local function ensure_parent(path)
  fn.mkdir(fn.fnamemodify(path, ":h"), "p")
end

local function load_all()
  local f = io.open(storage_path(), "r")
  if not f then notes_by_file = {}; return end
  local raw = f:read("*a"); f:close()
  local ok, data = pcall(vim.json.decode, raw)
  notes_by_file = (ok and type(data) == "table") and data or {}
end

local function save_all()
  local path = storage_path()
  ensure_parent(path)
  local f = io.open(path, "w")
  if not f then vim.notify("[audit] cannot write " .. path, vim.log.levels.ERROR); return end
  f:write(vim.json.encode(notes_by_file)); f:close()
end

local function hl_setup()
  api.nvim_set_hl(0, "AuditHeader", { link = "Identifier", default = true })
  api.nvim_set_hl(0, "AuditDim",    { link = "Comment",    default = true })
end

local function truncate(s, max)
  if #s <= max then return s end
  return s:sub(1, max - 1) .. "…"
end

local function build_virt_lines(note)
  local max, icon = M.config.max_line_len, M.config.icon
  local lines = {}
  local text_lines = vim.split(note.text, "\n", { plain = true })
  local header = string.format("%s [%s @ %s] ", icon, note.author or "?",
    (note.timestamp or ""):sub(1, 10))
  lines[1] = { { truncate(header .. (text_lines[1] or ""), max), "AuditHeader" } }
  local indent = string.rep(" ", fn.strdisplaywidth(icon) + 1)
  for i = 2, #text_lines do
    lines[#lines + 1] = { { truncate(indent .. text_lines[i], max), "AuditDim" } }
  end
  return lines
end

local function place_extmark(bufnr, note, row)
  note._extmark_id = api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
    virt_lines = build_virt_lines(note),
    virt_lines_above = false,
  })
end

local function clear_extmarks(bufnr)
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

local function buf_fpath(bufnr)
  local name = api.nvim_buf_get_name(bufnr)
  if name == "" then return nil end
  return fn.fnamemodify(name, ":p")
end

local function decorate_buf(bufnr)
  clear_extmarks(bufnr)
  if not visible then return end
  local fpath = buf_fpath(bufnr)
  if not fpath then return end
  local notes = notes_by_file[fpath]
  if not notes then return end
  local lc = api.nvim_buf_line_count(bufnr)
  table.sort(notes, function(a, b) return (a.line or 0) < (b.line or 0) end)
  for _, note in ipairs(notes) do
    local row = math.min(math.max((note.line or 1) - 1, 0), lc - 1)
    place_extmark(bufnr, note, row)
  end
end

local function sync_positions(bufnr)
  local fpath = buf_fpath(bufnr)
  if not fpath then return end
  local notes = notes_by_file[fpath]
  if not notes then return end
  for _, note in ipairs(notes) do
    if note._extmark_id then
      local ok, pos = pcall(api.nvim_buf_get_extmark_by_id, bufnr, ns, note._extmark_id, {})
      if ok and pos and pos[1] then
        note.line = pos[1] + 1
        note.col  = pos[2]
      end
    end
  end
end

local function find_closest_note(bufnr, cursor_row)
  local fpath = buf_fpath(bufnr)
  if not fpath then return nil, nil end
  local notes = notes_by_file[fpath]
  if not notes or #notes == 0 then return nil, nil end
  local best, best_dist, best_idx = nil, math.huge, nil
  for i, note in ipairs(notes) do
    local line = note.line or 1
    if note._extmark_id then
      local ok, pos = pcall(api.nvim_buf_get_extmark_by_id, bufnr, ns, note._extmark_id, {})
      if ok and pos and pos[1] then line = pos[1] + 1 end
    end
    local dist = math.abs(line - cursor_row)
    if dist < best_dist then best, best_dist, best_idx = note, dist, i end
  end
  return best, best_idx
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  hl_setup(); load_all()
  local grp = api.nvim_create_augroup("AuditNotes", { clear = true })
  api.nvim_create_autocmd("BufReadPost", { group = grp, callback = function(ev)
    loaded_bufs[ev.buf] = true; decorate_buf(ev.buf)
  end })
  api.nvim_create_autocmd("BufWritePost", { group = grp, callback = function(ev)
    if loaded_bufs[ev.buf] then
      sync_positions(ev.buf)
      if M.config.autosave then save_all() end
    end
  end })
end

function M.add(text)
  local bufnr = api.nvim_get_current_buf()
  local fpath = buf_fpath(bufnr)
  if not fpath then vim.notify("[audit] buffer has no file", vim.log.levels.WARN); return end
  if not text or text == "" then
    text = fn.input("Audit note (use \\n for newlines): ")
    if text == "" then return end
  end
  text = text:gsub("\\n", "\n")
  local note = {
    id = uuid(), text = text, author = get_author(),
    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    line = api.nvim_win_get_cursor(0)[1], col = 0,
  }
  if not notes_by_file[fpath] then notes_by_file[fpath] = {} end
  table.insert(notes_by_file[fpath], note)
  loaded_bufs[bufnr] = true; decorate_buf(bufnr)
  if M.config.autosave then save_all() end
  vim.notify("[audit] note added", vim.log.levels.INFO)
end

function M.edit()
  local bufnr = api.nvim_get_current_buf()
  local note = find_closest_note(bufnr, api.nvim_win_get_cursor(0)[1])
  if not note then vim.notify("[audit] no note near cursor", vim.log.levels.WARN); return end
  local new = fn.input("Edit note: ", note.text:gsub("\n", "\\n"))
  if new == "" then return end
  note.text = new:gsub("\\n", "\n")
  note.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
  decorate_buf(bufnr)
  if M.config.autosave then save_all() end
  vim.notify("[audit] note updated", vim.log.levels.INFO)
end

function M.delete()
  local bufnr = api.nvim_get_current_buf()
  local fpath = buf_fpath(bufnr)
  if not fpath then return end
  local note, idx = find_closest_note(bufnr, api.nvim_win_get_cursor(0)[1])
  if not note then vim.notify("[audit] no note near cursor", vim.log.levels.WARN); return end
  local ok = fn.input(string.format("Delete note '%s'? (y/N): ", note.text:sub(1, 40)))
  if ok ~= "y" and ok ~= "Y" then return end
  table.remove(notes_by_file[fpath], idx)
  decorate_buf(bufnr)
  if M.config.autosave then save_all() end
  vim.notify("[audit] note deleted", vim.log.levels.INFO)
end

function M.show()
  local bufnr = api.nvim_get_current_buf()
  local note = find_closest_note(bufnr, api.nvim_win_get_cursor(0)[1])
  if not note then vim.notify("[audit] no note near cursor", vim.log.levels.WARN); return end
  vim.notify(string.format("[%s @ %s]\n%s", note.author or "?", note.timestamp or "?", note.text),
    vim.log.levels.INFO)
end

function M.list()
  local bufnr = api.nvim_get_current_buf()
  local fpath = buf_fpath(bufnr)
  if not fpath then return end
  local notes = notes_by_file[fpath]
  if not notes or #notes == 0 then vim.notify("[audit] no notes in this file", vim.log.levels.INFO); return end
  sync_positions(bufnr)
  local lines = { "# Audit notes for " .. fn.fnamemodify(fpath, ":~:."), "" }
  local jump_map = {}
  for _, note in ipairs(notes) do
    lines[#lines + 1] = string.format("L%-4d  [%s @ %s]  %s",
      note.line or 0, note.author or "?", (note.timestamp or ""):sub(1, 10),
      note.text:gsub("\n", " | "))
    jump_map[#lines] = note.line or 1
  end
  vim.cmd("botright new")
  local sbuf = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
  vim.bo[sbuf].buftype  = "nofile"
  vim.bo[sbuf].bufhidden = "wipe"
  vim.bo[sbuf].swapfile  = false
  vim.bo[sbuf].filetype  = "audit_list"
  api.nvim_buf_set_keymap(sbuf, "n", "<CR>", "", {
    noremap = true, silent = true,
    callback = function()
      local target = jump_map[api.nvim_win_get_cursor(0)[1]]
      if target then vim.cmd("wincmd p"); pcall(api.nvim_win_set_cursor, 0, { target, 0 }) end
    end,
  })
end

function M.toggle()
  visible = not visible
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and loaded_bufs[buf] then
      if visible then decorate_buf(buf) else clear_extmarks(buf) end
    end
  end
  vim.notify("[audit] annotations " .. (visible and "shown" or "hidden"), vim.log.levels.INFO)
end

function M.export()
  local bufnr = api.nvim_get_current_buf()
  local fpath = buf_fpath(bufnr)
  if not fpath then return end
  local notes = notes_by_file[fpath]
  if not notes or #notes == 0 then vim.notify("[audit] nothing to export", vim.log.levels.INFO); return end
  sync_positions(bufnr)
  local root = git_root() or fn.getcwd()
  local rel = fn.fnamemodify(fpath, ":~:.")
  local outpath = root .. "/.audit/" .. rel .. ".md"
  ensure_parent(outpath)
  local lines = { "# Audit notes: " .. rel, "" }
  table.sort(notes, function(a, b) return (a.line or 0) < (b.line or 0) end)
  for _, note in ipairs(notes) do
    lines[#lines + 1] = string.format("## Line %d — %s (%s)",
      note.line or 0, note.author or "?", (note.timestamp or ""):sub(1, 10))
    lines[#lines + 1] = ""
    for _, tl in ipairs(vim.split(note.text, "\n", { plain = true })) do
      lines[#lines + 1] = tl
    end
    lines[#lines + 1] = ""
  end
  local f = io.open(outpath, "w")
  if not f then vim.notify("[audit] cannot write " .. outpath, vim.log.levels.ERROR); return end
  f:write(table.concat(lines, "\n")); f:close()
  vim.notify("[audit] exported to " .. outpath, vim.log.levels.INFO)
end

return M
