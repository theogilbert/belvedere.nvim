-- A floating "Connected to <name>" label pinned to the bottom-left of each
-- window whose buffer has an associated connection.  The labels follow window
-- resizes and disappear when the association or the window goes away.
local M = {}

local labels  = {}                       -- [winid] -> { win = fwin, width = w, name = s }
local resolve = function() return nil end -- bufnr -> connection name | nil

--- Return the nvim_open_win config for a label float: right-aligned, sized to the text.
--- @param winid integer
--- @param width integer  display-column width of the label text
--- @return table
local function geometry(winid, width)
  local win_width = vim.api.nvim_win_get_width(winid)
  return {
    relative = "win",
    win      = winid,
    row      = vim.api.nvim_win_get_height(winid) - 1,
    col      = win_width - width,
    width    = width,
    height   = 1,
  }
end

--- Remove the label float for `winid`, if any.
--- @param winid integer
function M.hide(winid)
  local entry = labels[winid]
  if entry and vim.api.nvim_win_is_valid(entry.win) then
    vim.api.nvim_win_close(entry.win, true)
  end
  labels[winid] = nil
end

--- Show (replacing any existing) the connection label for `winid`.
--- @param winid integer
--- @param name  string  human-readable connection name
function M.show(winid, name)
  M.hide(winid)
  local text = "Connected to " .. name
  local w    = vim.fn.strdisplaywidth(text)
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = fbuf })
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { text })
  vim.api.nvim_buf_add_highlight(fbuf, -1, "BelvedereConnection", 0, 0, -1)

  local cfg = geometry(winid, w)
  cfg.style, cfg.focusable, cfg.zindex = "minimal", false, 10
  local fwin = vim.api.nvim_open_win(fbuf, false, cfg)
  vim.api.nvim_set_option_value("winhl", "Normal:Normal,NormalFloat:Normal", { win = fwin })
  labels[winid] = { win = fwin, width = w, name = name }
end

--- Reposition an existing label after its parent window was resized.
--- @param winid integer
local function reposition(winid)
  local entry = labels[winid]
  if not (entry and vim.api.nvim_win_is_valid(entry.win)) then return end
  vim.api.nvim_win_set_config(entry.win, geometry(winid, entry.width))
end

--- Show, move, or remove the label for `winid` based on its current buffer's connection.
--- @param winid integer
local function refresh(winid)
  if not vim.api.nvim_win_is_valid(winid) then return end
  -- Skip floating windows (our own labels and other plugins').
  if vim.api.nvim_win_get_config(winid).relative ~= "" then return end
  local name = resolve(vim.api.nvim_win_get_buf(winid))
  if name then
    local entry = labels[winid]
    if entry and entry.name == name then reposition(winid) else M.show(winid, name) end
  else
    M.hide(winid)
  end
end

--- Remove every label (called on backend teardown).
function M.clear_all()
  for winid in pairs(labels) do
    local entry = labels[winid]
    if entry and vim.api.nvim_win_is_valid(entry.win) then
      vim.api.nvim_win_close(entry.win, true)
    end
  end
  labels = {}
end

--- Install the autocmds that keep labels in sync and set the buffer→name resolver.
--- @param resolve_fn fun(bufnr: integer): string|nil  returns the connection name or nil
function M.setup(resolve_fn)
  resolve = resolve_fn
  local aug = vim.api.nvim_create_augroup("BelvedereConnLabels", { clear = true })
  -- Show or hide the label whenever the buffer in the current window changes.
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
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
