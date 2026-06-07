local M = {}

local client   = require("dbelveder.client")
local config   = require("dbelveder.config")
local results  = require("dbelveder.ui.results")
local explorer = require("dbelveder.ui.explorer")

function M.setup(opts)
  config.setup(opts)
end

-- Connect to a named connection from config, or supply params inline.
-- M.connect("mydb")
-- M.connect({ driver = "sqlite", database = "/path/to/db.sqlite" })
function M.connect(name_or_params)
  local opts  = config.options
  local params
  if type(name_or_params) == "string" then
    params = opts.connections[name_or_params]
    if not params then
      vim.notify(("dbelveder: unknown connection %q"):format(name_or_params), vim.log.levels.ERROR)
      return
    end
  else
    params = name_or_params
  end

  -- Ensure backend is running
  if not client.is_running() then
    local ok, err = pcall(client.start, opts.python_cmd)
    if not ok then
      vim.notify("dbelveder: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    -- Give the process a moment to start, then connect
    vim.defer_fn(function() M._do_connect(params) end, 200)
  else
    M._do_connect(params)
  end
end

function M._do_connect(params)
  client.request("connect", params, function(err, _result)
    if err then
      vim.notify("dbelveder connect: " .. err, vim.log.levels.ERROR)
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

-- Execute a SQL string (or the lines from the given range).
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

-- Execute the visual selection, or the whole buffer if no range.
function M.execute_range(line1, line2)
  local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  M.execute(table.concat(lines, "\n"))
end

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
