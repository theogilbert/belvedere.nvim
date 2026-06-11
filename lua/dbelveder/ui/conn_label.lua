-- A floating "Connected to <name>" label pinned to the bottom-left of each
-- window whose buffer has an associated connection.  The labels follow window
-- resizes and disappear when the association or the window goes away.
local M = {}

local labels  = {}                       -- [winid] -> label float winid
local resolve = function() return nil end -- bufnr -> connection name | nil

-- Geometry shared by show() and reposition(): a one-row strip along the bottom.
local function geometry(winid)
  return {
    relative = "win",
    win      = winid,
    row      = vim.api.nvim_win_get_height(winid) - 1,
    col      = 0,
    width    = vim.api.nvim_win_get_width(winid),
    height   = 1,
  }
end

--- Remove the label for `winid`, if any.
function M.hide(winid)
  local fwin = labels[winid]
  if fwin and vim.api.nvim_win_is_valid(fwin) then
    vim.api.nvim_win_close(fwin, true)
  end
  labels[winid] = nil
end

--- Show (replacing any existing) the label for `winid`.
function M.show(winid, name)
  M.hide(winid)
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = fbuf })
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "Connected to " .. name })
  vim.api.nvim_buf_add_highlight(fbuf, -1, "DbelvederConnection", 0, 0, -1)

  local cfg = geometry(winid)
  cfg.style, cfg.focusable, cfg.zindex = "minimal", false, 10
  local fwin = vim.api.nvim_open_win(fbuf, false, cfg)
  vim.api.nvim_set_option_value("winhl", "Normal:Normal,NormalFloat:Normal", { win = fwin })
  labels[winid] = fwin
end

-- Reposition an existing label after its parent window was resized.
local function reposition(winid)
  local fwin = labels[winid]
  if not (fwin and vim.api.nvim_win_is_valid(fwin)) then return end
  vim.api.nvim_win_set_config(fwin, geometry(winid))
end

-- Show, move, or remove the label for a window based on its current buffer.
local function refresh(winid)
  if not vim.api.nvim_win_is_valid(winid) then return end
  -- Skip floating windows (our own labels and other plugins').
  if vim.api.nvim_win_get_config(winid).relative ~= "" then return end
  local name = resolve(vim.api.nvim_win_get_buf(winid))
  if name then
    if labels[winid] then reposition(winid) else M.show(winid, name) end
  else
    M.hide(winid)
  end
end

--- Remove every label (backend teardown).
function M.clear_all()
  for winid in pairs(labels) do M.hide(winid) end
  labels = {}
end

--- Install the autocmds that keep labels in sync.
--- @param resolve_fn fun(bufnr: integer): string|nil  buffer -> connection name
function M.setup(resolve_fn)
  resolve = resolve_fn
  local aug = vim.api.nvim_create_augroup("DbelvederConnLabels", { clear = true })
  -- Show or hide the label whenever the buffer in the current window changes.
  vim.api.nvim_create_autocmd("BufEnter", {
    group    = aug,
    callback = function() refresh(vim.api.nvim_get_current_win()) end,
  })
  -- Reposition all labels when any window is resized.
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group    = aug,
    callback = function()
      for winid in pairs(labels) do reposition(winid) end
    end,
  })
  -- Clean up the label entry when a window closes.
  vim.api.nvim_create_autocmd("WinClosed", {
    group    = aug,
    callback = function(ev) M.hide(tonumber(ev.match)) end,
  })
end

return M
