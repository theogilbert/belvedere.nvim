local M = {}

local NS

local ICON_RUNNING = "\xEE\xA9\xB7"  -- U+EA77
local ICON_SUCCESS = "\xEE\xAA\xB2"  -- U+EAB2
local ICON_ERROR   = "\xEE\xAA\xB8"  -- U+EAB8

function M.setup()
  NS = vim.api.nvim_create_namespace("BelvedereGutter")
end

local function get_mark_row(bufnr, mark_id)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, {})) do
    if m[1] == mark_id then return m[2] end
  end
end

local function replace(handle, icon, hl)
  if not handle or not vim.api.nvim_buf_is_valid(handle.bufnr) then return end
  local row = get_mark_row(handle.bufnr, handle.mark_id)
  if not row then return end
  vim.api.nvim_buf_set_extmark(handle.bufnr, NS, row, 0, {
    id            = handle.mark_id,
    sign_text     = icon,
    sign_hl_group = hl,
    priority      = 100,
  })
end

-- Replace any existing mark on this line with the running icon and return a handle.
function M.show_running(bufnr, line)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, NS, {line, 0}, {line, -1}, {})) do
    vim.api.nvim_buf_del_extmark(bufnr, NS, m[1])
  end
  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, NS, line, 0, {
    sign_text     = ICON_RUNNING,
    sign_hl_group = "BelvedereQueryRunning",
    priority      = 100,
  })
  return { bufnr = bufnr, mark_id = mark_id }
end

function M.show_success(handle)
  replace(handle, ICON_SUCCESS, "BelvedereQuerySuccess")
end

function M.show_error(handle)
  replace(handle, ICON_ERROR, "BelvedereQueryError")
end

return M
