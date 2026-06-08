local M = {}

local client      = require("dbelveder.client")
local config      = require("dbelveder.config")
local hl          = require("dbelveder.hl")
local connections = require("dbelveder.connections")
local results     = require("dbelveder.ui.results")
local explorer    = require("dbelveder.ui.explorer")

-- Active connections: { [name] = { conn_id, driver } }
-- active_name: the connection used by :DbExecute and :DbExplore
local state = {
  conns       = {},
  active_name = nil,
}

function M.setup(opts)
  config.setup(opts)
  hl.setup()
end

-- ── connection ────────────────────────────────────────────────────────────────

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
  M._do_connect(name, params)
end

function M._do_connect(name, params)
  if not client.is_running() then
    local ok, err = pcall(client.start, config.options.python_cmd)
    if not ok then
      vim.notify("dbelveder: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.defer_fn(function() M._send_connect(name, params) end, 200)
  else
    M._send_connect(name, params)
  end
end

function M._send_connect(name, params)
  client.request("connect", params, function(err, result)
    if err then
      vim.notify("dbelveder: " .. err, vim.log.levels.ERROR)
      return
    end
    state.conns[name] = { conn_id = result.connection_id, driver = params.driver }
    state.active_name = name
    explorer.open(result.connection_id)
    vim.notify(("dbelveder: connected to %q (%s)"):format(name, params.driver), vim.log.levels.INFO)
  end)
end

-- Switch the active connection to an already-open one.
function M.use(name)
  if not state.conns[name] then
    vim.notify(("dbelveder: not connected to %q"):format(name), vim.log.levels.ERROR)
    return
  end
  state.active_name = name
  explorer.open(state.conns[name].conn_id)
  vim.notify(("dbelveder: active connection: %q"):format(name), vim.log.levels.INFO)
end

function M.disconnect(name)
  name = name ~= "" and name or state.active_name
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
    if state.active_name == name then
      -- Fall back to another open connection if any.
      local next_name = next(state.conns)
      state.active_name = next_name
      if next_name then
        explorer.open(state.conns[next_name].conn_id)
      else
        explorer.reset()
      end
    end
    vim.notify(("dbelveder: disconnected from %q"):format(name), vim.log.levels.INFO)
  end)
end

-- Return the names of all currently-open connections (for tab completion).
function M.active_names()
  local names = vim.tbl_keys(state.conns)
  table.sort(names)
  return names
end

-- ── query ─────────────────────────────────────────────────────────────────────

function M.execute(sql)
  if not sql or sql == "" then
    vim.notify("dbelveder: no SQL to execute", vim.log.levels.WARN)
    return
  end
  local conn = state.active_name and state.conns[state.active_name]
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
  local start_pos = vim.fn.getpos("'<")
  local end_pos   = vim.fn.getpos("'>")

  -- lnum == 0 means no prior visual selection exists
  if start_pos[2] == 0 then
    vim.notify("dbelveder: no selection — visually select a query first", vim.log.levels.INFO)
    return
  end

  local sr = start_pos[2] - 1
  local sc = start_pos[3] - 1
  local er = end_pos[2] - 1
  -- v:maxcol (2147483647) is used for linewise visual — clamp to actual line length
  local end_line = vim.api.nvim_buf_get_lines(0, er, er + 1, false)[1] or ""
  local ec = math.min(end_pos[3], #end_line)

  local lines = vim.api.nvim_buf_get_text(0, sr, sc, er, ec, {})
  local sql   = vim.trim(table.concat(lines, "\n"))

  if sql == "" then
    vim.notify("dbelveder: no selection — visually select a query first", vim.log.levels.INFO)
    return
  end
  M.execute(sql)
end

-- ── explorer / lifecycle ──────────────────────────────────────────────────────

function M.open_explorer()
  local conn = state.active_name and state.conns[state.active_name]
  if not conn then
    vim.notify("dbelveder: no active connection — run :DbConnect first", vim.log.levels.WARN)
    return
  end
  explorer.open(conn.conn_id)
end

function M.stop()
  client.stop()
  state.conns       = {}
  state.active_name = nil
  explorer.reset()
  vim.notify("dbelveder: backend stopped", vim.log.levels.INFO)
end

return M
