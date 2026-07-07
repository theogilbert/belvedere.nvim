local M = {}

--- Return the XDG-aware default path for connections.json.
--- @return string
local function default_connections_file()
  local xdg = vim.env.XDG_CONFIG_HOME or vim.fn.expand("~/.config")
  return xdg .. "/belvedere/connections.json"
end

--- Return the XDG-aware default directory for saved queries.
--- @return string
local function default_queries_dir()
  local xdg = vim.env.XDG_DATA_HOME or vim.fn.expand("~/.local/share")
  return xdg .. "/belvedere/queries"
end

M.defaults = {
  -- Command used to launch the server backend.
  server_cmd = "belvedere",  -- or "python -m belvedere"

  -- Path to the JSON file that stores named connections.
  -- Defaults to $XDG_CONFIG_HOME/belvedere/connections.json
  connections_file = nil,  -- populated in setup() so the function runs at call time

  -- Directory that stores saved queries (one file per query).
  -- Defaults to $XDG_DATA_HOME/belvedere/queries/
  queries_dir = nil,

  keymaps = {
    hover_key = "K",
  },

  -- When a driver has at most this many connections total, skip the group step
  -- and show all connections as "group/name" in a flat list.
  flat_conn_threshold = 5,

  -- Results window options.
  results = {
    split     = "below",  -- "below" | "right"
    height    = 15,
    page_size = 500,

    -- Character inserted between digit groups in numeric cells (e.g. "1_234_567").
    -- Set to false or "" to disable.
    thousands_separator = "_",

    -- Character used as the decimal point in numeric cells (e.g. "1234.56").
    -- Set to false or "" to display numbers with a literal "." decimal point.
    decimal_separator = ".",
  },
}

M.options = {}

--- Merge user options into defaults and populate path fields that require runtime evaluation.
--- @param user_opts table|nil
function M.setup(user_opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
  if not M.options.connections_file then
    M.options.connections_file = default_connections_file()
  end
  if not M.options.queries_dir then
    M.options.queries_dir = default_queries_dir()
  end
end

return M
