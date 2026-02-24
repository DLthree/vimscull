-- numscull/notes.lua — notes module API + extmark rendering

local M = {}
local api, fn = vim.api, vim.fn
local client = require("numscull.client")

M.config = {
  icon = "📝",
  max_line_len = 120,
  editor = "float",         -- "float" (two-pane) or "inline" (single-pane with virt_lines)
  context_lines = 10,       -- lines of code context above/below in editors
  float_border = "rounded",
  float_width = 0.8,        -- ratio of editor width
  float_height = 0.7,       -- ratio of editor height
  split_direction = "vertical", -- "vertical" or "horizontal" for two-pane layout
  note_template = "",       -- Template for new notes
  mappings = {
    note_add = "<leader>na",
    note_edit = "<leader>ne",
  },
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
  api.nvim_set_hl(0, "NumscullListHeader", { link = "Title", default = true })
  api.nvim_set_hl(0, "NumscullListLegend", { link = "Comment", default = true })
  api.nvim_set_hl(0, "NumscullListId", { link = "Number", default = true })
  api.nvim_set_hl(0, "NumscullListMeta", { link = "Special", default = true })
  api.nvim_set_hl(0, "NumscullListFile", { link = "Directory", default = true })
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
  local line = api.nvim_win_get_cursor(0)[1]

  local function do_add(input)
    if not input or input == "" then return end
    input = input:gsub("\\n", "\n")
    local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local note_input = {
      location = { fileId = { uri = uri }, line = line },
      text = input,
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

  if text and text ~= "" then
    do_add(text)
  else
    vim.ui.input({ prompt = "Note (use \\n for newlines): " }, do_add)
  end
end

--- Edit the closest note (quick inline edit via vim.ui.input).
function M.edit()
  local bufnr = api.nvim_get_current_buf()
  local note = find_closest_note(bufnr, api.nvim_win_get_cursor(0)[1])
  if not note then
    vim.notify("[numscull] no note near cursor", vim.log.levels.WARN)
    return
  end
  vim.ui.input({
    prompt = "Edit note: ",
    default = (note.text:gsub("\n", "\\n")),
  }, function(new)
    if not new or new == "" then return end
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
  end)
end

--- Delete the closest note (with vim.ui.select confirmation).
function M.delete()
  local bufnr = api.nvim_get_current_buf()
  local uri = buf_uri(bufnr)
  if not uri then return end
  local note, idx = find_closest_note(bufnr, api.nvim_win_get_cursor(0)[1])
  if not note then
    vim.notify("[numscull] no note near cursor", vim.log.levels.WARN)
    return
  end
  vim.ui.select({ "Yes", "No" }, {
    prompt = string.format("Delete note '%s'?", note.text:sub(1, 40)),
  }, function(choice)
    if choice ~= "Yes" then return end
    local _, err = M.remove(uri, note.line)
    if err then
      vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    decorate_buf(bufnr)
    vim.notify("[numscull] note deleted", vim.log.levels.INFO)
  end)
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

--- List notes for current file (fetch from server, show in scratch buffer).
function M.list()
  local src_bufnr = api.nvim_get_current_buf()
  local uri = buf_uri(src_bufnr)
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
  loaded_bufs[src_bufnr] = true
  decorate_buf(src_bufnr)
  local fpath = buf_fpath(src_bufnr)
  local legend = "<CR>=jump  e=edit  dd=delete  r=refresh  q=close"
  local lines = {
    "Notes for " .. fn.fnamemodify(fpath or "", ":~:."),
    legend,
    "",
  }
  local jump_map = {}   -- row -> { line = N, note = note_obj }
  for _, note in ipairs(notes) do
    local date = (note.modifiedDate or note.createdDate or ""):sub(1, 10)
    lines[#lines + 1] = string.format("L%-4d  [%s @ %s]  %s",
      note.line or 0, note.author or "?", date,
      note.text:gsub("\n", " | "))
    jump_map[#lines] = { line = note.line or 1, note = note }
  end
  vim.cmd("botright new")
  local sbuf = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
  vim.bo[sbuf].filetype = "numscull_list"
  setup_ui_buf(sbuf)

  -- Highlights
  api.nvim_buf_add_highlight(sbuf, -1, "NumscullListHeader", 0, 0, -1)
  api.nvim_buf_add_highlight(sbuf, -1, "NumscullListLegend", 1, 0, -1)
  for i = 3, #lines - 1 do
    local line = lines[i + 1]
    -- Highlight "L<num>" at start
    local id_end = (line:find("%s") or 1)
    api.nvim_buf_add_highlight(sbuf, -1, "NumscullListId", i, 0, id_end)
    -- Highlight "[author @ date]" metadata
    local meta_s, meta_e = line:find("%[.-%]")
    if meta_s then
      api.nvim_buf_add_highlight(sbuf, -1, "NumscullListMeta", i, meta_s - 1, meta_e)
    end
  end

  -- Keymaps
  local kopts = { noremap = true, silent = true }
  api.nvim_buf_set_keymap(sbuf, "n", "<CR>", "", vim.tbl_extend("force", kopts, {
    callback = function()
      local target = jump_map[api.nvim_win_get_cursor(0)[1]]
      if target then
        vim.cmd("wincmd p")
        pcall(api.nvim_win_set_cursor, 0, { target.line, 0 })
      end
    end,
  }))
  api.nvim_buf_set_keymap(sbuf, "n", "e", "", vim.tbl_extend("force", kopts, {
    callback = function()
      local target = jump_map[api.nvim_win_get_cursor(0)[1]]
      if target and target.note then
        vim.cmd("wincmd p")
        pcall(api.nvim_win_set_cursor, 0, { target.line, 0 })
        M.edit_open()
      end
    end,
  }))
  api.nvim_buf_set_keymap(sbuf, "n", "dd", "", vim.tbl_extend("force", kopts, {
    callback = function()
      local target = jump_map[api.nvim_win_get_cursor(0)[1]]
      if target and target.note then
        vim.ui.select({ "Yes", "No" }, {
          prompt = string.format("Delete note '%s'?", target.note.text:sub(1, 40)),
        }, function(choice)
          if choice ~= "Yes" then return end
          local _, del_err = M.remove(uri, target.note.line)
          if del_err then
            vim.notify("[numscull] " .. tostring(del_err), vim.log.levels.ERROR)
            return
          end
          decorate_buf(src_bufnr)
          vim.notify("[numscull] note deleted", vim.log.levels.INFO)
          -- Refresh the list
          pcall(vim.cmd, "bwipeout!")
          M.list()
        end)
      end
    end,
  }))
  api.nvim_buf_set_keymap(sbuf, "n", "r", "", vim.tbl_extend("force", kopts, {
    callback = function()
      pcall(vim.cmd, "bwipeout!")
      M.list()
    end,
  }))
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

-----------------------------------------------------------------------
-- Note Editors
-----------------------------------------------------------------------

--- Helper: extract note text from editor buffer lines (strips # header lines).
local function extract_note_text(buf_lines)
  local text_lines = {}
  for _, l in ipairs(buf_lines) do
    if not l:match("^#") then
      text_lines[#text_lines + 1] = l
    end
  end
  -- Remove leading blank lines from filtered text
  while #text_lines > 0 and text_lines[1] == "" do
    table.remove(text_lines, 1)
  end
  return table.concat(text_lines, "\n")
end

--- Two-pane floating editor (A): code context pane + editable note pane.
--- is_new: if true, this is a new note being created (not an edit)
function M.edit_float(note, source_bufnr, is_new)
  source_bufnr = source_bufnr or api.nvim_get_current_buf()
  is_new = is_new or false
  local ctx = M.config.context_lines
  local note_line = note.line or 1

  -- Get code context from source buffer
  local lc = api.nvim_buf_line_count(source_bufnr)
  local ctx_start = math.max(1, note_line - ctx)
  local ctx_end = math.min(lc, note_line + ctx)
  local ctx_lines = api.nvim_buf_get_lines(source_bufnr, ctx_start - 1, ctx_end, false)

  -- Add line numbers to context
  local numbered_ctx = {}
  for i, line in ipairs(ctx_lines) do
    local lnum = ctx_start + i - 1
    local prefix = (lnum == note_line) and string.format("%4d>", lnum) or string.format("%4d ", lnum)
    numbered_ctx[#numbered_ctx + 1] = prefix .. line
  end

  -- Calculate float dimensions
  local total_width = math.floor(vim.o.columns * (M.config.float_width or 0.8))
  local total_height = math.floor(vim.o.lines * (M.config.float_height or 0.7))
  local border = M.config.float_border or "rounded"
  local vertical = (M.config.split_direction or "vertical") == "vertical"

  local ctx_w, note_w, ctx_h, note_h
  if vertical then
    ctx_w = math.floor(total_width * 0.5)
    note_w = total_width - ctx_w - 3
    ctx_h = total_height
    note_h = total_height
  else
    ctx_w = total_width
    note_w = total_width
    ctx_h = math.floor(total_height * 0.5)
    note_h = total_height - ctx_h - 3
  end

  -- Create context buffer (readonly)
  local ctx_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(ctx_buf, 0, -1, false, numbered_ctx)
  vim.bo[ctx_buf].buftype = "nofile"
  vim.bo[ctx_buf].bufhidden = "wipe"
  vim.bo[ctx_buf].swapfile = false
  vim.bo[ctx_buf].modifiable = false

  -- Create note buffer (editable)
  local note_buf = api.nvim_create_buf(false, true)
  local header = {
    "# Edit note below. Lines starting with # are ignored.",
    "# <leader>s or :w to save, q to close.",
    "",
  }
  local note_text_lines = vim.split(note.text, "\n", { plain = true })
  local full_lines = {}
  for _, h in ipairs(header) do full_lines[#full_lines + 1] = h end
  for _, l in ipairs(note_text_lines) do full_lines[#full_lines + 1] = l end
  api.nvim_buf_set_lines(note_buf, 0, -1, false, full_lines)
  vim.bo[note_buf].buftype = "acwrite"
  vim.bo[note_buf].bufhidden = "wipe"
  vim.bo[note_buf].swapfile = false
  vim.bo[note_buf].filetype = "markdown"

  -- Open floating windows
  local row = math.floor((vim.o.lines - total_height) / 2)
  local col = math.floor((vim.o.columns - total_width) / 2)

  local ctx_win, note_win
  if vertical then
    ctx_win = api.nvim_open_win(ctx_buf, false, {
      relative = "editor", width = ctx_w, height = ctx_h,
      row = row, col = col, style = "minimal", border = border,
      title = " Code Context ", title_pos = "center",
    })
    note_win = api.nvim_open_win(note_buf, true, {
      relative = "editor", width = note_w, height = note_h,
      row = row, col = col + ctx_w + 2, style = "minimal", border = border,
      title = is_new and " Add Note " or " Edit Note ", title_pos = "center",
    })
  else
    ctx_win = api.nvim_open_win(ctx_buf, false, {
      relative = "editor", width = ctx_w, height = ctx_h,
      row = row, col = col, style = "minimal", border = border,
      title = " Code Context ", title_pos = "center",
    })
    note_win = api.nvim_open_win(note_buf, true, {
      relative = "editor", width = note_w, height = note_h,
      row = row + ctx_h + 2, col = col, style = "minimal", border = border,
      title = is_new and " Add Note " or " Edit Note ", title_pos = "center",
    })
  end

  vim.wo[ctx_win].cursorline = false
  vim.wo[note_win].cursorline = true
  -- Scroll context to center on the note line
  local ctx_cursor = math.min(note_line - ctx_start + 1, #numbered_ctx)
  pcall(api.nvim_win_set_cursor, ctx_win, { math.max(ctx_cursor, 1), 0 })
  -- Place cursor after the header in note buffer
  pcall(api.nvim_win_set_cursor, note_win, { #header + 1, 0 })

  local function close_editor()
    if api.nvim_win_is_valid(ctx_win) then api.nvim_win_close(ctx_win, true) end
    if api.nvim_win_is_valid(note_win) then api.nvim_win_close(note_win, true) end
  end

  local function save()
    local all_lines = api.nvim_buf_get_lines(note_buf, 0, -1, false)
    local new_text = extract_note_text(all_lines)
    if new_text == "" then
      vim.notify("[numscull] note text is empty, not saving", vim.log.levels.WARN)
      return
    end
    local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local updated, err = M.set({
      location = note.location,
      text = new_text,
      createdDate = is_new and now or note.createdDate,
      modifiedDate = now,
    })
    if not updated then
      vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    loaded_bufs[source_bufnr] = true
    decorate_buf(source_bufnr)
    vim.notify("[numscull] note saved", vim.log.levels.INFO)
  end

  local kopts = { noremap = true, silent = true }
  api.nvim_buf_set_keymap(note_buf, "n", "<leader>s", "", vim.tbl_extend("force", kopts, { callback = save }))
  api.nvim_buf_set_keymap(note_buf, "n", "q", "", vim.tbl_extend("force", kopts, { callback = close_editor }))
  api.nvim_buf_set_keymap(note_buf, "n", "<Esc>", "", vim.tbl_extend("force", kopts, { callback = close_editor }))

  -- :w saves the note via BufWriteCmd
  api.nvim_create_autocmd("BufWriteCmd", {
    buffer = note_buf,
    callback = function()
      save()
      vim.bo[note_buf].modified = false
    end,
  })
end

--- Single-pane floating editor (B): note text with virt_lines code context.
--- is_new: if true, this is a new note being created (not an edit)
function M.edit_inline(note, source_bufnr, is_new)
  source_bufnr = source_bufnr or api.nvim_get_current_buf()
  is_new = is_new or false
  local ctx = M.config.context_lines
  local note_line = note.line or 1

  -- Get code context from source buffer
  local lc = api.nvim_buf_line_count(source_bufnr)
  local ctx_start = math.max(1, note_line - ctx)
  local ctx_end = math.min(lc, note_line + ctx)
  local ctx_lines_above = api.nvim_buf_get_lines(source_bufnr, ctx_start - 1, note_line, false)
  local ctx_lines_below = api.nvim_buf_get_lines(source_bufnr, note_line, ctx_end, false)

  -- Create note buffer
  local note_buf = api.nvim_create_buf(false, true)
  local header = {
    "# Edit note below. Lines starting with # are ignored.",
    "# <leader>s or :w to save, q to close, gf to jump to source.",
    "",
  }
  local note_text_lines = vim.split(note.text, "\n", { plain = true })
  local full_lines = {}
  for _, h in ipairs(header) do full_lines[#full_lines + 1] = h end
  for _, l in ipairs(note_text_lines) do full_lines[#full_lines + 1] = l end
  api.nvim_buf_set_lines(note_buf, 0, -1, false, full_lines)
  vim.bo[note_buf].buftype = "acwrite"
  vim.bo[note_buf].bufhidden = "wipe"
  vim.bo[note_buf].swapfile = false
  vim.bo[note_buf].filetype = "markdown"

  -- Calculate float dimensions
  local width = math.floor(vim.o.columns * (M.config.float_width or 0.8))
  local height = math.floor(vim.o.lines * (M.config.float_height or 0.7))
  local border = M.config.float_border or "rounded"
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = api.nvim_open_win(note_buf, true, {
    relative = "editor", width = width, height = height,
    row = row, col = col, style = "minimal", border = border,
    title = is_new and " Add Note (inline) " or " Edit Note (inline) ", title_pos = "center",
  })
  vim.wo[win].cursorline = true

  -- Add virt_lines for code context
  local edit_ns = api.nvim_create_namespace("numscull_edit_ctx")

  -- Context above (before the header)
  local virt_above = {}
  for i, line in ipairs(ctx_lines_above) do
    local lnum = ctx_start + i - 1
    virt_above[#virt_above + 1] = { { string.format("# %4d  %s", lnum, line), "NumscullDim" } }
  end
  if #virt_above > 0 then
    api.nvim_buf_set_extmark(note_buf, edit_ns, 0, 0, {
      virt_lines = virt_above,
      virt_lines_above = true,
    })
  end

  -- Context below (after the note content)
  local virt_below = {}
  for i, line in ipairs(ctx_lines_below) do
    local lnum = note_line + i
    virt_below[#virt_below + 1] = { { string.format("# %4d  %s", lnum, line), "NumscullDim" } }
  end
  if #virt_below > 0 then
    local last_line = api.nvim_buf_line_count(note_buf) - 1
    api.nvim_buf_set_extmark(note_buf, edit_ns, last_line, 0, {
      virt_lines = virt_below,
      virt_lines_above = false,
    })
  end

  pcall(api.nvim_win_set_cursor, win, { #header + 1, 0 })

  local function close_editor()
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  end

  local function save()
    local all_lines = api.nvim_buf_get_lines(note_buf, 0, -1, false)
    local new_text = extract_note_text(all_lines)
    if new_text == "" then
      vim.notify("[numscull] note text is empty, not saving", vim.log.levels.WARN)
      return
    end
    local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local updated, err = M.set({
      location = note.location,
      text = new_text,
      createdDate = is_new and now or note.createdDate,
      modifiedDate = now,
    })
    if not updated then
      vim.notify("[numscull] " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    loaded_bufs[source_bufnr] = true
    decorate_buf(source_bufnr)
    vim.notify("[numscull] note saved", vim.log.levels.INFO)
  end

  local function jump_to_source()
    close_editor()
    local path = uri_to_path((note.location.fileId or {}).uri)
    if path then
      vim.cmd("edit " .. fn.fnameescape(path))
      pcall(api.nvim_win_set_cursor, 0, { note_line, 0 })
    end
  end

  local kopts = { noremap = true, silent = true }
  api.nvim_buf_set_keymap(note_buf, "n", "<leader>s", "", vim.tbl_extend("force", kopts, { callback = save }))
  api.nvim_buf_set_keymap(note_buf, "n", "q", "", vim.tbl_extend("force", kopts, { callback = close_editor }))
  api.nvim_buf_set_keymap(note_buf, "n", "<Esc>", "", vim.tbl_extend("force", kopts, { callback = close_editor }))
  api.nvim_buf_set_keymap(note_buf, "n", "gf", "", vim.tbl_extend("force", kopts, { callback = jump_to_source }))

  -- :w saves the note via BufWriteCmd
  api.nvim_create_autocmd("BufWriteCmd", {
    buffer = note_buf,
    callback = function()
      save()
      vim.bo[note_buf].modified = false
    end,
  })
end

--- Open the configured editor for the closest note.
function M.edit_open()
  local bufnr = api.nvim_get_current_buf()
  local note = find_closest_note(bufnr, api.nvim_win_get_cursor(0)[1])
  if not note then
    vim.notify("[numscull] no note near cursor", vim.log.levels.WARN)
    return
  end
  local style = M.config.editor
  if style == "inline" then
    M.edit_inline(note, bufnr)
  else
    M.edit_float(note, bufnr)
  end
end

-----------------------------------------------------------------------
-- Search Results
-----------------------------------------------------------------------

--- Display search results in a scratch buffer with keymaps and quickfix export.
function M.search_results(results, title)
  if not results or #results == 0 then
    vim.notify("[numscull] no results", vim.log.levels.INFO)
    return
  end
  local legend = "<CR>=jump  e=edit  Q=quickfix  q=close"
  local lines = { title or "Search Results", legend, "" }
  local jump_map = {}
  for _, raw_note in ipairs(results) do
    local note = normalize_note(raw_note)
    local path = uri_to_path(note.uri) or "?"
    local rel = fn.fnamemodify(path, ":~:.")
    local date = (note.modifiedDate or note.createdDate or ""):sub(1, 10)
    lines[#lines + 1] = string.format("%s:%d  [%s @ %s]  %s",
      rel, note.line or 0, note.author or "?", date,
      note.text:gsub("\n", " | "))
    jump_map[#lines] = { path = path, line = note.line or 1, note = note }
  end

  vim.cmd("botright new")
  local sbuf = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
  vim.bo[sbuf].filetype = "numscull_search"
  setup_ui_buf(sbuf)

  -- Highlights
  api.nvim_buf_add_highlight(sbuf, -1, "NumscullListHeader", 0, 0, -1)
  api.nvim_buf_add_highlight(sbuf, -1, "NumscullListLegend", 1, 0, -1)
  for i = 3, #lines - 1 do
    local line = lines[i + 1]
    -- Highlight file:line part
    local colon_end = (line:find("%s") or #line)
    api.nvim_buf_add_highlight(sbuf, -1, "NumscullListFile", i, 0, colon_end)
    local meta_s, meta_e = line:find("%[.-%]")
    if meta_s then
      api.nvim_buf_add_highlight(sbuf, -1, "NumscullListMeta", i, meta_s - 1, meta_e)
    end
  end

  local kopts = { noremap = true, silent = true }
  api.nvim_buf_set_keymap(sbuf, "n", "<CR>", "", vim.tbl_extend("force", kopts, {
    callback = function()
      local target = jump_map[api.nvim_win_get_cursor(0)[1]]
      if target then
        vim.cmd("wincmd p")
        if buf_fpath(api.nvim_get_current_buf()) ~= target.path then
          vim.cmd("edit " .. fn.fnameescape(target.path))
        end
        pcall(api.nvim_win_set_cursor, 0, { target.line, 0 })
      end
    end,
  }))
  api.nvim_buf_set_keymap(sbuf, "n", "e", "", vim.tbl_extend("force", kopts, {
    callback = function()
      local target = jump_map[api.nvim_win_get_cursor(0)[1]]
      if target and target.note then
        vim.cmd("wincmd p")
        if buf_fpath(api.nvim_get_current_buf()) ~= target.path then
          vim.cmd("edit " .. fn.fnameescape(target.path))
        end
        pcall(api.nvim_win_set_cursor, 0, { target.line, 0 })
        M.edit_open()
      end
    end,
  }))
  api.nvim_buf_set_keymap(sbuf, "n", "Q", "", vim.tbl_extend("force", kopts, {
    callback = function()
      local qf_list = {}
      for _, target in pairs(jump_map) do
        qf_list[#qf_list + 1] = {
          filename = target.path,
          lnum = target.line,
          text = target.note.text:gsub("\n", " | "),
        }
      end
      fn.setqflist(qf_list, "r")
      vim.cmd("copen")
      vim.notify(string.format("[numscull] %d results sent to quickfix", #qf_list), vim.log.levels.INFO)
    end,
  }))
end

-----------------------------------------------------------------------
-- "Here" variants and enhanced add/edit
-----------------------------------------------------------------------

--- Add a note here (at cursor) with immediate editor and template support.
--- Opens editor immediately with template pre-filled (no intermediate prompt).
function M.add_here()
  local bufnr = api.nvim_get_current_buf()
  local uri = buf_uri(bufnr)
  if not uri then
    vim.notify("[numscull] buffer has no file", vim.log.levels.WARN)
    return
  end
  local line = api.nvim_win_get_cursor(0)[1]
  
  -- Prepare template
  local template = M.config.note_template or ""
  
  -- Create temporary note for editing
  local temp_note = {
    location = { fileId = { uri = uri }, line = line },
    text = template,
    author = "?",
    createdDate = "",
    modifiedDate = "",
  }
  
  -- Open editor directly
  local style = M.config.editor
  if style == "inline" then
    M.edit_inline(temp_note, bufnr, true) -- Pass true to indicate new note
  else
    M.edit_float(temp_note, bufnr, true) -- Pass true to indicate new note
  end
end

--- Edit note here (at cursor) - finds closest note and opens editor.
function M.edit_here()
  M.edit_open()
end

--- Setup buffer-local mappings for quick note add/edit.
local function setup_buffer_mappings(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  
  -- Only set up mappings if buffer has a file
  if not buf_uri(bufnr) then return end
  
  local opts = { buffer = bufnr, silent = true, noremap = true }
  
  if M.config.mappings and M.config.mappings.note_add then
    vim.keymap.set('n', M.config.mappings.note_add, function()
      M.add_here()
    end, vim.tbl_extend('force', opts, { desc = 'Add note here' }))
  end
  
  if M.config.mappings and M.config.mappings.note_edit then
    vim.keymap.set('n', M.config.mappings.note_edit, function()
      M.edit_here()
    end, vim.tbl_extend('force', opts, { desc = 'Edit note here' }))
  end
  
  -- Flow mappings (if flow module is available)
  if M.config.mappings and M.config.mappings.flow_add_node_here then
    local flow = require('numscull.flow')
    vim.keymap.set('n', M.config.mappings.flow_add_node_here, function()
      flow.add_node_here()
    end, vim.tbl_extend('force', opts, { desc = 'Add flow node here' }))
  end
  
  if M.config.mappings and M.config.mappings.flow_select then
    local flow = require('numscull.flow')
    vim.keymap.set('n', M.config.mappings.flow_select, function()
      flow.select()
    end, vim.tbl_extend('force', opts, { desc = 'Select flow' }))
  end
end

--- Expose setup_buffer_mappings
M.setup_buffer_mappings = setup_buffer_mappings

--- Configure (icon, max_line_len, editor, etc.).
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  hl_setup()
  
  -- Setup buffer mappings on BufEnter if any mapping is configured
  local has_mappings = M.config.mappings and (
    M.config.mappings.note_add or 
    M.config.mappings.note_edit or
    M.config.mappings.flow_add_node_here or
    M.config.mappings.flow_select
  )
  
  if has_mappings then
    local grp = api.nvim_create_augroup("NumscullMappings", { clear = true })
    api.nvim_create_autocmd("BufEnter", {
      group = grp,
      callback = function(ev)
        setup_buffer_mappings(ev.buf)
      end,
    })
  end
end

return M
