-- Panel listing all saved connections, grouped by driver.
-- Keymaps: <CR> expand/collapse group or connect, d delete, n new, R refresh, q close.
local M = {}

local Buffer      = require("dbelveder.buffer")
local connections = require("dbelveder.connections")
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
  conn_errors = {},  -- [name]    -> bool
  conn_loading = {}, -- [name]    -> { frame, timer }
}

local function build(conns, active_set)
  local by_driver, driver_order = {}, {}
  for name, params in pairs(conns) do
    local d = params.driver or "unknown"
    if not by_driver[d] then
      by_driver[d] = {}
      table.insert(driver_order, d)
    end
    table.insert(by_driver[d], name)
  end
  table.sort(driver_order)
  for _, names in pairs(by_driver) do table.sort(names) end

  local lines, line_map, hl_rules = {}, {}, {}

  for _, driver in ipairs(driver_order) do
    local names    = by_driver[driver]
    local expanded = state.expanded[driver]
    local chevron  = expanded and "▾ " or "▸ "
    local count    = " (" .. #names .. ")"
    table.insert(lines, chevron .. driver .. count)
    table.insert(line_map, { type = "header", driver = driver })
    hl_rules[#lines] = "DbelvederHeaderRow"

    if expanded then
      for _, name in ipairs(names) do
        local active   = active_set[name]
        local loading  = state.conn_loading[name]
        local has_err  = state.conn_errors[name]
        local mark
        if active then
          mark = ACTIVE_MARK
        elseif loading then
          mark = " " .. SPINNER_FRAMES[loading.frame]
        elseif has_err then
          mark = ERROR_MARK
        else
          mark = ""
        end
        table.insert(lines, "    " .. name .. mark)
        table.insert(line_map, { type = "conn", name = name, driver = driver })
        if active then
          hl_rules[#lines] = "DbelvederConnection"
        elseif has_err then
          hl_rules[#lines] = "DbelvederConnError"
        end
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
    state.expanded[entry.driver] = not state.expanded[entry.driver]
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

local function on_new()
  connections.create(function(name, params)
    if not name then return end
    local db = require("dbelveder")
    db._do_connect(name, params)
    refresh()
  end)
end


function M.open()
  if not (state.buffer and state.buffer:is_valid()) then
    state.buffer = Buffer:new(BUFNAME, "dbelveder_connections", false, "nofile")
    state.buffer:set_keymap("n", "<CR>", on_enter,  { nowait = true, silent = true, desc = "Expand/collapse or connect" })
    state.buffer:set_keymap("n", "d",    on_delete, { nowait = true, silent = true, desc = "Delete connection" })
    state.buffer:set_keymap("n", "n",    on_new,    { nowait = true, silent = true, desc = "New connection" })
    state.buffer:set_keymap("n", "R",    refresh,   { nowait = true, silent = true, desc = "Refresh" })
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

  local prev_win = vim.api.nvim_get_current_win()
  vim.cmd("botright 35vsplit")
  vim.api.nvim_win_set_buf(0, state.buffer.buf_id)
  vim.api.nvim_set_option_value("number",     false,   { win = 0 })
  vim.api.nvim_set_option_value("signcolumn", "no",    { win = 0 })
  vim.api.nvim_set_option_value("fillchars",  "eob: ", { win = 0 })
  vim.api.nvim_set_current_win(prev_win)

  refresh()
end

function M.refresh()
  if state.buffer and state.buffer:is_valid() then
    refresh()
  end
end

function M.set_conn_error(name)
  state.conn_errors[name] = true
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
