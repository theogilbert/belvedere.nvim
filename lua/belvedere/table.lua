-- Formats a sequence of row arrays into a box-drawing-character table.
-- Adapted from utilities/table.lua (nvim-dap-df project) — CSV parsing removed.
local M = {}

--- @class FormattedTable
--- @field lines         any[][]    raw row arrays (first row is the header)
--- @field columns_width integer[]  display-column widths per column
--- @field text          string[]   rendered lines ready to set into a buffer

M.COL_SEPARATOR = "│"

-- Display string for JSON null values (vim.NIL sentinel).
local NULL_TEXT = "NULL"

--- Return the display string for a cell value, mapping vim.NIL → "NULL".
--- @param cell any
--- @return string
local function cell_display(cell)
  if cell == vim.NIL then return NULL_TEXT end
  if cell == nil     then return "" end
  return tostring(cell)
end

--- Center `text` within `width` display columns using space padding.
--- @param text  string
--- @param width integer
--- @return string
local function center(text, width)
  local space = (width - vim.api.nvim_strwidth(text)) / 2
  return string.rep(" ", math.floor(space)) .. text .. string.rep(" ", math.ceil(space))
end

--- Expand `widths[i]` to fit the display width of each cell in `cols` (with 1-space padding each side).
--- @param cols   table    array of cell values
--- @param widths integer[]  mutable column-width array
local function update_col_widths(cols, widths)
  for i, cell in ipairs(cols) do
    widths[i] = math.max(widths[i] or 2, vim.api.nvim_strwidth(cell_display(cell)) + 2)
  end
end

--- Build the ├──┼──┤ separator row for the given column widths.
--- @param widths integer[]
--- @return string
local function build_separator(widths)
  local parts = {}
  for i, w in ipairs(widths) do parts[i] = string.rep("─", w) end
  return "├" .. table.concat(parts, "┼") .. "┤"
end

--- Build a FormattedTable from a list of row arrays.
--- @param lines table    rows, each an array of cell values
--- @param header_lines integer|nil  rows to treat as header (default 1)
--- @return FormattedTable
function M.from_structured_data(lines, header_lines)
  header_lines = header_lines or 1
  local widths = {}
  for _, row in ipairs(lines) do update_col_widths(row, widths) end

  local formatted = {}
  for _, row in ipairs(lines) do
    local cells = {}
    for i, cell in ipairs(row) do
      cells[i] = center(cell_display(cell), widths[i])
    end
    table.insert(formatted, M.COL_SEPARATOR .. table.concat(cells, M.COL_SEPARATOR) .. M.COL_SEPARATOR)
  end

  if header_lines > 0 and header_lines <= #formatted then
    table.insert(formatted, header_lines + 1, build_separator(widths))
  end

  return { lines = lines, columns_width = widths, text = formatted }
end

--- Return the 1-indexed column at a virtual cursor position,
--- or nil when the cursor is on a separator.
--- @param cols_width integer[]
--- @param virtual_col integer  1-indexed
--- @return integer|nil
function M.get_column_at_cursor(cols_width, virtual_col)
  local pos = 2  -- skip leading │
  for i, w in ipairs(cols_width) do
    if virtual_col >= pos and virtual_col < pos + w then return i end
    pos = pos + w + 1
  end
  return nil
end

local SEP_BYTES = #M.COL_SEPARATOR

--- Return the virtual-column positions of each column boundary (left edge of
--- the leading separator + each trailing separator).  The first entry is always
--- 0 (left edge of the table); the last is the right edge.
--- @param cols_width integer[]
--- @return integer[]
function M.column_boundaries(cols_width)
  local boundaries, pos = { 0 }, 0
  for _, w in ipairs(cols_width) do
    pos = pos + w + 1  -- cell width + │
    boundaries[#boundaries + 1] = pos
  end
  return boundaries
end

--- Compute the byte {start, finish} of each column cell in a formatted line.
--- Accounts for multi-byte cell content so positions are valid for vim.hl.range.
--- @param row table|nil   raw cell values for this row
--- @param cols_width integer[]
--- @return table   list of {byte_start, byte_end} per column
function M.column_byte_positions(row, cols_width)
  local positions = {}
  local byte_pos  = SEP_BYTES  -- skip leading │
  for i, width in ipairs(cols_width) do
    local cell_bytes
    if row then
      local s    = cell_display(row[i])
      cell_bytes = width - vim.api.nvim_strwidth(s) + #s
    else
      cell_bytes = width
    end
    positions[i] = { byte_pos, byte_pos + cell_bytes }
    byte_pos     = byte_pos + cell_bytes + SEP_BYTES
  end
  return positions
end

--- Build per-column highlight rules for one buffer line.
--- @param higroup string
--- @param buf_line integer   0-indexed buffer row
--- @param data_line integer  1-indexed into tbl.lines
--- @param tbl FormattedTable
--- @return table   list of { higroup, start, finish } rules
function M.col_hl_rules(higroup, buf_line, data_line, tbl)
  if not tbl then return {} end
  local positions = M.column_byte_positions(tbl.lines[data_line], tbl.columns_width)
  local rules     = {}
  for i, pos in ipairs(positions) do
    rules[i] = { higroup = higroup,
                 start   = { buf_line, pos[1] },
                 finish  = { buf_line, pos[2] } }
  end
  return rules
end

--- Return highlight rules for all NULL (vim.NIL) cells in the data rows.
--- @param tbl FormattedTable
--- @return table   list of { higroup, start, finish } rules
function M.null_hl_rules(tbl)
  local rules = {}
  -- tbl.lines[1] = header; data rows start at tbl.lines[2].
  -- With one separator after the header, data row i maps to 0-indexed buffer line i.
  for i = 2, #tbl.lines do
    local row      = tbl.lines[i]
    local buf_line = i
    local positions = M.column_byte_positions(row, tbl.columns_width)
    for j, cell in ipairs(row) do
      if cell == vim.NIL then
        rules[#rules + 1] = {
          higroup = "BelvedereNull",
          start   = { buf_line, positions[j][1] },
          finish  = { buf_line, positions[j][2] },
        }
      end
    end
  end
  return rules
end


--- Set up box-drawing character highlighting for a buffer that shows a table.
--- Call once after creating the buffer.
--- @param buf_id integer
function M.setup_buf_hl(buf_id)
  vim.api.nvim_buf_call(buf_id, function()
    vim.cmd("syntax match BelvedereTableBorder /[│├┼─┤]/")
  end)
  vim.cmd("highlight link BelvedereTableBorder BelvedereBorder")
end

return M
