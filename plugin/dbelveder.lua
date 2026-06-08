if vim.g.loaded_dbelveder then return end
vim.g.loaded_dbelveder = true

local db = require("dbelveder")

-- :DbConnect          — open the connection picker
-- :DbConnect <name>   — connect directly by name
vim.api.nvim_create_user_command("DbConnect", function(opts)
  local arg = vim.trim(opts.args)
  if arg == "" then
    db.connect()
  else
    db.connect_by_name(arg)
  end
end, {
  nargs = "?",
  complete = function()
    local ok, conns = pcall(require("dbelveder.connections").load)
    if not ok then return {} end
    local names = vim.tbl_keys(conns)
    table.sort(names)
    return names
  end,
})

-- :DbUse <name>   — switch the active connection (among already-open ones)
vim.api.nvim_create_user_command("DbUse", function(opts)
  local arg = vim.trim(opts.args)
  if arg == "" then
    vim.notify("Usage: :DbUse <name>", vim.log.levels.WARN)
    return
  end
  db.use(arg)
end, {
  nargs = 1,
  complete = function() return db.active_names() end,
})

-- :DbNewConnection    — jump straight to the new-connection wizard
vim.api.nvim_create_user_command("DbNewConnection", function(_)
  require("dbelveder.connections").create(function(name, params)
    if name then db._do_connect(name, params) end
  end)
end, {})

-- :DbDeleteConnection <name>  — remove a saved connection
vim.api.nvim_create_user_command("DbDeleteConnection", function(opts)
  local arg = vim.trim(opts.args)
  if arg == "" then
    vim.notify("Usage: :DbDeleteConnection <name>", vim.log.levels.WARN)
    return
  end
  require("dbelveder.connections").delete(arg)
end, {
  nargs = 1,
  complete = function()
    local ok, conns = pcall(require("dbelveder.connections").load)
    if not ok then return {} end
    local names = vim.tbl_keys(conns)
    table.sort(names)
    return names
  end,
})

-- :DbDisconnect [name]  — disconnect a named connection, or the active one
vim.api.nvim_create_user_command("DbDisconnect", function(opts)
  db.disconnect(vim.trim(opts.args))
end, {
  nargs = "?",
  complete = function() return db.active_names() end,
})

-- :[range]DbExecute
vim.api.nvim_create_user_command("DbExecute", function(opts)
  db.execute_range(opts.line1, opts.line2)
end, { range = true })


-- :DbExplore
vim.api.nvim_create_user_command("DbExplore", function(_)
  db.open_explorer()
end, {})

-- :DbStop
vim.api.nvim_create_user_command("DbStop", function(_)
  db.stop()
end, {})
