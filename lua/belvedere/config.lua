local M = {}

local function default_connections_file()
  local xdg = vim.env.XDG_CONFIG_HOME or vim.fn.expand("~/.config")
  return xdg .. "/belvedere/connections.json"
end

M.defaults = {
  -- Command used to launch the server backend.
  server_cmd = "belvedere",  -- or "python -m belvedere"

  -- Path to the JSON file that stores named connections.
  -- Defaults to $XDG_CONFIG_HOME/belvedere/connections.json
  -- (~/.config/belvedere/connections.json on most systems).
  connections_file = nil,  -- populated in setup() so the function runs at call time

  keymaps = {
    hover_key = "K",
  },

  -- Results window options.
  results = {
    split     = "below",  -- "below" | "right"
    height    = 15,
    page_size = 500,
  },
}

M.options = {}

function M.setup(user_opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
  if not M.options.connections_file then
    M.options.connections_file = default_connections_file()
  end
end

return M
