local M = {}

--- Return true when Neovim is currently in any visual mode (char, line, or block).
--- @return boolean
function M.is_in_visual_mode()
  local mode = vim.fn.mode()
  return mode == "v" or mode == "V" or mode == "\22"
end

--- Return the current visual selection as a trimmed string, or nil if not in visual mode.
--- @return string|nil
function M.get_selection()
  if not M.is_in_visual_mode() then return nil end

  local _, start_row, start_col = unpack(vim.fn.getpos("v"))
  local _, end_row,   end_col   = unpack(vim.fn.getpos("."))

  if start_row > end_row or (start_row == end_row and start_col > end_col) then
    start_row, end_row = end_row, start_row
    start_col, end_col = end_col, start_col
  end

  local lines = vim.fn.getline(start_row, end_row)
  if #lines == 0 then return "" end
  if type(lines) == "string" then lines = { lines } end

  if vim.fn.mode() ~= "V" then
    lines[1]      = string.sub(lines[1], start_col)
    lines[#lines] = string.sub(lines[#lines], 1, end_col)
  end
  -- TODO: handle block visual mode

  return vim.trim(table.concat(lines, "\n"))
end

return M
