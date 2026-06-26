if vim.g.loaded_belvedere then return end
vim.g.loaded_belvedere = true

local db = require("belvedere")

-- Names of all saved connections, sorted — used for command completion.
local function saved_connection_names()
  local ok, data = pcall(require("belvedere.connections").load_all)
  if not ok then return {} end
  local seen, names = {}, {}
  for _, server_data in pairs(data) do
    if type(server_data) == "table" then
      for _, driver_data in pairs(server_data) do
        if type(driver_data) == "table" then
          for _, group_conns in pairs(driver_data.groups or {}) do
            for conn_name in pairs(group_conns) do
              if not seen[conn_name] then seen[conn_name] = true; table.insert(names, conn_name) end
            end
          end
        end
      end
    end
  end
  table.sort(names)
  return names
end

-- :DbConnect          — open the connection picker
-- :DbConnect <name>   — connect directly by name
vim.api.nvim_create_user_command("DbConnect", function(opts)
  db.connect(vim.trim(opts.args))
end, {
  nargs = "?",
  complete = saved_connection_names,
})

-- :DbAssociate   — pick an open connection to associate with the current buffer
vim.api.nvim_create_user_command("DbAssociate", function(_)
  db.associate()
end, {})

-- :DbNewConnection  — open the new-connection wizard
vim.api.nvim_create_user_command("DbNewConnection", function(_)
  db.ensure_backend_with_caps(function(caps)
    require("belvedere.connections").create(caps, function(name, params)
      if name then db._do_connect(name, params) end
    end)
  end)
end, {})

-- :DbDeleteConnection <name>  — remove a saved connection by display name
vim.api.nvim_create_user_command("DbDeleteConnection", function(opts)
  local arg = vim.trim(opts.args)
  if arg == "" then
    vim.notify("Usage: :DbDeleteConnection <name>", vim.log.levels.WARN)
    return
  end
  local conns_mod = require("belvedere.connections")
  local matches = {}
  local data = conns_mod.load_all()
  for server_name, server_data in pairs(data) do
    if type(server_data) == "table" then
      for driver_id, driver_data in pairs(server_data) do
        if type(driver_data) == "table" then
          for group, group_conns in pairs(driver_data.groups or {}) do
            if group_conns[arg] then
              table.insert(matches, conns_mod.conn_key(server_name, driver_id, group, arg))
            end
          end
        end
      end
    end
  end
  if #matches == 0 then
    vim.notify(("belvedere: connection %q not found"):format(arg), vim.log.levels.WARN)
  elseif #matches == 1 then
    conns_mod.delete(matches[1])
  else
    vim.notify(("belvedere: %q is ambiguous (%d matches) — use the connections panel to delete"):format(arg, #matches), vim.log.levels.WARN)
  end
end, {
  nargs = 1,
  complete = saved_connection_names,
})

-- :DbDisconnect [name]  — disconnect a named connection, or the active one
vim.api.nvim_create_user_command("DbDisconnect", function(opts)
  db.disconnect(vim.trim(opts.args))
end, {
  nargs = "?",
  complete = function() return db.active_names() end,
})

-- :[range]DbExecute  — current line, or explicit range / visual selection
vim.api.nvim_create_user_command("DbExecute", function(opts)
  db.execute_range(opts.line1, opts.line2)
end, { range = true })


-- :DbExplore
vim.api.nvim_create_user_command("DbExplore", function(_)
  db.open_explorer()
end, {})

vim.api.nvim_create_user_command("DbConnections", function(_)
  db.open_connections()
end, {})

-- :[range]DbSaveQuery  — save selected/current-line query
vim.api.nvim_create_user_command("DbSaveQuery", function(opts)
  db.save_query_range(opts.line1, opts.line2)
end, { range = true })

-- :DbLoadQueries  — list saved queries for the current buffer's connection
vim.api.nvim_create_user_command("DbLoadQueries", function(_)
  db.load_query()
end, {})

-- :DbQueryLog  — open the query log for the current buffer's connection
vim.api.nvim_create_user_command("DbQueryLog", function(_)
  db.query_log()
end, {})

-- :DbCancelQuery  — cancel the running query under the cursor (gutter icon line)
vim.api.nvim_create_user_command("DbCancelQuery", function(_)
  db.cancel_query()
end, {})

-- :DbStop
vim.api.nvim_create_user_command("DbStop", function(_)
  db.stop()
end, {})

-- :DbRestart
vim.api.nvim_create_user_command("DbRestart", function(_)
  db.restart()
end, {})
