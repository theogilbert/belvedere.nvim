local M = {}

local client            = require("belvedere.client")
local config            = require("belvedere.config")
local hl                = require("belvedere.hl")
local connections       = require("belvedere.connections")
local executor          = require("belvedere.executor")
local explorer          = require("belvedere.ui.explorer")
local conn_label        = require("belvedere.ui.conn_label")
local connections_panel = require("belvedere.ui.connections")
local selection         = require("belvedere.selection")

-- Session state.
--   conns:     connections opened this session  { [name]  = { conn_id, driver } }
--   buf_conns: connection each buffer queries    { [bufnr] = name }
local state = {
  conns     = {},
  buf_conns = {},
}

-- Resolve the connection associated with `bufnr`, or nil.
local function conn_for_buf(bufnr)
  local name = state.buf_conns[bufnr]
  return name and state.conns[name]
end

-- Compute the display label for a connection: "name (driver)".
local function conn_display_label(name)
  local conn = state.conns[name]
  return (conn and conn.driver) and (name .. " (" .. conn.driver .. ")") or name
end

-- Associate (or, with name=nil, dissociate) a buffer and update its window labels.
local function set_buf_conn(bufnr, name)
  state.buf_conns[bufnr] = name
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if name then conn_label.show(winid, conn_display_label(name)) else conn_label.hide(winid) end
  end
end

function M.setup(opts)
  config.setup(opts)
  hl.setup()
  conn_label.setup(function(bufnr)
    local name = state.buf_conns[bufnr]
    return name and conn_display_label(name)
  end)

end


-- Start the backend if it isn't already running.
-- Returns false (and notifies) if the process could not be spawned.
local function start_backend()
  if client.is_running() then return true end
  local ok, err = pcall(client.start, config.options.python_cmd)
  if not ok then
    vim.notify("belvedere: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

-- Start the backend if needed, then deliver capabilities to `callback`.
-- Returns false if the backend could not be started.
function M.ensure_backend_with_caps(callback)
  if not start_backend() then return false end
  client.ensure_capabilities(callback)
  return true
end

function M.connect(name)
  local bufnr = vim.api.nvim_get_current_buf()
  local auto_assign = vim.bo[bufnr].buftype == ""

  local function after_connect(conn_name)
    if auto_assign and vim.api.nvim_buf_is_valid(bufnr) then
      set_buf_conn(bufnr, conn_name)
    end
  end

  if name and name ~= "" then
    local params = connections.get(name)
    if not params then
      vim.notify(("belvedere: connection %q not found"):format(name), vim.log.levels.ERROR)
      return
    end
    connections.prompt_password(params, function(params_with_pw)
      if not params_with_pw then return end
      M._do_connect(name, params_with_pw, after_connect)
    end)
  else
    M.ensure_backend_with_caps(function(caps)
      local active_set = {}
      for _, n in ipairs(M.active_names()) do active_set[n] = true end
      connections.pick(caps, active_set, function(picked_name, params)
        if not picked_name then return end
        M._do_connect(picked_name, params, after_connect)
      end)
    end)
  end
end

function M._do_connect(name, params, after_connect)
  connections_panel.set_conn_loading(name)
  local ok = M.ensure_backend_with_caps(function()
    M._send_connect(name, params, after_connect)
  end)
  if not ok then connections_panel.clear_conn_loading(name) end
end

-- Fields stored in the connections file that must not be forwarded to the server.
local CLIENT_ONLY_FIELDS = { server = true, requires_password = true, driver_label = true }

function M._send_connect(name, params, after_connect)
  local server_params = {}
  for k, v in pairs(params) do
    if not CLIENT_ONLY_FIELDS[k] then server_params[k] = v end
  end
  client.request("connect", server_params, function(err, result)
    connections_panel.clear_conn_loading(name)
    if err then
      vim.notify("belvedere: " .. err, vim.log.levels.ERROR)
      connections_panel.set_conn_error(name, err)
      return
    end
    state.conns[name] = { conn_id = result.connection_id, driver = params.driver, name = name, driver_label = params.driver_label }
    vim.notify(("belvedere: connected to %q (%s)"):format(name, params.driver), vim.log.levels.INFO)
    connections_panel.refresh()
    if after_connect then after_connect(name) end
  end)
end

function M.associate()
  local names = M.active_names()
  if #names == 0 then
    vim.notify("belvedere: no open connections — open the connection panel with :DbConnections", vim.log.levels.WARN)
    return
  end
  vim.ui.select(names, {
    prompt      = "Associate connection:",
    format_item = function(name)
      local conn  = state.conns[name]
      local label = conn and conn.driver_label
      return label and (name .. " (" .. label .. ")") or name
    end,
  }, function(name)
    if not name then return end
    set_buf_conn(vim.api.nvim_get_current_buf(), name)
    vim.notify(("belvedere: buffer associated with %q"):format(name), vim.log.levels.INFO)
  end)
end

function M.disconnect(name)
  name = name ~= "" and name or state.buf_conns[vim.api.nvim_get_current_buf()]
  if not name then
    vim.notify("belvedere: no active connection", vim.log.levels.WARN)
    return
  end
  local conn = state.conns[name]
  if not conn then
    vim.notify(("belvedere: not connected to %q"):format(name), vim.log.levels.ERROR)
    return
  end
  client.request("disconnect", { connection_id = conn.conn_id }, function(err, _)
    if err then
      vim.notify("belvedere: " .. err, vim.log.levels.ERROR)
      return
    end
    state.conns[name] = nil
    -- Clear the label from every buffer that was using this connection.
    for bufnr, conn_name in pairs(state.buf_conns) do
      if conn_name == name then set_buf_conn(bufnr, nil) end
    end
    vim.notify(("belvedere: disconnected from %q"):format(name), vim.log.levels.INFO)
    connections_panel.refresh()
  end)
end

-- Return the names of all currently-open connections (for tab completion).
function M.active_names()
  local names = vim.tbl_keys(state.conns)
  table.sort(names)
  return names
end

-- Return valid bufnrs whose associated connection matches {name}.
function M.buffers_for(name)
  local result = {}
  for bufnr, conn_name in pairs(state.buf_conns) do
    if conn_name == name and vim.api.nvim_buf_is_valid(bufnr) then
      table.insert(result, bufnr)
    end
  end
  return result
end


local function execute_sql(sql)
  if not sql or sql == "" then
    vim.notify("belvedere: no SQL to execute", vim.log.levels.WARN)
    return
  end
  local conn = conn_for_buf(vim.api.nvim_get_current_buf())
  if not conn then
    if next(state.conns) == nil then
      vim.notify("belvedere: no active connection — use :DbConnections to connect", vim.log.levels.WARN)
    else
      vim.notify("belvedere: no active connection — run :DbAssociate first", vim.log.levels.WARN)
    end
    return
  end
  executor.run(conn, sql)
end

function M.execute()
  local sql
  if selection.is_in_visual_mode() then
    sql = selection.get_selection()
    if not sql or sql == "" then
      vim.notify("belvedere: empty selection", vim.log.levels.WARN)
      return
    end
  else
    sql = vim.api.nvim_get_current_line()
    if vim.trim(sql) == "" then
      vim.notify("belvedere: current line is empty", vim.log.levels.WARN)
      return
    end
  end
  execute_sql(sql)
end

function M.execute_range(line1, line2)
  local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  execute_sql(table.concat(lines, "\n"))
end

function M.open_connections()
  connections_panel.open()
end

function M.open_current_driver_help(opts)
  local conn = conn_for_buf(vim.api.nvim_get_current_buf())
  if not conn then
    vim.notify("belvedere: no connection associated with this buffer", vim.log.levels.WARN)
    return
  end
  M.open_driver_help(conn.driver, opts)
end

function M.open_driver_help(driver, opts)
  opts = opts or {}
  if not start_backend() then return end
  client.request("driver.help", { driver = driver }, function(err, result)
    if err then
      vim.notify("belvedere: " .. err, vim.log.levels.ERROR)
      return
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result.content, "\n"))
    vim.bo[buf].filetype   = "markdown"
    vim.bo[buf].modifiable = false
    local win
    if opts.position == "bottom" then
      vim.cmd("botright split")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.api.nvim_win_set_height(win, math.floor(vim.o.lines * 0.4))
    else
      local width  = math.floor(vim.o.columns * 0.8)
      local height = math.floor(vim.o.lines   * 0.8)
      win = vim.api.nvim_open_win(buf, true, {
        relative   = "editor",
        width      = width,
        height     = height,
        row        = math.floor((vim.o.lines   - height) / 2),
        col        = math.floor((vim.o.columns - width)  / 2),
        style      = "minimal",
        border     = "rounded",
        title      = " " .. driver .. " ",
        title_pos  = "center",
      })
    end
    vim.keymap.set("n", "q",     function() vim.api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
    vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
  end)
end

function M.open_explorer_for(name)
  local conn = state.conns[name]
  if not conn then
    vim.notify(("belvedere: not connected to %q — press <CR> to connect first"):format(name), vim.log.levels.ERROR)
    return
  end
  explorer.open(conn.conn_id, name, conn.driver)
end

function M.open_explorer()
  -- The current buffer's connection, or else any open connection.
  local name = state.buf_conns[vim.api.nvim_get_current_buf()] or next(state.conns)
  local conn = name and state.conns[name]
  if not conn then
    vim.notify("belvedere: no active connection — run :DbConnect first", vim.log.levels.WARN)
    return
  end
  explorer.open(conn.conn_id, name, conn.driver)
end

local function teardown()
  client.stop()  -- also resets capabilities cache
  state.conns     = {}
  state.buf_conns = {}
  conn_label.clear_all()
  explorer.reset()
end

function M.stop()
  teardown()
  vim.notify("belvedere: backend stopped", vim.log.levels.INFO)
end

function M.restart()
  teardown()
  if start_backend() then
    vim.notify("belvedere: backend restarted", vim.log.levels.INFO)
  end
end

return M
