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
local gutter            = require("belvedere.ui.gutter")
local ts_queries        = require("belvedere.ts_queries")

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

-- Compute the display label for a connection: "name (Driver Label)".
local function conn_display_label(key)
  local conn  = state.conns[key]
  local label = conn and (conn.driver_label or conn.driver)
  return label and (connections.conn_display_name(key) .. " (" .. label .. ")") or connections.conn_display_name(key)
end

-- Associate (or, with conn_key=nil, dissociate) a buffer and update its window labels.
local function set_buf_conn(bufnr, name)
  state.buf_conns[bufnr] = name
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if name then conn_label.show(winid, conn_display_label(name)) else conn_label.hide(winid) end
  end
end

function M.set_buf_conn(bufnr, conn_key)
  set_buf_conn(bufnr, conn_key)
end

function M.setup(opts)
  config.setup(opts)
  hl.setup()
  gutter.setup()
  conn_label.setup(function(bufnr)
    local name = state.buf_conns[bufnr]
    return name and conn_display_label(name)
  end)
end


-- Start the backend if it isn't already running.
-- Returns false (and notifies) if the process could not be spawned.
local function start_backend()
  if client.is_running() then return true end
  local ok, err = pcall(client.start, config.options.server_cmd)
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
    local resolved_key = name
    if not params then
      -- Search the active server's connections by display name (:DbConnect <name>).
      local active_caps = client.capabilities()
      local server = active_caps and (active_caps.server or "") or ""
      local server_data = connections.load(server)
      for driver_id, driver_data in pairs(server_data) do
        for group, group_conns in pairs(driver_data.groups or {}) do
          for conn_name, conn_params in pairs(group_conns) do
            if conn_name == name then
              resolved_key = connections.conn_key(server, driver_id, group, conn_name)
              params = conn_params
              break
            end
          end
          if params then break end
        end
        if params then break end
      end
    end
    if not params then
      vim.notify(("belvedere: connection %q not found"):format(name), vim.log.levels.ERROR)
      return
    end
    connections.prompt_password(params, function(params_with_pw)
      if not params_with_pw then return end
      M._do_connect(resolved_key, params_with_pw, after_connect)
    end)
  else
    local ft = vim.bo[bufnr].filetype
    M.ensure_backend_with_caps(function(caps)
      local active_set = {}
      for _, k in ipairs(M.active_keys()) do active_set[k] = true end
      connections.pick(caps, active_set, ft, function(picked_name, params)
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

-- Fields in connection params that must not be forwarded to the server.
local CLIENT_ONLY_FIELDS = { requires_password = true }

function M._send_connect(name, params, after_connect)
  local _, driver, _, _ = connections.conn_parts(name)
  local server_params = { driver = driver }
  for k, v in pairs(params) do
    if not CLIENT_ONLY_FIELDS[k] then server_params[k] = v end
  end
  local display = connections.conn_display_name(name)
  -- Get the human-readable driver label from capabilities.
  local driver_label = driver
  local caps = client.capabilities()
  if caps then
    for _, d in ipairs(caps.drivers or {}) do
      if d.driver == driver then driver_label = d.label or driver; break end
    end
  end
  client.request("connect", server_params, function(err, result)
    connections_panel.clear_conn_loading(name)
    if err then
      local first_line = err:match("^([^\n]*)") or err
      vim.notify(("belvedere: %q failed — %s"):format(display, first_line), vim.log.levels.ERROR)
      connections_panel.set_conn_error(name, err)
      return
    end
    state.conns[name] = { conn_id = result.connection_id, driver = driver, key = name, driver_label = driver_label }
    vim.notify(("belvedere: connected to %q (%s)"):format(display, driver_label), vim.log.levels.INFO)
    connections_panel.refresh()
    if after_connect then after_connect(name) end
  end)
end

function M.associate()
  local keys = vim.tbl_keys(state.conns)
  if #keys == 0 then
    vim.notify("belvedere: no open connections — open the connection panel with :DbConnections", vim.log.levels.WARN)
    return
  end
  table.sort(keys)
  vim.ui.select(keys, {
    prompt      = "Associate connection:",
    format_item = function(key)
      local conn  = state.conns[key]
      local label = conn and conn.driver_label
      return label and (connections.conn_display_name(key) .. " (" .. label .. ")") or connections.conn_display_name(key)
    end,
  }, function(key)
    if not key then return end
    set_buf_conn(vim.api.nvim_get_current_buf(), key)
    vim.notify(("belvedere: buffer associated with %q"):format(connections.conn_display_name(key)), vim.log.levels.INFO)
  end)
end

function M.disconnect(name)
  local key = name ~= "" and name or state.buf_conns[vim.api.nvim_get_current_buf()]
  if not key then
    vim.notify("belvedere: no active connection", vim.log.levels.WARN)
    return
  end
  local conn = state.conns[key]
  if not conn then
    -- Try matching by display name
    for k in pairs(state.conns) do
      if connections.conn_display_name(k) == key then
        key = k
        conn = state.conns[k]
        break
      end
    end
  end
  if not conn then
    vim.notify(("belvedere: not connected to %q"):format(name), vim.log.levels.ERROR)
    return
  end
  client.request("disconnect", { connection_id = conn.conn_id }, function(err, _)
    if err then
      vim.notify("belvedere: " .. err, vim.log.levels.ERROR)
      return
    end
    state.conns[key] = nil
    -- Clear the label from every buffer that was using this connection.
    for bufnr, conn_name in pairs(state.buf_conns) do
      if conn_name == key then set_buf_conn(bufnr, nil) end
    end
    vim.notify(("belvedere: disconnected from %q"):format(connections.conn_display_name(key)), vim.log.levels.INFO)
    connections_panel.refresh()
  end)
end

-- Return the display names of all currently-open connections (for tab completion).
function M.active_names()
  local names = {}
  local seen = {}
  for key in pairs(state.conns) do
    local dn = connections.conn_display_name(key)
    if not seen[dn] then seen[dn] = true; table.insert(names, dn) end
  end
  table.sort(names)
  return names
end

-- Return the storage keys of all currently-open connections.
function M.active_keys()
  local keys = vim.tbl_keys(state.conns)
  table.sort(keys)
  return keys
end

-- Return the active conn record for a key, or nil.
function M.get_conn(key)
  return state.conns[key]
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


local function execute_sql(sql, bufnr, first_line, prebuilt_queries)
  if not prebuilt_queries and (not sql or sql == "") then
    vim.notify("belvedere: no SQL to execute", vim.log.levels.WARN)
    return
  end
  local conn = conn_for_buf(bufnr)
  if not conn then
    if next(state.conns) == nil then
      vim.notify("belvedere: no active connection — use :DbConnections to connect", vim.log.levels.WARN)
    else
      vim.notify("belvedere: no active connection — run :DbAssociate first", vim.log.levels.WARN)
    end
    return
  end
  executor.run(conn, sql or "", bufnr, first_line, prebuilt_queries)
end

function M.execute()
  local bufnr = vim.api.nvim_get_current_buf()

  if selection.is_in_visual_mode() then
    local vsr = vim.fn.getpos("v")[2]
    local ver = vim.fn.getpos(".")[2]
    local sr  = math.min(vsr, ver) - 1  -- 0-indexed
    local er  = math.max(vsr, ver) - 1

    -- Use treesitter to detect multiple distinct statements in the selection.
    local ts_stmts = ts_queries.statements_in_range(bufnr, sr, er)
    if ts_stmts and #ts_stmts > 1 then
      local first = ts_stmts[1].start_row
      local queries = {}
      for _, s in ipairs(ts_stmts) do
        table.insert(queries, { sql = s.text, line = s.start_row - first })
      end
      execute_sql(nil, bufnr, first, queries)
      return
    end

    -- Single statement or no treesitter — fall back to raw selection text.
    local sql = selection.get_selection()
    if not sql or sql == "" then
      vim.notify("belvedere: empty selection", vim.log.levels.WARN)
      return
    end
    execute_sql(sql, bufnr, sr)
  else
    -- No selection: use treesitter to find the outermost statement at cursor.
    local ts_stmt = ts_queries.statement_at_cursor(bufnr)
    if ts_stmt then
      execute_sql(ts_stmt.text, bufnr, ts_stmt.start_row)
      return
    end

    -- Treesitter unavailable — fall back to the current line.
    local sql = vim.api.nvim_get_current_line()
    if vim.trim(sql) == "" then
      vim.notify("belvedere: current line is empty", vim.log.levels.WARN)
      return
    end
    execute_sql(sql, bufnr, vim.api.nvim_win_get_cursor(0)[1] - 1)
  end
end

function M.execute_range(line1, line2)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  execute_sql(table.concat(lines, "\n"), bufnr, line1 - 1)
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
    vim.notify(("belvedere: not connected to %q — press <CR> to connect first"):format(connections.conn_display_name(name)), vim.log.levels.ERROR)
    return
  end
  explorer.open(conn.conn_id, connections.conn_display_name(name), conn.driver, name, conn.driver_label)
end

function M.open_explorer()
  -- The current buffer's connection, or else any open connection.
  local key = state.buf_conns[vim.api.nvim_get_current_buf()] or next(state.conns)
  local conn = key and state.conns[key]
  if not conn then
    vim.notify("belvedere: no active connection — run :DbConnect first", vim.log.levels.WARN)
    return
  end
  explorer.open(conn.conn_id, connections.conn_display_name(key), conn.driver, key, conn.driver_label)
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

local function open_save_query(content, bufnr)
  local ext = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":e")
  if ext == "" then ext = vim.bo[bufnr].filetype end
  require("belvedere.ui.save_query").open(content, state.buf_conns[bufnr], ext)
end

-- Mode-aware: reads the visual selection or the current line.
function M.save_query()
  local bufnr = vim.api.nvim_get_current_buf()
  local content
  if selection.is_in_visual_mode() then
    content = selection.get_selection()
    if not content or content == "" then
      vim.notify("belvedere: empty selection", vim.log.levels.WARN)
      return
    end
  else
    content = vim.api.nvim_get_current_line()
    if vim.trim(content) == "" then
      vim.notify("belvedere: current line is empty", vim.log.levels.WARN)
      return
    end
  end
  open_save_query(content, bufnr)
end

-- For :[range]DbSaveQuery — range lines are already resolved by Neovim.
function M.save_query_range(line1, line2)
  local bufnr   = vim.api.nvim_get_current_buf()
  local lines   = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  local content = table.concat(lines, "\n")
  if vim.trim(content) == "" then
    vim.notify("belvedere: empty selection", vim.log.levels.WARN)
    return
  end
  open_save_query(content, bufnr)
end

function M.cancel_query()
  local bufnr      = vim.api.nvim_get_current_buf()
  local line       = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed
  local request_id = gutter.find_request_at_line(bufnr, line)
  if not request_id then
    vim.notify("belvedere: cursor must be over a running query", vim.log.levels.WARN)
    return
  end
  client.cancel(request_id, function(err, _)
    if err then
      vim.notify("belvedere: cancel failed — " .. err, vim.log.levels.ERROR)
    end
  end)
end

function M.load_query(conn_key)
  if not conn_key then
    conn_key = state.buf_conns[vim.api.nvim_get_current_buf()]
  end
  if not conn_key then
    vim.notify("belvedere: no connection associated with current buffer", vim.log.levels.WARN)
    return
  end
  require("belvedere.ui.query_picker").open(conn_key)
end

function M.query_log(conn_key)
  if not conn_key then
    conn_key = state.buf_conns[vim.api.nvim_get_current_buf()]
  end
  if not conn_key then
    vim.notify("belvedere: no connection associated with current buffer", vim.log.levels.WARN)
    return
  end
  require("belvedere.ui.query_log").open(conn_key, state.conns[conn_key])
end

return M
