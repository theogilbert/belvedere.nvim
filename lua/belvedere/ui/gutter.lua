local M = {}

local NS
local running = {}  -- [bufnr][mark_id] = request_id

local ICON_RUNNING = "\xEE\xA9\xB7"  -- U+EA77
local ICON_SUCCESS = "\xEE\xAA\xB2"  -- U+EAB2
local ICON_ERROR   = "\xEE\xAA\xB8"  -- U+EAB8

function M.setup()
  NS = vim.api.nvim_create_namespace("BelvedereGutter")
end

local function get_mark_row(bufnr, mark_id)
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS, mark_id, {})
  return pos[1]
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

function M.register_request(handle, request_id)
  if not handle or not request_id then return end
  running[handle.bufnr] = running[handle.bufnr] or {}
  running[handle.bufnr][handle.mark_id] = request_id
end

function M.unregister_request(handle)
  if not handle then return end
  local by_buf = running[handle.bufnr]
  if by_buf then by_buf[handle.mark_id] = nil end
end

-- Returns the request_id of a running query whose gutter mark sits on `line`
-- (0-indexed), or nil if none.
function M.find_request_at_line(bufnr, line)
  local by_buf = running[bufnr]
  if not by_buf then return nil end
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, { line, 0 }, { line, -1 }, {})
  for _, m in ipairs(marks) do
    local req_id = by_buf[m[1]]
    if req_id then return req_id end
  end
  return nil
end

return M
