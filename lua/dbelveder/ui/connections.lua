-- Panel listing all saved connections, grouped by driver.
-- Keymaps: <CR> expand/collapse group or connect, d delete, n new, R refresh, q close.
local M = {}

local Buffer      = require("dbelveder.buffer")
local connections = require("dbelveder.connections")
local config      = require("dbelveder.config")
local hl          = require("dbelveder.hl")

local BUFNAME          = "dbelveder://connections"
local ACTIVE_MARK      = " ✓"
local ERROR_MARK       = " ✗"
local SPINNER_FRAMES   = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_INTERVAL = 80  -- ms

local state = {
  buffer      = nil,
  line_map    = {},  -- [line_nr] -> { type="header"|"conn", driver, name? }
  expanded    = {},  -- [driver]  -> bool (default false = folded)
  conn_errors = {},  -- [name]    -> string (error message)
  conn_loading = {}, -- [name]    -> { frame, timer }
  hover_win    = nil,
}

local function build(conns, active_set)
  -- Determine whether saved connections span multiple servers.
  local server_set = {}
  for _, p in pairs(conns) do server_set[p.server or ""] = true end
  local multi_server = vim.tbl_count(server_set) > 1

  -- Group by {driver, server}.  Key uses NUL as separator (never in names).
  local groups, group_order = {}, {}
  for name, params in pairs(conns) do
    local driver = params.driver or "unknown"
    local server = params.server
    local gkey   = driver .. (server and ("\0" .. server) or "")
    local label  = driver .. (multi_server and server and (" (" .. server .. ")") or "")
    if not groups[gkey] then
      groups[gkey] = { label = label, names = {} }
      table.insert(group_order, gkey)
    end
    table.insert(groups[gkey].names, name)
  end
  table.sort(group_order)
  for _, gkey in ipairs(group_order) do table.sort(groups[gkey].names) end

  local lines, line_map, hl_rules = {}, {}, {}

  for _, gkey in ipairs(group_order) do
    local g        = groups[gkey]
    local expanded = state.expanded[gkey]
    local chevron  = expanded and "▾ " or "▸ "
    table.insert(lines, chevron .. g.label .. " (" .. #g.names .. ")")
    table.insert(line_map, { type = "header", gkey = gkey })
    hl_rules[#lines] = "DbelvederHeaderRow"

    if expanded then
      for _, name in ipairs(g.names) do
        local active  = active_set[name]
        local loading = state.conn_loading[name]
        local has_err = state.conn_errors[name]
        local mark
        if active then mark = ACTIVE_MARK
        elseif loading then mark = " " .. SPINNER_FRAMES[loading.frame]
        elseif has_err then mark = ERROR_MARK
        else mark = "" end
        table.insert(lines, "    " .. name .. mark)
        table.insert(line_map, { type = "conn", name = name })
        if active then hl_rules[#lines] = "DbelvederConnection"
        elseif has_err then hl_rules[#lines] = "DbelvederConnError" end
      end
    end
  end

  return lines, line_map, hl_rules
end

local function refresh()
  local db = require("dbelveder")  -- lazy: avoids circular dependency
  local active_set = {}
  for _, n in ipairs(db.active_names()) do active_set[n] = true end

  local conns = connections.load()
  local lines, line_map, hl_rules = build(conns, active_set)
  state.line_map = line_map

  if #lines == 0 then
    state.buffer:set_content({ "(no saved connections)" })
    return
  end

  state.buffer:set_content(lines)

  local rules = {}
  for lnum, group in pairs(hl_rules) do
    table.insert(rules, {
      higroup = group,
      start   = { lnum - 1, 0 },
      finish  = { lnum - 1, -1 },
    })
  end
  state.buffer:apply_highlight(rules)
end


local function entry_at_cursor()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return state.line_map[line]
end

local function on_enter()
  local entry = entry_at_cursor()
  if not entry then return end
  if entry.type == "header" then
    state.expanded[entry.gkey] = not state.expanded[entry.gkey]
    refresh()
  else
    state.conn_errors[entry.name] = nil
    local db = require("dbelveder")
    db.connect_by_name(entry.name)
  end
end

local function on_delete()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  connections.delete(entry.name)
  refresh()
end

local function on_disconnect()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  local db = require("dbelveder")
  db.disconnect(entry.name)
end

local function on_new()
  local db = require("dbelveder")
  db.ensure_backend_with_caps(function(caps)
    connections.create(caps, function(name, params)
      if not name then return end
      db._do_connect(name, params)
      refresh()
    end)
  end)
end

local function on_explore()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  local db = require("dbelveder")
  db.open_explorer_for(entry.name)
end

local function on_hover()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  local msg = state.conn_errors[entry.name]
  if not msg then return end

  -- Second K: enter the existing float so the user can read/scroll.
  if state.hover_win and vim.api.nvim_win_is_valid(state.hover_win) then
    pcall(vim.api.nvim_del_augroup_by_name, "DbelvederHoverFloat")
    local fwin    = state.hover_win
    local fbuf    = vim.api.nvim_win_get_buf(fwin)
    local prev    = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_config(fwin, { focusable = true })
    vim.api.nvim_set_current_win(fwin)
    for _, key in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", key, function()
        pcall(vim.api.nvim_win_close, fwin, true)
        state.hover_win = nil
        if vim.api.nvim_win_is_valid(prev) then
          vim.api.nvim_set_current_win(prev)
        end
      end, { buffer = fbuf, silent = true, nowait = true })
    end
    return
  end

  -- First K: open a tooltip float.
  local lines = vim.split(msg, "\n", { plain = true })
  local max_w = 1
  for _, l in ipairs(lines) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end
  local win_w = math.min(max_w, vim.o.columns - 6)

  -- Height: sum of rows each line occupies under character-wrap.
  local height = 0
  for _, l in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(l)
    height = height + (w == 0 and 1 or math.ceil(w / win_w))
  end

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].bufhidden  = "wipe"
  for i = 0, #lines - 1 do
    vim.api.nvim_buf_add_highlight(fbuf, -1, "DbelvederConnError", i, 0, -1)
  end

  local fwin = vim.api.nvim_open_win(fbuf, false, {
    relative  = "cursor",
    row       = 1,
    col       = 0,
    width     = win_w,
    height    = height,
    style     = "minimal",
    border    = "rounded",
    title     = " error ",
    title_pos = "center",
    focusable = false,
  })
  vim.api.nvim_set_option_value("winhl", "FloatBorder:DbelvederConnError", { win = fwin })
  vim.api.nvim_set_option_value("wrap",  true, { win = fwin })

  state.hover_win = fwin

  vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
    group    = vim.api.nvim_create_augroup("DbelvederHoverFloat", { clear = true }),
    buffer   = state.buffer.buf_id,
    once     = true,
    callback = function()
      pcall(vim.api.nvim_win_close, state.hover_win, true)
      state.hover_win = nil
    end,
  })
end


function M.open()
  if not (state.buffer and state.buffer:is_valid()) then
    state.buffer = Buffer:new(BUFNAME, "dbelveder_connections", false, "nofile")
    local hover_key = config.options.keymaps.hover_key
    state.buffer:set_keymap("n", "<CR>",     on_enter,      { nowait = true, silent = true, desc = "Expand/collapse or connect" })
    state.buffer:set_keymap("n", "e",        on_explore,    { nowait = true, silent = true, desc = "Open explorer" })
    state.buffer:set_keymap("n", "x",        on_disconnect, { nowait = true, silent = true, desc = "Disconnect" })
    state.buffer:set_keymap("n", "d",        on_delete,     { nowait = true, silent = true, desc = "Delete connection" })
    state.buffer:set_keymap("n", "n",        on_new,        { nowait = true, silent = true, desc = "New connection" })
    state.buffer:set_keymap("n", "R",        refresh,       { nowait = true, silent = true, desc = "Refresh" })
    state.buffer:set_keymap("n", hover_key,  on_hover,      { nowait = true, silent = true, desc = "Show error details" })
    state.buffer:set_keymap("n", "q", function()
      local win = vim.fn.bufwinid(state.buffer.buf_id)
      if win ~= -1 then vim.api.nvim_win_close(win, true) end
    end, { nowait = true, silent = true, desc = "Close panel" })
  end

  local win = vim.fn.bufwinid(state.buffer.buf_id)
  if win ~= -1 then
    vim.api.nvim_win_close(win, true)
    return
  end

  vim.cmd("botright 35vsplit")
  vim.api.nvim_win_set_buf(0, state.buffer.buf_id)
  vim.api.nvim_set_option_value("number",     false,   { win = 0 })
  vim.api.nvim_set_option_value("signcolumn", "no",    { win = 0 })
  vim.api.nvim_set_option_value("fillchars",  "eob: ", { win = 0 })

  refresh()
end

function M.refresh()
  if state.buffer and state.buffer:is_valid() then
    refresh()
  end
end

function M.set_conn_error(name, msg)
  state.conn_errors[name] = msg or "unknown error"
  M.refresh()
end

function M.clear_conn_loading(name)
  local entry = state.conn_loading[name]
  if not entry then return end
  state.conn_loading[name] = nil
  if entry.timer then
    entry.timer:stop()
    entry.timer:close()
  end
end

function M.set_conn_loading(name)
  M.clear_conn_loading(name)
  local entry = { frame = 1 }
  local timer = vim.uv.new_timer()
  entry.timer = timer
  state.conn_loading[name] = entry
  timer:start(0, SPINNER_INTERVAL, vim.schedule_wrap(function()
    local e = state.conn_loading[name]
    if not e then return end
    e.frame = (e.frame % #SPINNER_FRAMES) + 1
    M.refresh()
  end))
end

return M
