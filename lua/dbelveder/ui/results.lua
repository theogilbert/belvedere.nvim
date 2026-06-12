-- Query results window.
--
-- One buffer per connection, named "dbelveder://results [name (driver)]".
-- Buffers are listed so the user can :b between them. A single split window
-- is reused; switching connections swaps the buffer shown in it.
local Buffer     = require("dbelveder.buffer")
local table_fmt  = require("dbelveder.table")
local hl         = require("dbelveder.hl")
local config     = require("dbelveder.config")
local col_picker = require("dbelveder.ui.col_picker")

local M = {}

local BUFNAME = "dbelveder://results"

local render_table  -- forward declaration; defined after apply_highlights below

local function same_columns(a, b)
  if #a ~= #b then return false end
  for i, c in ipairs(a) do if c ~= b[i] then return false end end
  return true
end

local function rows_label(total, max_rows)
  local s = total .. " row" .. (total == 1 and "" or "s")
  if total > max_rows then
    return max_rows .. " of " .. total .. " rows (truncated)"
  end
  return s
end

local function rows_affected_msg(n, verb)
  return n .. " row" .. (n == 1 and "" or "s") .. " " .. verb
end


-- Per-connection buffer state.
-- buffers[conn_name] = { buffer=Buffer, table_data=nil|FormattedTable, segments={} }
local state = {
  buffers           = {},
  win_id            = nil,
  active_conn       = nil,  -- set by set_conn_name before each query
  scroll_autocmd_id = nil,
  close_autocmd_id  = nil,
}

local function active_bs()
  return state.active_conn and state.buffers[state.active_conn]
end

-- Find the buf_state for whichever buffer is currently shown in the results window.
local function win_bs()
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return nil end
  local buf_id = vim.api.nvim_win_get_buf(state.win_id)
  for _, bs in pairs(state.buffers) do
    if bs.buffer.buf_id == buf_id then return bs end
  end
  return nil
end


local function scroll_columns(direction)
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return end
  local bs = win_bs()
  if not bs or not bs.table_data then return end
  local boundaries = table_fmt.column_boundaries(bs.table_data.columns_width)

  local leftcol
  vim.api.nvim_win_call(state.win_id, function()
    leftcol = vim.fn.winsaveview().leftcol
  end)

  local target = leftcol
  if direction > 0 then
    local win_width = vim.api.nvim_win_get_width(state.win_id)
    for i, b in ipairs(boundaries) do
      if i == #boundaries then break end
      if b > leftcol then
        local new_target = math.max(0, boundaries[i + 1] - win_width + 1)
        if new_target > leftcol then target = new_target break end
      end
    end
  else
    target = 0
    for _, b in ipairs(boundaries) do
      if b < leftcol then target = b end
    end
  end

  if target ~= leftcol then
    vim.api.nvim_win_call(state.win_id, function()
      local cursor_vcol = vim.fn.virtcol(".")
      local new_vcol    = math.max(1, target + cursor_vcol - leftcol)
      local row         = vim.fn.line(".")
      local byte_col    = vim.fn.virtcol2col(0, row, new_vcol) - 1
      vim.api.nvim_win_set_cursor(0, { row, byte_col })
      vim.fn.winrestview({ leftcol = target })
    end)
  end
end


local function update_truncation_indicators()
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return end
  local bs = win_bs()
  if not bs then return end
  local buf_id = bs.buffer.buf_id
  vim.api.nvim_buf_clear_namespace(buf_id, hl.TRUNCATION_NS_ID, 0, -1)

  if not bs.table_data then return end
  local boundaries = table_fmt.column_boundaries(bs.table_data.columns_width)

  local win_width = vim.api.nvim_win_get_width(state.win_id)
  local leftcol = 0
  vim.api.nvim_win_call(state.win_id, function()
    leftcol = vim.fn.winsaveview().leftcol
  end)

  local trunc_right = boundaries[#boundaries] >= leftcol + win_width
  local trunc_left  = leftcol > 0
  if not trunc_right and not trunc_left then return end

  for row = 0, vim.api.nvim_buf_line_count(buf_id) - 1 do
    if trunc_right then
      vim.api.nvim_buf_set_extmark(buf_id, hl.TRUNCATION_NS_ID, row, 0, {
        virt_text = { { "▸", "DbelvederTruncated" } },
        virt_text_pos = "right_align",
      })
    end
    if trunc_left then
      vim.api.nvim_buf_set_extmark(buf_id, hl.TRUNCATION_NS_ID, row, 0, {
        virt_text         = { { "◂", "DbelvederTruncated" } },
        virt_text_win_col = 0,
      })
    end
  end
end


local function is_open()
  return state.win_id ~= nil and vim.api.nvim_win_is_valid(state.win_id)
end

local function teardown()
  if state.scroll_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, state.scroll_autocmd_id)
    state.scroll_autocmd_id = nil
  end
  if state.close_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, state.close_autocmd_id)
    state.close_autocmd_id = nil
  end
  state.win_id = nil
end

local function open_win(buf_id)
  local opts     = config.options.results
  local cmd      = opts.split == "right"
      and "botright vsplit"
      or  ("botright " .. opts.height .. "split")
  local prev_win = vim.api.nvim_get_current_win()
  vim.cmd(cmd)
  state.win_id = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win_id, buf_id)

  vim.api.nvim_set_option_value("number",       false, { win = state.win_id })
  vim.api.nvim_set_option_value("signcolumn",   "no",  { win = state.win_id })
  vim.api.nvim_set_option_value("winfixheight", true,  { win = state.win_id })
  vim.api.nvim_set_option_value("winfixwidth",  true,  { win = state.win_id })
  vim.api.nvim_set_option_value("wrap",         false, { win = state.win_id })
  vim.api.nvim_win_set_hl_ns(state.win_id, hl.NS_ID)

  state.scroll_autocmd_id = vim.api.nvim_create_autocmd("WinScrolled", {
    pattern  = tostring(state.win_id),
    callback = function() update_truncation_indicators() end,
  })
  state.close_autocmd_id = vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(state.win_id),
    once     = true,
    callback = function() teardown() end,
  })
  vim.api.nvim_set_current_win(prev_win)
end

-- Open the results window if closed; otherwise just swap the buffer inside it.
local function ensure_win(buf_id)
  if is_open() then
    vim.api.nvim_win_set_buf(state.win_id, buf_id)
  else
    open_win(buf_id)
  end
end

local function get_or_create_buf_state(conn_name, buf_title)
  local existing = state.buffers[conn_name]
  if existing and existing.buffer:is_valid() then return existing end

  local buf = Buffer:new(buf_title, "dbelveder_results", false, "nofile", "hide")
  vim.bo[buf.buf_id].buflisted = true
  table_fmt.setup_buf_hl(buf.buf_id)

  local bs = {
    buffer      = buf,
    table_data  = nil,
    segments    = {},
    raw_columns = nil,
    raw_rows    = nil,
    vis_columns = nil,
  }
  state.buffers[conn_name] = bs

  buf:set_keymap("n", "q", function()
    if is_open() then
      local win = state.win_id
      teardown()
      vim.api.nvim_win_close(win, true)
    end
  end, { desc = "Close results window", silent = true })
  buf:set_keymap("n", "L", function() scroll_columns(1)  end,
    { desc = "Scroll right one column", silent = true })
  buf:set_keymap("n", "H", function() scroll_columns(-1) end,
    { desc = "Scroll left one column",  silent = true })
  buf:set_keymap("n", "c", function()
    if not bs.raw_columns then return end
    col_picker.open(bs.raw_columns, bs.vis_columns, function(sel)
      bs.vis_columns = sel
      render_table(bs)
    end)
  end, { desc = "Select displayed columns", silent = true })

  return bs
end


local function apply_highlights(bs, tbl)
  local rules = table_fmt.col_hl_rules("DbelvederHeaderRow", 0, 1, tbl)
  local rowcount_buf_line = #tbl.text + 1
  table.insert(rules, {
    higroup = "DbelvederRowCount",
    start   = { rowcount_buf_line, 0 },
    finish  = { rowcount_buf_line, -1 },
  })
  bs.buffer:apply_highlight(rules)
end


render_table = function(bs)
  local max_rows   = config.options.results.max_rows
  local total_rows = #bs.raw_rows

  -- Build index map: vis column name → position in raw_columns
  local col_indices = {}
  for _, vc in ipairs(bs.vis_columns) do
    for i, rc in ipairs(bs.raw_columns) do
      if rc == vc then table.insert(col_indices, i); break end
    end
  end

  local display = { bs.vis_columns }
  for i = 1, math.min(total_rows, max_rows) do
    local row = {}
    for _, idx in ipairs(col_indices) do table.insert(row, bs.raw_rows[i][idx]) end
    table.insert(display, row)
  end

  local tbl = table_fmt.from_structured_data(display, 1)
  bs.table_data = tbl

  local content = vim.list_extend({}, tbl.text)
  table.insert(content, "")
  table.insert(content, rows_label(total_rows, max_rows))
  bs.buffer:set_content(content)
  apply_highlights(bs, tbl)
  update_truncation_indicators()
end


local function make_separator(idx, total)
  return ("── Query %d / %d "):format(idx, total) .. string.rep("─", 44)
end

local function render_segments(bs)
  local all_lines, all_rules = {}, {}
  for _, seg in ipairs(bs.segments) do
    local hdr_lnum = #all_lines
    table.insert(all_lines, seg.header)
    local offset = #all_lines
    for _, l in ipairs(seg.lines) do table.insert(all_lines, l) end
    for _, r in ipairs(seg.hl_rules) do
      table.insert(all_rules, {
        higroup = r.higroup,
        start   = { r.start[1] + offset,  r.start[2] },
        finish  = { r.finish[1] + offset, r.finish[2] },
      })
    end
    table.insert(all_rules, { higroup = "DbelvederHeaderRow",
      start = { hdr_lnum, 0 }, finish = { hdr_lnum, -1 } })
    table.insert(all_lines, "")
  end
  bs.buffer:set_content(all_lines)
  bs.buffer:apply_highlight(all_rules)
  update_truncation_indicators()
end


-- Set the active connection for subsequent show calls. Creates the buffer if needed.
function M.set_conn_name(name, driver_label)
  local label     = name and (driver_label and (name .. " (" .. driver_label .. ")") or name)
  local buf_title = label and (BUFNAME .. " [" .. label .. "]") or BUFNAME
  local key       = name or ""
  get_or_create_buf_state(key, buf_title)
  state.active_conn = key
end

function M.begin_batch(n)
  local bs = active_bs()
  ensure_win(bs.buffer.buf_id)
  bs.table_data = nil
  bs.segments   = {}
  bs.buffer:set_content({ ("Executing %d quer%s…"):format(n, n == 1 and "y" or "ies") })
  bs.buffer:apply_highlight({})
end

function M.append_batch_result(idx, total, columns, rows)
  local bs         = active_bs()
  local max_rows   = config.options.results.max_rows
  local total_rows = #rows
  local display    = { columns }
  for i = 1, math.min(total_rows, max_rows) do table.insert(display, rows[i]) end
  local tbl     = table_fmt.from_structured_data(display, 1)
  local content = vim.list_extend({}, tbl.text)
  table.insert(content, "")
  table.insert(content, rows_label(total_rows, max_rows))
  local rules = table_fmt.col_hl_rules("DbelvederHeaderRow", 0, 1, tbl)
  table.insert(rules, { higroup = "DbelvederRowCount",
    start = { #tbl.text + 1, 0 }, finish = { #tbl.text + 1, -1 } })
  table.insert(bs.segments, { header = make_separator(idx, total), lines = content, hl_rules = rules })
  render_segments(bs)
end

function M.append_batch_error(idx, total, msg)
  local bs = active_bs()
  table.insert(bs.segments, {
    header   = make_separator(idx, total),
    lines    = { "Error: " .. msg },
    hl_rules = { { higroup = "DbelvederError", start = { 0, 0 }, finish = { 0, -1 } } },
  })
  render_segments(bs)
end

function M.show_results(columns, rows)
  local bs = active_bs()
  -- Reset vis_columns when the query returns a different schema.
  if not bs.raw_columns or not same_columns(bs.raw_columns, columns) then
    bs.vis_columns = vim.list_extend({}, columns)
  end
  bs.raw_columns = columns
  bs.raw_rows    = rows
  ensure_win(bs.buffer.buf_id)
  render_table(bs)
end

function M.show_rows_affected(n, verb)
  local bs = active_bs()
  bs.table_data = nil
  ensure_win(bs.buffer.buf_id)
  bs.buffer:set_content({ rows_affected_msg(n, verb) })
  bs.buffer:apply_highlight({
    { higroup = "DbelvederRowCount", start = { 0, 0 }, finish = { 0, -1 } },
  })
end

function M.append_batch_rows_affected(idx, total, n, verb)
  local bs = active_bs()
  table.insert(bs.segments, {
    header   = make_separator(idx, total),
    lines    = { rows_affected_msg(n, verb) },
    hl_rules = { { higroup = "DbelvederRowCount", start = { 0, 0 }, finish = { 0, -1 } } },
  })
  render_segments(bs)
end

function M.show_error(msg)
  local bs = active_bs()
  bs.table_data = nil
  ensure_win(bs.buffer.buf_id)
  bs.buffer:set_content({ "Error: " .. msg })
  bs.buffer:apply_highlight({
    { higroup = "DbelvederError", start = { 0, 0 }, finish = { 0, -1 } },
  })
end

function M.show_message(msg)
  local bs = active_bs()
  bs.table_data = nil
  ensure_win(bs.buffer.buf_id)
  bs.buffer:set_content({ msg })
  bs.buffer:apply_highlight({})
end

return M
