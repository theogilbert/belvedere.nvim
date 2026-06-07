local M = {}

local client      = require("dbelveder.client")
local config      = require("dbelveder.config")
local connections = require("dbelveder.connections")
local results     = require("dbelveder.ui.results")
local explorer    = require("dbelveder.ui.explorer")

function M.setup(opts)
  config.setup(opts)
end

-- ── connection ────────────────────────────────────────────────────────────────

-- Open the connection picker.  The user selects an existing connection or
-- creates a new one through the wizard.
function M.connect()
  connections.pick(function(name, params)
    if not name then return end
    M._do_connect(params)
  end)
end

-- Connect directly by name (skips the picker).
function M.connect_by_name(name)
  local params = connections.get(name)
  if not params then
    vim.notify(("dbelveder: connection %q not found"):format(name), vim.log.levels.ERROR)
    return
  end
  M._do_connect(params)
end

function M._do_connect(params)
  if not client.is_running() then
    local ok, err = pcall(client.start, config.options.python_cmd)
    if not ok then
      vim.notify("dbelveder: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.defer_fn(function() M._send_connect(params) end, 200)
  else
    M._send_connect(params)
  end
end

function M._send_connect(params)
  client.request("connect", params, function(err, _)
    if err then
      vim.notify("dbelveder: " .. err, vim.log.levels.ERROR)
      return
    end
    explorer.reset()
    vim.notify("dbelveder: connected (" .. params.driver .. ")", vim.log.levels.INFO)
  end)
end

function M.disconnect()
  client.request("disconnect", {}, function(err, _)
    if err then
      vim.notify("dbelveder: " .. err, vim.log.levels.ERROR)
    else
      explorer.reset()
      vim.notify("dbelveder: disconnected", vim.log.levels.INFO)
    end
  end)
end

-- ── query ─────────────────────────────────────────────────────────────────────

function M.execute(sql)
  if not sql or sql == "" then
    vim.notify("dbelveder: no SQL to execute", vim.log.levels.WARN)
    return
  end
  results.show_message("Executing…")
  client.request("execute", { sql = sql, params = {} }, function(err, result)
    vim.schedule(function()
      if err then
        results.show_error(err)
      else
        results.show_results(result.columns or {}, result.rows or {})
      end
    end)
  end)
end

function M.execute_range(line1, line2)
  local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  M.execute(table.concat(lines, "\n"))
end

-- ── explorer / lifecycle ──────────────────────────────────────────────────────

function M.open_explorer()
  if not client.is_running() then
    vim.notify("dbelveder: not connected — run :DbConnect first", vim.log.levels.WARN)
    return
  end
  explorer.open()
end

function M.stop()
  client.stop()
  vim.notify("dbelveder: backend stopped", vim.log.levels.INFO)
end

return M
