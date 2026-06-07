-- Formats a sequence of row arrays into a box-drawing-character table.
-- Adapted from utilities/table.lua (nvim-dap-df project) — CSV parsing removed.
local M = {}

M.COL_SEPARATOR = "│"

local function center(text, width)
  local space = (width - vim.api.nvim_strwidth(text)) / 2
  return string.rep(" ", math.floor(space)) .. text .. string.rep(" ", math.ceil(space))
end

local function update_col_widths(cols, widths)
  for i, cell in ipairs(cols) do
    widths[i] = math.max(widths[i] or 2, vim.api.nvim_strwidth(tostring(cell or "")) + 2)
  end
end

local function build_separator(widths)
  local parts = {}
  for i, w in ipairs(widths) do parts[i] = string.rep("─", w) end
  return "├" .. table.concat(parts, "┼") .. "┤"
end

--- Build a FormattedTable from a list of row arrays.
--- @param lines table    rows, each an array of cell values
--- @param header_lines integer|nil  rows to treat as header (default 1)
--- @return table  { lines, columns_width, text }
function M.from_structured_data(lines, header_lines)
  header_lines = header_lines or 1
  local widths = {}
  for _, row in ipairs(lines) do update_col_widths(row, widths) end

  local formatted = {}
  for _, row in ipairs(lines) do
    local cells = {}
    for i, cell in ipairs(row) do
      cells[i] = center(tostring(cell or ""), widths[i])
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
    if row and row[i] then
      local s      = tostring(row[i])
      cell_bytes   = width - vim.api.nvim_strwidth(s) + #s
    else
      cell_bytes   = width
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
--- @param tbl table          FormattedTable from from_structured_data
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

--- Set up box-drawing character highlighting for a buffer that shows a table.
--- Call once after creating the buffer.
--- @param buf_id integer
function M.setup_buf_hl(buf_id)
  vim.api.nvim_buf_call(buf_id, function()
    vim.cmd("syntax match DbelvederTableBorder /[│├┼─┤]/")
  end)
  vim.cmd("highlight link DbelvederTableBorder DbelvederBorder")
end

return M
