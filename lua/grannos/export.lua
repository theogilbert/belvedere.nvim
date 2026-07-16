-- Pure serializers for exporting query results in various formats.
-- No nvim API calls beyond what table_fmt.from_structured_data already uses.
local table_fmt = require("grannos.table")

local M = {}

--- Export formats offered to the user, in display order.
M.FORMATS = { "pretty", "json", "csv", "markdown" }

--- Neovim filetype to assign to the scratch buffer for each format ("" = none).
M.FILETYPES = {
  json     = "json",
  csv      = "csv",
  pretty   = "",
  markdown = "markdown",
}

local to_json      -- forward declarations; defined below
local to_csv
local to_pretty
local to_markdown

--- Serialize `rows` (with `columns` as field names) into the given export format.
--- @param format  string    one of M.FORMATS
--- @param columns string[]
--- @param rows    any[][]
--- @return string
function M.render(format, columns, rows)
  if format == "json"     then return to_json(columns, rows) end
  if format == "csv"      then return to_csv(columns, rows) end
  if format == "pretty"   then return to_pretty(columns, rows) end
  if format == "markdown" then return to_markdown(columns, rows) end
  error("unknown export format: " .. tostring(format))
end

--- Return the display string for a cell value, mapping NULL (nil/vim.NIL) to ""
--- and a LobPlaceholder object to its server-formatted `text`.
--- @param cell any
--- @return string
local function plain_cell(cell)
  if cell == nil or cell == vim.NIL then return "" end
  if type(cell) == "table" and cell.type == "lob" then return cell.text end
  return tostring(cell)
end

--- Quote a CSV field if it contains a comma, quote, or newline.
--- @param s string
--- @return string
local function csv_escape(s)
  if s:find('[,"\n]') then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

--- Escape a markdown table cell: pipes break columns, newlines break rows.
--- @param s string
--- @return string
local function md_escape(s)
  return (s:gsub("|", "\\|"):gsub("\n", " "))
end

--- Right-pad `s` with spaces so its display width equals `width`.
--- @param s     string
--- @param width integer
--- @return string
local function pad(s, width)
  return s .. string.rep(" ", width - vim.api.nvim_strwidth(s))
end

--- Serialize rows as a pretty-printed JSON array of objects, columns in order.
--- @param columns string[]
--- @param rows    any[][]
--- @return string
to_json = function(columns, rows)
  local row_strs = {}
  for _, row in ipairs(rows) do
    local field_strs = {}
    for i, col in ipairs(columns) do
      local key = vim.json.encode(col)
      local val = vim.json.encode(row[i] == nil and vim.NIL or row[i])
      table.insert(field_strs, "    " .. key .. ": " .. val)
    end
    table.insert(row_strs, "  {\n" .. table.concat(field_strs, ",\n") .. "\n  }")
  end
  if #row_strs == 0 then return "[]" end
  return "[\n" .. table.concat(row_strs, ",\n") .. "\n]"
end

--- Serialize rows as RFC4180-style CSV with a header row; NULL becomes an empty field.
--- @param columns string[]
--- @param rows    any[][]
--- @return string
to_csv = function(columns, rows)
  local lines  = {}
  local header = {}
  for _, c in ipairs(columns) do table.insert(header, csv_escape(c)) end
  table.insert(lines, table.concat(header, ","))

  for _, row in ipairs(rows) do
    local cells = {}
    for i = 1, #columns do
      table.insert(cells, csv_escape(plain_cell(row[i])))
    end
    table.insert(lines, table.concat(cells, ","))
  end
  return table.concat(lines, "\n")
end

--- Serialize rows as the same box-drawing table rendered in the results pane.
--- @param columns string[]
--- @param rows    any[][]
--- @return string
to_pretty = function(columns, rows)
  local display = { columns }
  for _, row in ipairs(rows) do table.insert(display, row) end
  local tbl = table_fmt.from_structured_data(display, 1)
  return table.concat(tbl.text, "\n")
end

--- Serialize rows as a column-aligned GitHub-flavored markdown table.
--- @param columns string[]
--- @param rows    any[][]
--- @return string
to_markdown = function(columns, rows)
  local header_cells = {}
  for _, c in ipairs(columns) do table.insert(header_cells, md_escape(c)) end

  local data_rows = {}
  for _, row in ipairs(rows) do
    local cells = {}
    for i = 1, #columns do
      table.insert(cells, md_escape(plain_cell(row[i])))
    end
    table.insert(data_rows, cells)
  end

  -- GFM requires at least 3 dashes per separator cell.
  local widths = {}
  for i, c in ipairs(header_cells) do widths[i] = math.max(3, vim.api.nvim_strwidth(c)) end
  for _, cells in ipairs(data_rows) do
    for i, c in ipairs(cells) do widths[i] = math.max(widths[i], vim.api.nvim_strwidth(c)) end
  end

  --- Render one row of already-escaped cells as a padded markdown table line.
  --- @param cells string[]
  --- @return string
  local function render_row(cells)
    local padded = {}
    for i, c in ipairs(cells) do table.insert(padded, pad(c, widths[i])) end
    return "| " .. table.concat(padded, " | ") .. " |"
  end

  local seps = {}
  for i = 1, #columns do table.insert(seps, string.rep("-", widths[i])) end

  local lines = { render_row(header_cells), render_row(seps) }
  for _, cells in ipairs(data_rows) do table.insert(lines, render_row(cells)) end
  return table.concat(lines, "\n")
end

return M
