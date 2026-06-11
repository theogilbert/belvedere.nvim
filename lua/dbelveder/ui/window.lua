-- Shared window helpers for dbelveder's sidebar panels.
local M = {}

local SIDEBAR_WIDTH = 35

--- Open `buf` in a vertical sidebar split and apply the shared panel chrome.
--- @param buf integer
--- @param side "left"|"right"
--- @return integer winid  the newly created (and focused) window
function M.open_sidebar(buf, side)
  local anchor = side == "left" and "topleft" or "botright"
  vim.cmd(anchor .. " " .. SIDEBAR_WIDTH .. "vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_set_option_value("number",     false,   { win = win })
  vim.api.nvim_set_option_value("signcolumn", "no",    { win = win })
  vim.api.nvim_set_option_value("fillchars",  "eob: ", { win = win })
  return win
end

return M
