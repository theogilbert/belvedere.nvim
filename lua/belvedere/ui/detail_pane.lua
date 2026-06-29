-- Shared infrastructure for two-pane and single-item detail floats.
-- Consumers supply item-specific rendering; this module handles all window
-- management, sizing, keymaps, and autocmds.
local M = {}

local hl         = require("belvedere.hl")

--- Positional highlight entry: { group, 0-indexed-row, byte-col-start, byte-col-end }.
--- Used in the `hls` accumulator arrays passed between section/tag_line/apply.
--- @class DetailHlRule
--- @field [1] string   highlight group name
--- @field [2] integer  0-indexed buffer row
--- @field [3] integer  byte start column
--- @field [4] integer  byte end column  (-1 = end of line)

--- Per-segment highlight spec returned by tag_line: { group, col_start, col_end }.
--- @class TagSpec
--- @field [1] string   highlight group name
--- @field [2] integer  byte start column within the tag line
--- @field [3] integer  byte end column within the tag line

local SEP        = string.rep("─", 48)
local TAG_SEP    = "  ·  "
local TAG_PREFIX = "  "
local NS         = vim.api.nvim_create_namespace("BelvedereDetailPane")

--- True when v is nil or vim.NIL (JSON null decoded by Neovim).
--- @param v any
--- @return boolean
function M.is_nil(v) return v == nil or v == vim.NIL end

--- Append a bold section header + horizontal separator to the line/highlight accumulators.
--- @param lines table  mutable string array being built
--- @param hls   DetailHlRule[]  mutable highlight-rule array being built
--- @param title string
function M.section(lines, hls, title)
  local row = #lines
  lines[#lines + 1] = "  " .. title
  hls[#hls + 1] = { "BelvedereHeaderRow", row, 2, 2 + #title }
  row = #lines
  lines[#lines + 1] = "  " .. SEP
  hls[#hls + 1] = { "BelvedereBorder", row, 2, 2 + #SEP }
end

--- Build a "tag summary" line with per-segment highlight specs.
--- @param tagged table  list of {text, hl_group} pairs (hl_group nil/false = no highlight)
--- @return string line, TagSpec[] specs
function M.tag_line(tagged)
  local texts = {}
  for _, t in ipairs(tagged) do texts[#texts + 1] = t[1] end
  local line  = TAG_PREFIX .. table.concat(texts, TAG_SEP)
  local specs = {}
  local pos   = #TAG_PREFIX
  for i, t in ipairs(tagged) do
    if t[2] then
      specs[#specs + 1] = { t[2], pos, pos + #t[1] }
    end
    pos = pos + #t[1] + (i < #tagged and #TAG_SEP or 0)
  end
  return line, specs
end

--- Write lines + highlights into buf (replaces all existing content).
--- @param buf   integer
--- @param lines string[]
--- @param hls   DetailHlRule[]
function M.apply(buf, lines, hls)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(buf, NS, h[1], h[2], h[3], h[4])
  end
end

--- Open a two-pane browsing float.
--- Left pane: navigable list. Right pane: detail view that updates on cursor move.
--- Keymaps: j/k navigate · l/<Tab> focus right · h/<S-Tab>/<Tab> back · q/<Esc> close.
---
--- @param opts table
---   .items      array             items to browse (must be non-empty)
---   .left_title string            left window title (with surrounding spaces)
---   .get_label  fn(item)→string   label shown for each row in the left pane
---   .get_title  fn(item)→string   right window title for the focused item (no surrounding spaces)
---   .render     fn(buf, item)     populate the right buffer for the focused item
---   .estimate   fn(item)→number   estimated rendered line count (for window sizing)
function M.open_two_pane(opts)
  local items = opts.items
  if #items == 0 then
    vim.notify("belvedere: nothing to display", vim.log.levels.WARN)
    return
  end

  local ew      = vim.o.columns
  local eh      = vim.o.lines
  local left_w  = math.min(36, math.max(24, math.floor(ew * 0.22)))
  local right_w = math.min(math.floor(ew * 0.60), 110)
  local max_h   = math.max(math.floor(eh * 0.72), 8)
  local left_h  = math.min(math.max(#items + 2, 8), max_h)
  local max_content = 8
  for _, item in ipairs(items) do
    max_content = math.max(max_content, opts.estimate(item))
  end
  local right_h = math.min(max_content, max_h)
  local total   = left_w + 2 + 1 + right_w + 2
  local col0    = math.max(0, math.floor((ew - total) / 2))
  local row0    = math.max(0, math.floor((eh - right_h - 2) / 2))

  local lbuf = vim.api.nvim_create_buf(false, true)
  local rbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[lbuf].bufhidden = "wipe"
  vim.bo[rbuf].bufhidden = "wipe"

  local llines = {}
  for _, item in ipairs(items) do
    llines[#llines + 1] = "  " .. opts.get_label(item)
  end
  vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, llines)
  vim.bo[lbuf].modifiable = false
  vim.bo[rbuf].modifiable = false

  local lwin = vim.api.nvim_open_win(lbuf, true, {
    relative  = "editor",
    row       = row0, col = col0,
    width     = left_w, height = left_h,
    style     = "minimal", border = "rounded",
    title     = opts.left_title, title_pos = "center",
  })
  local rwin = vim.api.nvim_open_win(rbuf, false, {
    relative  = "editor",
    row       = row0, col = col0 + left_w + 3,
    width     = right_w, height = right_h,
    style     = "minimal", border = "rounded",
  })

  vim.api.nvim_win_set_hl_ns(lwin, hl.NS_ID)
  vim.api.nvim_win_set_hl_ns(rwin, hl.NS_ID)
  vim.api.nvim_set_option_value("cursorline", true,  { win = lwin })
  vim.api.nvim_set_option_value("wrap",       false, { win = rwin })

  --- Sync the right pane to reflect the left pane's current cursor row.
  local function sync()
    local row  = vim.api.nvim_win_get_cursor(lwin)[1]
    local item = items[row]
    if not item then return end
    pcall(vim.api.nvim_win_set_config, rwin, {
      title     = " " .. opts.get_title(item) .. " ",
      title_pos = "center",
    })
    opts.render(rbuf, item)
    pcall(vim.api.nvim_win_set_cursor, rwin, { 1, 0 })
  end

  sync()

  local aug = vim.api.nvim_create_augroup("BelvedereDetailPane_" .. lbuf, { clear = true })

  --- Close both panes.
  local function close()
    pcall(vim.api.nvim_win_close, lwin, true)
    pcall(vim.api.nvim_win_close, rwin, true)
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug, pattern = tostring(lwin), once = true,
    callback = function()
      pcall(vim.api.nvim_win_close, rwin, true)
      vim.api.nvim_del_augroup_by_id(aug)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug, pattern = tostring(rwin), once = true,
    callback = function()
      pcall(vim.api.nvim_win_close, lwin, true)
      vim.api.nvim_del_augroup_by_id(aug)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = aug, buffer = lbuf, callback = sync,
  })

  --- @param key string
  --- @param fn  fun()
  local function lmap(key, fn) vim.keymap.set("n", key, fn, { buffer = lbuf, nowait = true, silent = true }) end
  lmap("q",     close)
  lmap("<Esc>", close)
  lmap("l",     function() vim.api.nvim_set_current_win(rwin) end)
  lmap("<Tab>", function() vim.api.nvim_set_current_win(rwin) end)

  --- @param key string
  --- @param fn  fun()
  local function rmap(key, fn) vim.keymap.set("n", key, fn, { buffer = rbuf, nowait = true, silent = true }) end
  rmap("q",       close)
  rmap("<Esc>",   close)
  rmap("h",       function() vim.api.nvim_set_current_win(lwin) end)
  rmap("<Tab>",   function() vim.api.nvim_set_current_win(lwin) end)
  rmap("<S-Tab>", function() vim.api.nvim_set_current_win(lwin) end)
end

--- Open a single-item detail float.
---
--- @param opts table
---   .item     any              item to display
---   .title    string           window title (no surrounding spaces — they are added here)
---   .render   fn(buf, item)    populate the buffer
---   .estimate fn(item)→number  estimated line count for window height
function M.open_single(opts)
  local ew     = vim.o.columns
  local eh     = vim.o.lines
  local width  = math.min(math.floor(ew * 0.60), 110)
  local max_h  = math.max(math.floor(eh * 0.72), 8)
  local height = math.min(math.max(opts.estimate(opts.item), 8), max_h)
  local col0   = math.max(0, math.floor((ew - width  - 2) / 2))
  local row0   = math.max(0, math.floor((eh - height - 2) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  opts.render(buf, opts.item)

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = row0, col = col0,
    width     = width, height = height,
    style     = "minimal", border = "rounded",
    title     = " " .. opts.title .. " ",
    title_pos = "center",
  })
  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)
  vim.api.nvim_set_option_value("wrap", false, { win = win })

  --- Close the single-item float.
  local function close() pcall(vim.api.nvim_win_close, win, true) end

  local aug = vim.api.nvim_create_augroup("BelvedereDetailPane_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug, pattern = tostring(win), once = true,
    callback = function() vim.api.nvim_del_augroup_by_id(aug) end,
  })
  vim.keymap.set("n", "q",     close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, silent = true })
end

return M
