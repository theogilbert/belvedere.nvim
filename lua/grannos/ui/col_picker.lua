-- Floating two-panel column picker.
--
-- Left panel:  available (unselected) columns.
-- Right panel: selected columns (in display order).
-- j/k navigate within the focused panel; h/l switch panels.
-- Tab/Enter/Space move the item under the cursor to the other panel.
-- K/J (right panel only) move the item under the cursor up/down.
-- >   move all available columns to selected.
-- <   move all selected columns back to available.
-- r   reset selection to its state when the picker was opened.
-- q/Esc close (changes are already applied live via the on_change callback).
local hl        = require("grannos.hl")
local table_fmt = require("grannos.table")

local M = {}

local ns_id   = vim.api.nvim_create_namespace("grannos_col_picker")
local SEP     = "│"
local SEP_LEN = #SEP  -- 3 bytes for the UTF-8 box-drawing character

--- Right-pad `s` with spaces so its display width equals `width`.
--- @param s     string
--- @param width integer
--- @return string
local function pad(s, width)
  return s .. string.rep(" ", math.max(0, width - vim.api.nvim_strwidth(s)))
end

-- One picker at a time.
local p = {}

--- Redraw the picker buffer from the current picker state.
local function render()
  if not p.buf or not vim.api.nvim_buf_is_valid(p.buf) then return end

  local cw    = p.col_width
  local lines = {}

  -- Header
  table.insert(lines, pad("  Available columns", cw) .. SEP .. pad("  Selected columns", cw))
  -- Separator row
  table.insert(lines, string.rep("─", cw) .. "┼" .. string.rep("─", cw))

  -- Item rows — pad both sides so every line is exactly cw+SEP_LEN+cw bytes
  local n = math.max(#p.available, #p.selected, 1)
  for i = 1, n do
    local ltext = p.available[i] and ("  " .. p.available[i]) or ""
    local rtext = p.selected[i]  and ("  " .. p.selected[i])  or ""
    table.insert(lines, pad(ltext, cw) .. SEP .. pad(rtext, cw))
  end

  vim.api.nvim_buf_set_lines(p.buf, 0, -1, false, lines)

  vim.api.nvim_buf_clear_namespace(p.buf, ns_id, 0, -1)

  -- Header text
  vim.api.nvim_buf_set_extmark(p.buf, ns_id, 0, 0,
    { end_col = cw, hl_group = "GrannosHeaderRow" })
  vim.api.nvim_buf_set_extmark(p.buf, ns_id, 0, cw + SEP_LEN,
    { end_col = cw + SEP_LEN + cw, hl_group = "GrannosHeaderRow" })

  -- Cursor highlight (0-indexed: header=0, sep-row=1, items start at 2)
  local item_lnum = p.cursor + 1
  if p.side == "left" and p.available[p.cursor] then
    vim.api.nvim_buf_set_extmark(p.buf, ns_id, item_lnum, 0,
      { end_col = cw, hl_group = "PmenuSel" })
  elseif p.side == "right" and p.selected[p.cursor] then
    vim.api.nvim_buf_set_extmark(p.buf, ns_id, item_lnum, cw + SEP_LEN,
      { end_col = cw + SEP_LEN + cw, hl_group = "PmenuSel" })
  end

  -- Keep the Neovim cursor on the highlighted item so the window auto-scrolls.
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    local nvim_col = p.side == "right" and (cw + SEP_LEN) or 0
    pcall(vim.api.nvim_win_set_cursor, p.win, { item_lnum + 1, nvim_col })
  end
end

--- Close the picker window.
local function close()
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    vim.api.nvim_win_close(p.win, true)
  end
end

--- Re-insert `col` into the available list while preserving original column order.
--- @param col string
local function insert_sorted_available(col)
  local rank = {}
  for i, c in ipairs(p.all_cols) do rank[c] = i end
  local cr = rank[col]
  for i, ac in ipairs(p.available) do
    if rank[ac] > cr then
      table.insert(p.available, i, col)
      return
    end
  end
  table.insert(p.available, col)
end

--- Move the focused item in the selected list up (`delta` = -1) or down (+1).
--- @param delta integer
local function reorder(delta)
  if p.side ~= "right" then return end
  local target = p.cursor + delta
  if target < 1 or target > #p.selected then return end
  p.selected[p.cursor], p.selected[target] = p.selected[target], p.selected[p.cursor]
  p.cursor = target
  render()
  if p.on_change then p.on_change(vim.list_extend({}, p.selected)) end
end

--- Restore available and selected to the state when the picker was opened.
local function reset()
  p.available = vim.list_extend({}, p.init_available)
  p.selected  = vim.list_extend({}, p.init_selected)
  p.side      = #p.init_available > 0 and "left" or "right"
  p.cursor    = 1
  render()
  if p.on_change then p.on_change(vim.list_extend({}, p.selected)) end
end

--- Move all available columns into selected.
local function select_all()
  for _, col in ipairs(p.available) do
    table.insert(p.selected, col)
  end
  p.available = {}
  p.side      = "right"
  p.cursor    = math.min(p.cursor, math.max(#p.selected, 1))
  render()
  if p.on_change then p.on_change(vim.list_extend({}, p.selected)) end
end

--- Move all selected columns back to available (in original order).
local function deselect_all()
  for _, col in ipairs(p.selected) do
    insert_sorted_available(col)
  end
  p.selected = {}
  p.side     = "left"
  p.cursor   = math.min(p.cursor, math.max(#p.available, 1))
  render()
  if p.on_change then p.on_change({}) end
end

--- Move the item under the cursor between available and selected.
local function move_item()
  if p.side == "left" then
    local col = table.remove(p.available, p.cursor)
    if not col then return end
    table.insert(p.selected, col)
    p.cursor = math.min(p.cursor, math.max(#p.available, 1))
    if #p.available == 0 then p.side = "right"; p.cursor = #p.selected end
  else
    local col = table.remove(p.selected, p.cursor)
    insert_sorted_available(col)
    p.cursor = math.min(p.cursor, math.max(#p.selected, 1))
    if #p.selected == 0 then p.side = "left"; p.cursor = 1 end
  end
  render()
  if p.on_change then p.on_change(vim.list_extend({}, p.selected)) end
end

--- Open the column picker.
--- @param all_cols  string[]  all column names in original order
--- @param vis_cols  string[]  currently visible column names
--- @param on_change fun(selected: string[])  called live on every toggle
function M.open(all_cols, vis_cols, on_change)
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    vim.api.nvim_set_current_win(p.win)
    return
  end

  local vis_set  = {}
  for _, c in ipairs(vis_cols) do vis_set[c] = true end
  local available = {}
  for _, c in ipairs(all_cols) do
    if not vis_set[c] then table.insert(available, c) end
  end

  local col_width = vim.api.nvim_strwidth("  Available columns")
  for _, c in ipairs(all_cols) do
    col_width = math.max(col_width, vim.api.nvim_strwidth(c) + 2)
  end

  local inner_h = math.min(#all_cols + 2, vim.o.lines - 8)
  local inner_w = col_width * 2 + SEP_LEN
  local row     = math.max(0, math.floor((vim.o.lines   - inner_h - 2) / 2))
  local col     = math.max(0, math.floor((vim.o.columns - inner_w - 2) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  table_fmt.setup_buf_hl(buf)

  p = {
    buf            = buf,
    win            = nil,
    available      = available,
    selected       = vim.list_extend({}, vis_cols),
    init_available = vim.list_extend({}, available),
    init_selected  = vim.list_extend({}, vis_cols),
    all_cols       = all_cols,
    side           = #available > 0 and "left" or "right",
    cursor         = 1,
    col_width      = col_width,
    on_change      = on_change,
  }

  render()

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = row,
    col       = col,
    width     = inner_w,
    height    = inner_h,
    style     = "minimal",
    border    = "rounded",
    title     = " Columns ",
    title_pos = "center",
  })
  p.win = win

  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)
  vim.api.nvim_set_option_value("number",     false, { win = win })
  vim.api.nvim_set_option_value("signcolumn", "no",  { win = win })
  vim.api.nvim_set_option_value("wrap",       false, { win = win })
  vim.api.nvim_set_option_value("cursorline", false, { win = win })

  render()  -- second call positions the Neovim cursor now that p.win is set

  --- Register a normal-mode keymap on the picker buffer.
  --- @param key string
  --- @param fn  fun()
  --- @param desc string
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  --- Open a floating keymap cheatsheet for the picker.
  local function show_help()
    local keymaps = vim.api.nvim_buf_get_keymap(buf, "n")
    local lines   = {}
    for _, km in ipairs(keymaps) do
      if km.desc and km.desc ~= "" then
        local lhs = km.lhs:gsub("^<lt>$", "<")
      table.insert(lines, string.format("  %-10s  %s", lhs, km.desc))
      end
    end
    table.sort(lines)
    if #lines == 0 then return end
    local width = 0
    for _, l in ipairs(lines) do width = math.max(width, #l) end
    local hbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, lines)
    vim.bo[hbuf].modifiable = false
    vim.bo[hbuf].bufhidden  = "wipe"
    local hwin = vim.api.nvim_open_win(hbuf, true, {
      relative  = "cursor",
      row       = 1,
      col       = 0,
      width     = width,
      height    = #lines,
      style     = "minimal",
      border    = "rounded",
      title     = " keymaps ",
      title_pos = "center",
    })
    for _, key in ipairs({ "q", "<Esc>", "g?" }) do
      vim.keymap.set("n", key, function() pcall(vim.api.nvim_win_close, hwin, true) end,
        { buffer = hbuf, silent = true })
    end
  end

  --- Move cursor to the next item in the focused panel.
  local function nav_down()
    local list = p.side == "left" and p.available or p.selected
    p.cursor   = math.min(p.cursor + 1, math.max(#list, 1))
    render()
  end
  --- Move cursor to the previous item in the focused panel.
  local function nav_up()   p.cursor = math.max(1, p.cursor - 1); render() end
  --- Switch focus to the available (left) panel.
  local function nav_left()
    p.side   = "left"
    p.cursor = math.min(p.cursor, math.max(#p.available, 1))
    render()
  end
  --- Switch focus to the selected (right) panel.
  local function nav_right()
    p.side   = "right"
    p.cursor = math.min(p.cursor, math.max(#p.selected, 1))
    render()
  end

  map("q",       close,      "Close")
  map("<Esc>",   close,      "")
  map("j",       nav_down,   "Move cursor down")
  map("<Down>",  nav_down,   "")
  map("k",       nav_up,     "Move cursor up")
  map("<Up>",    nav_up,     "")
  map("h",       nav_left,   "Focus available panel")
  map("<Left>",  nav_left,   "")
  map("l",       nav_right,  "Focus selected panel")
  map("<Right>", nav_right,  "")
  map("<Tab>",   move_item,  "Toggle column")
  map("<CR>",    move_item,  "")
  map("<Space>", move_item,  "")
  map("K",       function() reorder(-1) end, "Move column up")
  map("J",       function() reorder(1)  end, "Move column down")
  map(">",       select_all,   "Select all")
  map("<",       deselect_all, "Deselect all")
  map("r",       reset,        "Reset to initial selection")
  map("g?",      show_help,    "Show keymaps")

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(win),
    once     = true,
    callback = function()
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      p = {}
    end,
  })
end

return M
