if vim.g.loaded_dbelveder then return end
vim.g.loaded_dbelveder = true

local db = require("dbelveder")

-- :DbConnect [name]        — connect to a named connection
-- :DbConnect! driver=... — inline params (future: parsed from args)
vim.api.nvim_create_user_command("DbConnect", function(opts)
  local arg = vim.trim(opts.args)
  if arg == "" then
    vim.notify("Usage: :DbConnect <connection_name>", vim.log.levels.WARN)
    return
  end
  db.connect(arg)
end, { nargs = "?" })

vim.api.nvim_create_user_command("DbDisconnect", function(_)
  db.disconnect()
end, {})

-- :[range]DbExecute   — execute range (or current line) as SQL
vim.api.nvim_create_user_command("DbExecute", function(opts)
  db.execute_range(opts.line1, opts.line2)
end, { range = true })

-- :DbExplore          — open the tree explorer
vim.api.nvim_create_user_command("DbExplore", function(_)
  db.open_explorer()
end, {})

-- :DbStop             — kill the backend process
vim.api.nvim_create_user_command("DbStop", function(_)
  db.stop()
end, {})
