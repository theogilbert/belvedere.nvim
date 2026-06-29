local M = {}

--- Open a non-focusable hover float near the cursor displaying `lines`.
--- The float closes automatically when the cursor moves or `source_bufnr` is left.
--- @param lines      string[]  lines to display
--- @param source_bufnr integer  buffer to attach the autoclose autocmd to
function M.open(lines, source_bufnr)
  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, #l) end

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].modifiable = false

  local win = vim.api.nvim_open_win(float_buf, false, {
    relative  = "cursor",
    row       = 1,
    col       = 0,
    width     = width,
    height    = #lines,
    style     = "minimal",
    border    = "rounded",
    focusable = false,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufLeave" }, {
    buffer   = source_bufnr,
    once     = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end,
  })
end

return M
