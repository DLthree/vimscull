-- numscull/notes.lua — notes module API + extmark rendering

local M = {}
local api, fn = vim.api, vim.fn
local client = require("numscull.client")

M.config = {
  icon = "📝",
  max_line_len = 120,
}

local ns = api.nvim_create_namespace("numscull_notes")
local notes_by_uri = {}  -- uri -> {note, ...}  (Note has location, text, author, createdDate, etc.)
local visible = true
local loaded_bufs = {}

--- Convert file path to file URI.
local function path_to_uri(path)
  if not path or path == "" then return nil end
  path = fn.fnamemodify(path, ":p")
  if path:sub(1, 1) ~= "/" then
    path = fn.getcwd() .. "/" .. path
  end
  return "file://" .. path
end

--- Convert file URI to path.
local function uri_to_path(uri)
  if not uri or uri:sub(1, 7) ~= "file://" then return nil end
  return uri:sub(8)
end

local function buf_uri(bufnr)
  local name = api.nvim_buf_get_name(bufnr)
  if name == "" then return nil end
  return path_to_uri(name)
end

local function buf_fpath(bufnr)
  local name = api.nvim_buf_get_name(bufnr)
  if name == "" then return nil end
  return fn.fnamemodify(name, ":p")
end

local function hl_setup()
  api.nvim_set_hl(0, "NumscullHeader", { link = "Identifier", default = true })
  api.nvim_set_hl(0, "NumscullDim", { link = "Comment", default = true })
end

local function truncate(s, max)
  if #s <= max then return s end
  return s:sub(1, max - 1) .. "…"
end

--- Normalize server Note to display format (add .line for convenience).
local function normalize_note(note)
  local loc = note.location or {}
  local file_id = loc.fileId or {}
  local uri = file_id.uri or ""
  local line = loc.line or 1
  return {
    location = loc,
    uri = uri,
    line = line,
    text = note.text or "",
    author = note.author or "?",
    modifiedBy = note.modifiedBy or note.author or "?",
    createdDate = note.createdDate or "",
    modifiedDate = note.modifiedDate or note.createdDate or "",
    orphaned = note.orphaned,
  }
end

local function build_virt_lines(note)
  local max, icon = M.config.max_line_len, M.config.icon
  local lines = {}
  local text_lines = vim.split(note.text, "\n", { plain = true })
  local date = (note.modifiedDate or note.createdDate or ""):sub(1, 10)
  local header = string.format("%s [%s @ %s] ", icon, note.author or "?", date)
  lines[1] = { { truncate(header .. (text_lines[1] or ""), max), "NumscullHeader" } }
  local indent = string.rep(" ", fn.strdisplaywidth(icon) + 1)
  for i = 2, #text_lines do
    lines[#lines + 1] = { { truncate(indent .. text_lines[i], max), "NumscullDim" } }
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

local function decorate_buf(bufnr)
  clear_extmarks(bufnr)
  if not visible then return end
  local uri = buf_uri(bufnr)
  if not uri then return end
  local notes = notes_by_uri[uri]
  if not notes or #notes == 0 then return end
  local lc = api.nvim_buf_line_count(bufnr)
  table.sort(notes, function(a, b) return (a.line or 0) < (b.line or 0) end)
  for _, note in ipairs(notes) do
    local row = math.min(math.max((note.line or 1) - 1, 0), lc - 1)
    place_extmark(bufnr, note, row)
  end
end

local function find_closest_note(bufnr, cursor_row)
  local uri = buf_uri(bufnr)
  if not uri then return nil, nil end
  local notes = notes_by_uri[uri]
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

--- Fetch notes for a file from the server and update cache.
function M.for_file(uri)
  if not client.is_connected() then
    return nil, "not connected"
  end
  local params = { fileId = { uri = uri }, page = { index = 0, size = 100 } }
  local result = client.request("notes/for/file", params)
  if not result then return nil, "request failed" end
  local notes = {}
  for _, n in ipairs(result.notes or {}) do
    notes[#notes + 1] = normalize_note(n)
  end
  notes_by_uri[uri] = notes
  return notes
end

--- Create or update a note.
function M.set(note_input, verify_file_hash)
  if not client.is_connected() then
    return nil, "not connected"
  end
  local params = { note = note_input, verifyFileHash = verify_file_hash or vim.NIL }
  local result = client.request("notes/set", params)
  if not result then return nil, "request failed" end
  local note = normalize_note(result.note or {})
  local uri = (note.location or {}).fileId and (note.location.fileId or {}).uri
  if uri then
    local notes = notes_by_uri[uri] or {}
    local line = note.line
    local found = false
    for i, n in ipairs(notes) do
      if n.line == line then
        notes[i] = note
        found = true
        break
      end
    end
    if not found then
      notes[#notes + 1] = note
      table.sort(notes, function(a, b) return (a.line or 0) < (b.line or 0) end)
    end
    notes_by_uri[uri] = notes
  end
  return note
end

--- Remove a note by location.
function M.remove(uri, line)
  if not client.is_connected() then
    return nil, "not connected"
  end
  local result = client.request("notes/remove", {
    location = { fileId = { uri = uri }, line = line },
  })
  if not result then return nil, "request failed" end
  local notes = notes_by_uri[uri]
  if notes then
    for i, n in ipairs(notes) do
      if n.line == line then
        table.remove(notes, i)
        break
      end
    end
  end
  return true
end

--- Search notes by text.
function M.search(text, page)
  if not client.is_connected() then return nil, "not connected" end
  return client.request("notes/search", { text = text, page = page })
end

--- Search notes by tag.
function M.search_tags(text, page)
  if not client.is_connected() then return nil, "not connected" end
  return client.request("notes/search/tags", { text = text, page = page })
end

--- Search with filter/order/page.
function M.search_columns(filter, order, page)
  if not client.is_connected() then return nil, "not connected" end
  local params = { filter = filter or {} }
  if order then params.order = order end
  if page then params.page = page end
  return client.request("notes/search/columns", params)
end

--- Get tag counts.
function M.tag_count()
  if not client.is_connected() then return nil, "not connected" end
  return client.request("notes/tag/count", {})
end

--- Add a note at cursor. Prompts for text if not provided.
function M.add(text)
  local bufnr = api.nvim_get_current_buf()
  local uri = buf_uri(bufnr)
  if not uri then
    vim.notify("[numscull] buffer has no file", vim.log.levels.WARN)
    return
  end
  if not text or text == "" then
    text = fn.input("Note (use \\n for newlines): ")
    if text == "" then return end
  end
  text = text:gsub("\\n", "\n")
  local line = api.nvim_win_get_cursor(0)[1]
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local note_input = {
    location = { fileId = { uri = uri }, line = line },
    text = text,
    createdDate = now,
    modifiedDate = now,
  }
  local note, err = M.set(note_input)
  if not note then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  loaded_bufs[bufnr] = true
  decorate_buf(bufnr)
  vim.notify("[numscull] note added", vim.log.levels.INFO)
end

--- Edit the closest note.
function M.edit()
  local bufnr = api.nvim_get_current_buf()
  local note = find_closest_note(bufnr, api.nvim_win_get_cursor(0)[1])
  if not note then
    vim.notify("[numscull] no note near cursor", vim.log.levels.WARN)
    return
  end
  local new = fn.input("Edit note: ", (note.text:gsub("\n", "\\n")))
  if new == "" then return end
  new = new:gsub("\\n", "\n")
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local note_input = {
    location = note.location,
    text = new,
    createdDate = note.createdDate,
    modifiedDate = now,
  }
  local updated, err = M.set(note_input)
  if not updated then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  decorate_buf(bufnr)
  vim.notify("[numscull] note updated", vim.log.levels.INFO)
end

--- Delete the closest note.
function M.delete()
  local bufnr = api.nvim_get_current_buf()
  local uri = buf_uri(bufnr)
  if not uri then return end
  local note, idx = find_closest_note(bufnr, api.nvim_win_get_cursor(0)[1])
  if not note then
    vim.notify("[numscull] no note near cursor", vim.log.levels.WARN)
    return
  end
  local ok = fn.input(string.format("Delete note '%s'? (y/N): ", note.text:sub(1, 40)))
  if ok ~= "y" and ok ~= "Y" then return end
  local _, err = M.remove(uri, note.line)
  if err then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  decorate_buf(bufnr)
  vim.notify("[numscull] note deleted", vim.log.levels.INFO)
end

--- Show full text of closest note.
function M.show()
  local bufnr = api.nvim_get_current_buf()
  local note = find_closest_note(bufnr, api.nvim_win_get_cursor(0)[1])
  if not note then
    vim.notify("[numscull] no note near cursor", vim.log.levels.WARN)
    return
  end
  local date = note.modifiedDate or note.createdDate or "?"
  vim.notify(string.format("[%s @ %s]\n%s", note.author or "?", date, note.text),
    vim.log.levels.INFO)
end

--- List notes for current file (fetch from server, show in scratch buffer).
function M.list()
  local bufnr = api.nvim_get_current_buf()
  local uri = buf_uri(bufnr)
  if not uri then return end
  local notes, err = M.for_file(uri)
  if err then
    vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  if not notes or #notes == 0 then
    vim.notify("[numscull] no notes in this file", vim.log.levels.INFO)
    return
  end
  loaded_bufs[bufnr] = true
  decorate_buf(bufnr)
  local fpath = buf_fpath(bufnr)
  local lines = { "# Notes for " .. fn.fnamemodify(fpath or "", ":~:."), "" }
  local jump_map = {}
  for _, note in ipairs(notes) do
    local date = (note.modifiedDate or note.createdDate or ""):sub(1, 10)
    lines[#lines + 1] = string.format("L%-4d  [%s @ %s]  %s",
      note.line or 0, note.author or "?", date,
      note.text:gsub("\n", " | "))
    jump_map[#lines] = note.line or 1
  end
  vim.cmd("botright new")
  local sbuf = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
  vim.bo[sbuf].buftype = "nofile"
  vim.bo[sbuf].bufhidden = "wipe"
  vim.bo[sbuf].swapfile = false
  vim.bo[sbuf].filetype = "numscull_list"
  api.nvim_buf_set_keymap(sbuf, "n", "<CR>", "", {
    noremap = true,
    silent = true,
    callback = function()
      local target = jump_map[api.nvim_win_get_cursor(0)[1]]
      if target then
        vim.cmd("wincmd p")
        pcall(api.nvim_win_set_cursor, 0, { target, 0 })
      end
    end,
  })
end

--- Toggle annotation visibility.
function M.toggle()
  visible = not visible
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and loaded_bufs[buf] then
      if visible then decorate_buf(buf) else clear_extmarks(buf) end
    end
  end
  vim.notify("[numscull] annotations " .. (visible and "shown" or "hidden"), vim.log.levels.INFO)
end

--- Fetch notes for buffer and decorate. Called on BufReadPost.
function M.fetch_and_decorate(bufnr)
  local uri = buf_uri(bufnr)
  if not uri then return end
  if not client.is_connected() then return end
  local notes, err = M.for_file(uri)
  if err then return end
  loaded_bufs[bufnr] = true
  decorate_buf(bufnr)
end

--- Decorate a buffer (uses cached notes).
function M.decorate(bufnr)
  loaded_bufs[bufnr] = true
  decorate_buf(bufnr)
end

--- Get cached notes for URI (for tests).
function M.get_cached(uri)
  return notes_by_uri[uri]
end

--- Get URI for buffer (same format used by decorate/for_file). For tests.
function M.get_buf_uri(bufnr)
  return buf_uri(bufnr)
end

--- Configure (icon, max_line_len).
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  hl_setup()
end

return M
