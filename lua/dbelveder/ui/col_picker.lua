-- Floating two-panel column picker.
--
-- Left panel:  available (unselected) columns.
-- Right panel: selected columns (in display order).
-- j/k navigate within the focused panel; h/l switch panels.
-- Tab/Enter/Space move the item under the cursor to the other panel.
-- K/J (right panel only) move the item under the cursor up/down.
-- q/Esc close (changes are already applied live via the on_change callback).
local hl        = require("dbelveder.hl")
local table_fmt = require("dbelveder.table")

local M = {}

local ns_id   = vim.api.nvim_create_namespace("dbelveder_col_picker")
local SEP     = "│"
local SEP_LEN = #SEP  -- 3 bytes for the UTF-8 box-drawing character

local function pad(s, width)
  return s .. string.rep(" ", math.max(0, width - vim.api.nvim_strwidth(s)))
end

-- One picker at a time.
local p = {}

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
    { end_col = cw, hl_group = "DbelvederHeaderRow" })
  vim.api.nvim_buf_set_extmark(p.buf, ns_id, 0, cw + SEP_LEN,
    { end_col = cw + SEP_LEN + cw, hl_group = "DbelvederHeaderRow" })

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

local function close()
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    vim.api.nvim_win_close(p.win, true)
  end
end

-- Re-insert col into available while preserving the original column order.
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

local function reorder(delta)
  if p.side ~= "right" then return end
  local target = p.cursor + delta
  if target < 1 or target > #p.selected then return end
  p.selected[p.cursor], p.selected[target] = p.selected[target], p.selected[p.cursor]
  p.cursor = target
  render()
  if p.on_change then p.on_change(vim.list_extend({}, p.selected)) end
end

local function move_item()
  if p.side == "left" then
    local col = table.remove(p.available, p.cursor)
    if not col then return end
    table.insert(p.selected, col)
    p.cursor = math.min(p.cursor, math.max(#p.available, 1))
    if #p.available == 0 then p.side = "right"; p.cursor = #p.selected end
  else
    if #p.selected <= 1 then return end  -- always keep at least one column
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
    buf       = buf,
    win       = nil,
    available = available,
    selected  = vim.list_extend({}, vis_cols),
    all_cols  = all_cols,
    side      = #available > 0 and "left" or "right",
    cursor    = 1,
    col_width = col_width,
    on_change = on_change,
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

  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true })
  end

  map("q",       close)
  map("<Esc>",   close)
  map("j",       function()
    local list = p.side == "left" and p.available or p.selected
    p.cursor   = math.min(p.cursor + 1, math.max(#list, 1))
    render()
  end)
  map("<Down>",  function()
    local list = p.side == "left" and p.available or p.selected
    p.cursor   = math.min(p.cursor + 1, math.max(#list, 1))
    render()
  end)
  map("k",       function() p.cursor = math.max(1, p.cursor - 1); render() end)
  map("<Up>",    function() p.cursor = math.max(1, p.cursor - 1); render() end)
  map("h",       function()
    p.side   = "left"
    p.cursor = math.min(p.cursor, math.max(#p.available, 1))
    render()
  end)
  map("<Left>",  function()
    p.side   = "left"
    p.cursor = math.min(p.cursor, math.max(#p.available, 1))
    render()
  end)
  map("l",       function()
    p.side   = "right"
    p.cursor = math.min(p.cursor, math.max(#p.selected, 1))
    render()
  end)
  map("<Right>", function()
    p.side   = "right"
    p.cursor = math.min(p.cursor, math.max(#p.selected, 1))
    render()
  end)
  map("<Tab>",   move_item)
  map("<CR>",    move_item)
  map("<Space>", move_item)
  map("K",       function() reorder(-1) end)
  map("J",       function() reorder(1)  end)

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
