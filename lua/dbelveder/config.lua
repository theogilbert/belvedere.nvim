local M = {}

M.defaults = {
  -- Command used to launch the Python backend.
  -- Can be "dbelveder" (if installed via pip) or "python -m dbelveder".
  python_cmd = "dbelveder",

  -- Named connections.  Each key is an alias selectable via :DbConnect <alias>.
  -- params are passed verbatim to the Python connect handler.
  connections = {
    -- example = {
    --   driver   = "sqlite",
    --   database = vim.fn.expand("~/my.db"),
    -- },
  },

  -- Keymaps inside the query buffer
  keymaps = {
    execute = "<CR>",   -- execute selected range (or whole buffer if no selection)
  },

  -- Results window options
  results = {
    split    = "below",   -- "below" | "right"
    height   = 15,
    max_rows = 500,
  },
}

M.options = {}

function M.setup(user_opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
end

return M
