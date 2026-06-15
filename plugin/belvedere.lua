if vim.g.loaded_belvedere then return end
vim.g.loaded_belvedere = true

local db = require("belvedere")

-- Names of all saved connections, sorted — used for command completion.
local function saved_connection_names()
  local ok, conns = pcall(require("belvedere.connections").load)
  if not ok then return {} end
  local names = vim.tbl_keys(conns)
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

-- :DbDeleteConnection <name>  — remove a saved connection
vim.api.nvim_create_user_command("DbDeleteConnection", function(opts)
  local arg = vim.trim(opts.args)
  if arg == "" then
    vim.notify("Usage: :DbDeleteConnection <name>", vim.log.levels.WARN)
    return
  end
  require("belvedere.connections").delete(arg)
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

-- :DbStop
vim.api.nvim_create_user_command("DbStop", function(_)
  db.stop()
end, {})

-- :DbRestart
vim.api.nvim_create_user_command("DbRestart", function(_)
  db.restart()
end, {})
