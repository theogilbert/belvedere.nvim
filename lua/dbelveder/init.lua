local M = {}

local client      = require("dbelveder.client")
local config      = require("dbelveder.config")
local hl          = require("dbelveder.hl")
local connections = require("dbelveder.connections")
local results          = require("dbelveder.ui.results")
local explorer         = require("dbelveder.ui.explorer")
local connections_panel = require("dbelveder.ui.connections")
local selection   = require("dbelveder.selection")

-- Active connections: { [name] = { conn_id, driver } }
-- buf_conns:  per-buffer active connection { [bufnr] = name }
-- win_labels: label float per window       { [winid] = fwinid }
local state = {
  conns      = {},
  buf_conns  = {},
  win_labels = {},
}


local function close_win_label(winid)
  local fwin = state.win_labels[winid]
  if fwin and vim.api.nvim_win_is_valid(fwin) then
    vim.api.nvim_win_close(fwin, true)
  end
  state.win_labels[winid] = nil
end

local function open_win_label(winid, name)
  close_win_label(winid)
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = fbuf })
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "Connected to " .. name })
  vim.api.nvim_buf_add_highlight(fbuf, -1, "DbelvederConnection", 0, 0, -1)
  local height = vim.api.nvim_win_get_height(winid)
  local width  = vim.api.nvim_win_get_width(winid)
  local fwin = vim.api.nvim_open_win(fbuf, false, {
    relative  = "win",
    win       = winid,
    row       = height - 1,
    col       = 0,
    width     = width,
    height    = 1,
    style     = "minimal",
    focusable = false,
    zindex    = 10,
  })
  vim.api.nvim_set_option_value("winhl", "Normal:Normal,NormalFloat:Normal", { win = fwin })
  state.win_labels[winid] = fwin
end

-- Reposition an existing label float after the parent window is resized.
local function reposition_win_label(winid)
  local fwin = state.win_labels[winid]
  if not (fwin and vim.api.nvim_win_is_valid(fwin)) then return end
  local height = vim.api.nvim_win_get_height(winid)
  local width  = vim.api.nvim_win_get_width(winid)
  vim.api.nvim_win_set_config(fwin, {
    relative = "win",
    win      = winid,
    row      = height - 1,
    col      = 0,
    width    = width,
    height   = 1,
  })
end

-- Show, update, or remove the label for a given window based on its buffer.
local function refresh_win_label(winid)
  if not vim.api.nvim_win_is_valid(winid) then return end
  -- Skip our own label floats (focusable=false but guard anyway).
  if vim.api.nvim_win_get_config(winid).relative ~= "" then return end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local name  = state.buf_conns[bufnr]
  if name then
    if state.win_labels[winid] then
      reposition_win_label(winid)
    else
      open_win_label(winid, name)
    end
  else
    close_win_label(winid)
  end
end

local function set_buf_conn(bufnr, name)
  state.buf_conns[bufnr] = name
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if name then
      open_win_label(winid, name)
    else
      close_win_label(winid)
    end
  end
end

function M.setup(opts)
  config.setup(opts)
  hl.setup()
  local aug = vim.api.nvim_create_augroup("DbelvederConnLabels", { clear = true })
  -- Show or hide the label whenever the buffer in a window changes.
  vim.api.nvim_create_autocmd("BufEnter", {
    group    = aug,
    callback = function() refresh_win_label(vim.api.nvim_get_current_win()) end,
  })
  -- Reposition all labels when any window is resized.
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group    = aug,
    callback = function()
      for winid in pairs(state.win_labels) do
        reposition_win_label(winid)
      end
    end,
  })
  -- Clean up the label entry when a window closes.
  vim.api.nvim_create_autocmd("WinClosed", {
    group    = aug,
    callback = function(ev) close_win_label(tonumber(ev.match)) end,
  })
end


function M.connect()
  connections.pick(function(name, params)
    if not name then return end
    M._do_connect(name, params)
  end)
end

function M.connect_by_name(name)
  local params = connections.get(name)
  if not params then
    vim.notify(("dbelveder: connection %q not found"):format(name), vim.log.levels.ERROR)
    return
  end
  connections.prompt_password(params, function(params_with_pw)
    if not params_with_pw then return end
    M._do_connect(name, params_with_pw)
  end)
end

function M._do_connect(name, params)
  local bufnr = vim.api.nvim_get_current_buf()  -- capture before async
  if not client.is_running() then
    local ok, err = pcall(client.start, config.options.python_cmd)
    if not ok then
      vim.notify("dbelveder: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    connections_panel.set_conn_loading(name)
    vim.defer_fn(function() M._send_connect(name, params, bufnr) end, 200)
  else
    connections_panel.set_conn_loading(name)
    M._send_connect(name, params, bufnr)
  end
end

function M._send_connect(name, params, bufnr)
  client.request("connect", params, function(err, result)
    connections_panel.clear_conn_loading(name)
    if err then
      vim.notify("dbelveder: " .. err, vim.log.levels.ERROR)
      connections_panel.set_conn_error(name, err)
      return
    end
    state.conns[name] = { conn_id = result.connection_id, driver = params.driver }
    set_buf_conn(bufnr, name)
    vim.notify(("dbelveder: connected to %q (%s)"):format(name, params.driver), vim.log.levels.INFO)
    connections_panel.refresh()
  end)
end

-- Associate an already-open connection to the current buffer.
function M.use(name)
  if not state.conns[name] then
    vim.notify(("dbelveder: not connected to %q"):format(name), vim.log.levels.ERROR)
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if state.buf_conns[bufnr] == name then return end  -- no-op
  set_buf_conn(bufnr, name)
  vim.notify(("dbelveder: active connection: %q"):format(name), vim.log.levels.INFO)
end

function M.disconnect(name)
  name = name ~= "" and name or state.buf_conns[vim.api.nvim_get_current_buf()]
  if not name then
    vim.notify("dbelveder: no active connection", vim.log.levels.WARN)
    return
  end
  local conn = state.conns[name]
  if not conn then
    vim.notify(("dbelveder: not connected to %q"):format(name), vim.log.levels.ERROR)
    return
  end
  client.request("disconnect", { connection_id = conn.conn_id }, function(err, _)
    if err then
      vim.notify("dbelveder: " .. err, vim.log.levels.ERROR)
      return
    end
    state.conns[name] = nil
    -- Clear the label from every buffer that was using this connection.
    for bufnr, conn_name in pairs(state.buf_conns) do
      if conn_name == name then
        set_buf_conn(bufnr, nil)
      end
    end
    vim.notify(("dbelveder: disconnected from %q"):format(name), vim.log.levels.INFO)
    connections_panel.refresh()
  end)
end

-- Return the names of all currently-open connections (for tab completion).
function M.active_names()
  local names = vim.tbl_keys(state.conns)
  table.sort(names)
  return names
end


function M.execute(sql)
  if not sql or sql == "" then
    vim.notify("dbelveder: no SQL to execute", vim.log.levels.WARN)
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local conn = state.buf_conns[bufnr] and state.conns[state.buf_conns[bufnr]]
  if not conn then
    vim.notify("dbelveder: no active connection — run :DbConnect first", vim.log.levels.WARN)
    return
  end
  results.show_message("Executing…")
  client.request(
    "execute",
    { connection_id = conn.conn_id, sql = sql, params = {} },
    function(err, result)
      vim.schedule(function()
        if err then
          results.show_error(err)
        else
          results.show_results(result.columns or {}, result.rows or {})
        end
      end)
    end,
    function(progress)
      vim.schedule(function()
        results.show_message(progress.message or progress.status or "…")
      end)
    end)
end

function M.execute_range(line1, line2)
  local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  M.execute(table.concat(lines, "\n"))
end

function M.execute_selection()
  if not selection.is_in_visual_mode() then
    vim.notify("dbelveder: must be in visual mode to run execute_selection()", vim.log.levels.WARN)
    return
  end

  local sql = selection.get_selection()
  if sql == "" then
    vim.notify("dbelveder: no selection — visually select a query first", vim.log.levels.WARN)
    return
  end
  M.execute(sql)
end

function M.open_connections()
  connections_panel.open()
end


function M.open_explorer()
  local bufnr = vim.api.nvim_get_current_buf()
  local conn = state.buf_conns[bufnr] and state.conns[state.buf_conns[bufnr]]
  if not conn then
    vim.notify("dbelveder: no active connection — run :DbConnect first", vim.log.levels.WARN)
    return
  end
  explorer.open(conn.conn_id)
end

function M.stop()
  client.stop()
  state.conns = {}
  for winid in pairs(state.win_labels) do
    close_win_label(winid)
  end
  state.win_labels = {}
  state.buf_conns  = {}
  explorer.reset()
  vim.notify("dbelveder: backend stopped", vim.log.levels.INFO)
end

return M
