-- Highlight groups and namespaces for belvedere.
-- Ported and adapted from nvim-dap-df/lua/nvim-dap-df-pane/hl.lua.
local M = {}

local BORDER_FG    = "#555555"
local HEADER_FG    = "#9CDCFE"
local ERROR_FG     = "#CA2722"
local TRUNCATED_FG = "#666666"
local ROW_COUNT_FG = "#7F8490"
local CONN_FG      = "#7DB88A"
local NULL_FG      = "#6B7280"
local LOB_FG       = "#6B7280"
local HELP_FG      = "#4B9CD3"
local THOUSANDS_FG = "#767676"
local SCROLLBAR_FG = "#888888"

--- Build the table of highlight group definitions.
--- @return table<string, table>
local function build_highlights()
  return {
    BelvedereBorder    = { fg = BORDER_FG },
    BelvedereHeaderRow = { fg = HEADER_FG, bold = true },
    BelvedereError     = { fg = ERROR_FG },
    BelvedereTruncated = { fg = TRUNCATED_FG, bold = true },
    BelvedereRowCount  = { fg = ROW_COUNT_FG },
    BelvedereNull      = { fg = NULL_FG, italic = true },
    BelvedereLob       = { fg = LOB_FG, italic = true },
    BelvedereHelp      = { fg = HELP_FG, italic = true },
    BelvedereThousandsSeparator = { fg = THOUSANDS_FG },
    BelvedereScrollbarThumb     = { fg = SCROLLBAR_FG },
  }
end

--- Create namespaces and define all highlight groups; re-called on ColorScheme.
local function setup_highlights()
  M.NS_ID            = vim.api.nvim_create_namespace("BelvedereNs")
  M.TRUNCATION_NS_ID = vim.api.nvim_create_namespace("BelvedereTruncationNs")
  for group, opts in pairs(build_highlights()) do
    vim.api.nvim_set_hl(M.NS_ID, group, opts)
  end
  -- Defined globally so it works in any buffer's extmarks; default = true allows user override.
  vim.api.nvim_set_hl(0, "BelvedereConnection",          { fg = CONN_FG,    italic = true, default = true })
  vim.api.nvim_set_hl(0, "BelvedereConnError",           { fg = ERROR_FG,   default = true })
  vim.api.nvim_set_hl(0, "BelvedereQueryRunning",        { fg = "#E5C07B",  default = true })
  vim.api.nvim_set_hl(0, "BelvedereQuerySuccess",        { fg = "#98C379",  default = true })
  vim.api.nvim_set_hl(0, "BelvedereQueryError",          { fg = "#CA2722",  default = true })
  vim.api.nvim_set_hl(0, "BelvedereQueryFlash",          { link = "Visual", default = true })
  vim.api.nvim_set_hl(0, "BelvedereExplorerDatabase",    { fg = "#98C379",  default = true })
  vim.api.nvim_set_hl(0, "BelvedereExplorerSchema",      { fg = "#E5C07B",  default = true })
  vim.api.nvim_set_hl(0, "BelvedereExplorerTable",       { fg = "#61AFEF",  default = true })
  vim.api.nvim_set_hl(0, "BelvedereExplorerColumn",      { fg = "#D19A66",  default = true })
  vim.api.nvim_set_hl(0, "BelvedereExplorerView",        { fg = "#C678DD",  default = true })
  vim.api.nvim_set_hl(0, "BelvedereExplorerCollection",  { fg = "#4EC9B0",  default = true })
  vim.api.nvim_set_hl(0, "BelvedereExplorerIndex",       { fg = "#56B6C2",  default = true })
  vim.api.nvim_set_hl(0, "BelvedereExplorerConstraint",  { fg = "#E06C75",  default = true })
  vim.api.nvim_set_hl(0, "BelvedereExplorerGroup",       { fg = "#848D9E",  default = true })
  vim.api.nvim_set_hl(0, "BelvedereExplorerDim",         { fg = "#6B7691",  default = true })
end

--- Initialize namespaces, define highlights, and register a ColorScheme autocmd.
function M.setup()
  setup_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = setup_highlights })
end

return M
