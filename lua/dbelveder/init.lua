local M = {}

local client            = require("dbelveder.client")
local config            = require("dbelveder.config")
local hl                = require("dbelveder.hl")
local connections       = require("dbelveder.connections")
local executor          = require("dbelveder.executor")
local explorer          = require("dbelveder.ui.explorer")
local conn_label        = require("dbelveder.ui.conn_label")
local connections_panel = require("dbelveder.ui.connections")
local selection         = require("dbelveder.selection")

-- Session state.
--   conns:     connections opened this session  { [name]  = { conn_id, driver } }
--   buf_conns: connection each buffer queries    { [bufnr] = name }
local state = {
  conns     = {},
  buf_conns = {},
}

-- Associate (or, with name=nil, dissociate) a buffer and update its window labels.
local function set_buf_conn(bufnr, name)
  state.buf_conns[bufnr] = name
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if name then conn_label.show(winid, name) else conn_label.hide(winid) end
  end
end

function M.setup(opts)
  config.setup(opts)
  hl.setup()
  conn_label.setup(function(bufnr) return state.buf_conns[bufnr] end)

  local key = config.options.keymaps.execute
  if key and key ~= "" then
    vim.keymap.set("n", key, M.execute,
      { desc = "Execute current line", silent = true })
    vim.keymap.set("x", key, function()
      -- Exit visual mode first so getpos("v") is still valid.
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      M.execute()
    end, { desc = "Execute selection", silent = true })
  end
end


-- A freshly-spawned backend needs a moment before it can answer requests.
local STARTUP_DELAY_MS = 200

-- Start the backend if it isn't already running.
-- Returns (ok, fresh): ok=false means it failed; fresh=true means we just started it.
local function start_backend()
  if client.is_running() then return true, false end
  local ok, err = pcall(client.start, config.options.python_cmd)
  if not ok then
    vim.notify("dbelveder: " .. tostring(err), vim.log.levels.ERROR)
    return false, false
  end
  return true, true
end

-- Start the backend if needed, then deliver capabilities to `callback`.
-- Returns false if the backend could not be started.
function M.ensure_backend_with_caps(callback)
  local ok, fresh = start_backend()
  if not ok then return false end
  if fresh then
    vim.defer_fn(function() client.ensure_capabilities(callback) end, STARTUP_DELAY_MS)
  else
    client.ensure_capabilities(callback)
  end
  return true
end

function M.connect()
  M.ensure_backend_with_caps(function(caps)
    connections.pick(caps, function(name, params)
      if not name then return end
      M._do_connect(name, params)
    end)
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
  connections_panel.set_conn_loading(name)
  local ok = M.ensure_backend_with_caps(function()
    M._send_connect(name, params)
  end)
  if not ok then connections_panel.clear_conn_loading(name) end
end

-- Fields stored in the connections file that must not be forwarded to the server.
local CLIENT_ONLY_FIELDS = { server = true, requires_password = true }

function M._send_connect(name, params)
  local server_params = {}
  for k, v in pairs(params) do
    if not CLIENT_ONLY_FIELDS[k] then server_params[k] = v end
  end
  client.request("connect", server_params, function(err, result)
    connections_panel.clear_conn_loading(name)
    if err then
      vim.notify("dbelveder: " .. err, vim.log.levels.ERROR)
      connections_panel.set_conn_error(name, err)
      return
    end
    state.conns[name] = { conn_id = result.connection_id, driver = params.driver }
    vim.notify(("dbelveder: connected to %q (%s)"):format(name, params.driver), vim.log.levels.INFO)
    connections_panel.refresh()
  end)
end

function M.associate()
  local names = M.active_names()
  if #names == 0 then
    vim.notify("dbelveder: no open connections — open the connection panel with :DbConnections", vim.log.levels.WARN)
    return
  end
  vim.ui.select(names, { prompt = "Associate connection:" }, function(name)
    if not name then return end
    set_buf_conn(vim.api.nvim_get_current_buf(), name)
    vim.notify(("dbelveder: buffer associated with %q"):format(name), vim.log.levels.INFO)
  end)
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
      if conn_name == name then set_buf_conn(bufnr, nil) end
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


-- Resolve the connection associated with `bufnr`, or nil.
local function conn_for_buf(bufnr)
  local name = state.buf_conns[bufnr]
  return name and state.conns[name]
end

local function execute_sql(sql)
  if not sql or sql == "" then
    vim.notify("dbelveder: no SQL to execute", vim.log.levels.WARN)
    return
  end
  local conn = conn_for_buf(vim.api.nvim_get_current_buf())
  if not conn then
    vim.notify("dbelveder: no active connection — run :DbAssociate first", vim.log.levels.WARN)
    return
  end
  executor.run(conn, sql)
end

function M.execute_range(line1, line2)
  local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  execute_sql(table.concat(lines, "\n"))
end

function M.execute()
  local sql
  if selection.is_in_visual_mode() then
    sql = selection.get_selection()
    if not sql or sql == "" then
      vim.notify("dbelveder: empty selection", vim.log.levels.WARN)
      return
    end
  else
    sql = vim.api.nvim_get_current_line()
    if vim.trim(sql) == "" then
      vim.notify("dbelveder: current line is empty", vim.log.levels.WARN)
      return
    end
  end
  execute_sql(sql)
end

function M.open_connections()
  connections_panel.open()
end

function M.open_explorer_for(name)
  local conn = state.conns[name]
  if not conn then
    vim.notify(("dbelveder: not connected to %q — press <CR> to connect first"):format(name), vim.log.levels.ERROR)
    return
  end
  explorer.open(conn.conn_id, name, conn.driver)
end

function M.open_explorer()
  -- The current buffer's connection, or else any open connection.
  local name = state.buf_conns[vim.api.nvim_get_current_buf()] or next(state.conns)
  local conn = name and state.conns[name]
  if not conn then
    vim.notify("dbelveder: no active connection — run :DbConnect first", vim.log.levels.WARN)
    return
  end
  explorer.open(conn.conn_id, name, conn.driver)
end

function M.stop()
  client.stop()  -- also resets capabilities cache
  state.conns     = {}
  state.buf_conns = {}
  conn_label.clear_all()
  explorer.reset()
  vim.notify("dbelveder: backend stopped", vim.log.levels.INFO)
end

return M
