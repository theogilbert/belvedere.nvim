-- Highlight groups and namespaces for dbelveder.
-- Ported and adapted from nvim-dap-df/lua/nvim-dap-df-pane/hl.lua.
local M = {}

local BORDER_FG    = "#555555"
local HEADER_FG    = "#9CDCFE"
local ERROR_FG     = "#CA2722"
local TRUNCATED_FG = "#666666"
local ROW_COUNT_FG = "#7F8490"
local CONN_FG      = "#7DB88A"

local function build_highlights()
  return {
    DbelvederBorder    = { fg = BORDER_FG },
    DbelvederHeaderRow = { fg = HEADER_FG, bold = true },
    DbelvederError     = { fg = ERROR_FG },
    DbelvederTruncated = { fg = TRUNCATED_FG, bold = true },
    DbelvederRowCount  = { fg = ROW_COUNT_FG },
  }
end

local function setup_highlights()
  M.NS_ID            = vim.api.nvim_create_namespace("DbelvederNs")
  M.TRUNCATION_NS_ID = vim.api.nvim_create_namespace("DbelvederTruncationNs")
  for group, opts in pairs(build_highlights()) do
    vim.api.nvim_set_hl(M.NS_ID, group, opts)
  end
  -- Defined globally so it works in any buffer's extmarks; default = true allows user override.
  vim.api.nvim_set_hl(0, "DbelvederConnection", { fg = CONN_FG, italic = true, default = true })
end

function M.setup()
  setup_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = setup_highlights })
end

return M
