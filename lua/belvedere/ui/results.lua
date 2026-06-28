-- Query results window.
--
-- One buffer per source buffer, named:
--   "belvedere://results [conn (driver)] [filename]"   (named source buf)
--   "belvedere://results [conn (driver)] #N"            (unnamed source buf)
-- Buffers are listed so the user can :b between them.
-- One results window per tab: running a query in tab A never clobbers tab B.
local Buffer      = require("belvedere.buffer")
local table_fmt   = require("belvedere.table")
local hl          = require("belvedere.hl")
local config      = require("belvedere.config")
local col_picker  = require("belvedere.ui.col_picker")
local connections = require("belvedere.connections")

local M = {}

local BUFNAME = "belvedere://results"

local render_table  -- forward declaration; defined after apply_highlights

local function same_columns(a, b)
  if #a ~= #b then return false end
  for i, c in ipairs(a) do if c ~= b[i] then return false end end
  return true
end

local function rows_label(rows_returned, rows_total, page, page_size)
  local total_pages = math.max(1, math.ceil(rows_returned / page_size))
  local first       = (page - 1) * page_size + 1
  local last        = math.min(rows_returned, page * page_size)

  local count
  if rows_returned == rows_total then
    count = total_pages <= 1
        and (rows_returned .. " row" .. (rows_returned == 1 and "" or "s"))
        or  ("rows %d–%d of %d"):format(first, last, rows_returned)
  else
    count = total_pages <= 1
        and ("%d returned  ·  %d matched"):format(rows_returned, rows_total)
        or  ("rows %d–%d of %d returned  ·  %d matched"):format(first, last, rows_returned, rows_total)
  end

  if total_pages > 1 then
    return count .. ("  ·  page %d/%d  (] next  [ prev)"):format(page, total_pages)
  end
  return count
end

local function rows_affected_msg(n, verb)
  return n .. " row" .. (n == 1 and "" or "s") .. " " .. verb
end

local function format_duration(ms)
  local total_s = ms / 1000
  if total_s >= 3600 then
    local h = math.floor(total_s / 3600)
    local m = math.floor((total_s % 3600) / 60)
    return ("%dh %dm"):format(h, m)
  elseif total_s >= 60 then
    local m = math.floor(total_s / 60)
    local s = math.floor(total_s % 60)
    return ("%dm %ds"):format(m, s)
  else
    return ("%.3f"):format(total_s):gsub("0+$", ""):gsub("%.$", "") .. "s"
  end
end


-- state.buffers[src_bufnr] = buf_state
-- state.win_ids[tabpage]   = win_id        (one results window per tab)
-- state.autocmds[win_id]   = { scroll, close }
local state = {
  buffers    = {},
  win_ids    = {},
  autocmds   = {},
  active_src = nil,  -- src_bufnr set by set_conn_name before each query
}

local function active_bs()
  return state.active_src and state.buffers[state.active_src]
end

local function win_bs_for(win_id)
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then return nil end
  local buf_id = vim.api.nvim_win_get_buf(win_id)
  for _, bs in pairs(state.buffers) do
    if bs.buffer.buf_id == buf_id then return bs end
  end
  return nil
end

local function current_results_win()
  return state.win_ids[vim.api.nvim_get_current_tabpage()]
end

local function win_bs()
  return win_bs_for(current_results_win())
end


local function scroll_columns(direction)
  local win_id = vim.api.nvim_get_current_win()
  local bs = win_bs_for(win_id)
  if not bs or not bs.table_data then return end
  local boundaries = table_fmt.column_boundaries(bs.table_data.columns_width)

  local leftcol
  vim.api.nvim_win_call(win_id, function()
    leftcol = vim.fn.winsaveview().leftcol
  end)

  local target = leftcol
  if direction > 0 then
    local win_width = vim.api.nvim_win_get_width(win_id)
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
    vim.api.nvim_win_call(win_id, function()
      local cursor_vcol = vim.fn.virtcol(".")
      local new_vcol    = math.max(1, target + cursor_vcol - leftcol)
      local row         = vim.fn.line(".")
      local byte_col    = vim.fn.virtcol2col(0, row, new_vcol) - 1
      vim.api.nvim_win_set_cursor(0, { row, byte_col })
      vim.fn.winrestview({ leftcol = target })
    end)
  end
end


local function update_truncation_indicators(win_id)
  win_id = win_id or current_results_win()
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then return end
  local bs = win_bs_for(win_id)
  if not bs then return end
  local buf_id = bs.buffer.buf_id
  vim.api.nvim_buf_clear_namespace(buf_id, hl.TRUNCATION_NS_ID, 0, -1)

  if not bs.table_data then return end
  local boundaries = table_fmt.column_boundaries(bs.table_data.columns_width)

  local win_width = vim.api.nvim_win_get_width(win_id)
  local leftcol = 0
  vim.api.nvim_win_call(win_id, function()
    leftcol = vim.fn.winsaveview().leftcol
  end)

  local trunc_right = boundaries[#boundaries] >= leftcol + win_width
  local trunc_left  = leftcol > 0
  if not trunc_right and not trunc_left then return end

  for row = 0, vim.api.nvim_buf_line_count(buf_id) - 1 do
    if trunc_right then
      vim.api.nvim_buf_set_extmark(buf_id, hl.TRUNCATION_NS_ID, row, 0, {
        virt_text = { { "▸", "BelvedereTruncated" } },
        virt_text_pos = "right_align",
      })
    end
    if trunc_left then
      vim.api.nvim_buf_set_extmark(buf_id, hl.TRUNCATION_NS_ID, row, 0, {
        virt_text         = { { "◂", "BelvedereTruncated" } },
        virt_text_win_col = 0,
      })
    end
  end
end


local function teardown(win_id)
  local ac = state.autocmds[win_id]
  if ac then
    pcall(vim.api.nvim_del_autocmd, ac.scroll)
    state.autocmds[win_id] = nil
  end
  for tab, wid in pairs(state.win_ids) do
    if wid == win_id then state.win_ids[tab] = nil; break end
  end
end

local function open_win(buf_id)
  local opts     = config.options.results
  local cmd      = opts.split == "right"
      and "botright vsplit"
      or  ("botright " .. opts.height .. "split")
  local prev_win = vim.api.nvim_get_current_win()
  local tab      = vim.api.nvim_get_current_tabpage()
  vim.cmd(cmd)
  local win_id = vim.api.nvim_get_current_win()
  state.win_ids[tab] = win_id
  vim.api.nvim_win_set_buf(win_id, buf_id)

  vim.api.nvim_set_option_value("number",       false, { win = win_id })
  vim.api.nvim_set_option_value("signcolumn",   "no",  { win = win_id })
  vim.api.nvim_set_option_value("winfixheight", true,  { win = win_id })
  vim.api.nvim_set_option_value("winfixwidth",  true,  { win = win_id })
  vim.api.nvim_set_option_value("wrap",         false, { win = win_id })
  vim.api.nvim_win_set_hl_ns(win_id, hl.NS_ID)

  state.autocmds[win_id] = {
    scroll = vim.api.nvim_create_autocmd("WinScrolled", {
      pattern  = tostring(win_id),
      callback = function() update_truncation_indicators(win_id) end,
    }),
    close = vim.api.nvim_create_autocmd("WinClosed", {
      pattern  = tostring(win_id),
      once     = true,
      callback = function() teardown(win_id) end,
    }),
  }
  vim.api.nvim_set_current_win(prev_win)
end

-- Open the results window for the current tab if closed; otherwise swap the buffer.
local function ensure_win(buf_id)
  local tab    = vim.api.nvim_get_current_tabpage()
  local win_id = state.win_ids[tab]
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_win_set_buf(win_id, buf_id)
  else
    open_win(buf_id)
  end
end

local function src_buf_suffix(src_bufnr)
  if not src_bufnr then return "" end
  local name = vim.api.nvim_buf_get_name(src_bufnr)
  if name ~= "" then
    return " [" .. vim.fn.fnamemodify(name, ":t") .. "]"
  end
  return " #" .. src_bufnr
end

local function show_source_query(bs)
  if not bs.query then return end
  local lines = vim.split(bs.query, "\n", { plain = true })
  local fbuf  = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].bufhidden  = "wipe"
  if bs.query_ft and bs.query_ft ~= "" then
    vim.bo[fbuf].filetype = bs.query_ft
    pcall(vim.treesitter.start, fbuf)
  end
  local ui     = vim.api.nvim_list_uis()[1]
  local width  = math.min(math.max(20, math.floor(ui.width * 0.6)), 120)
  local height = math.min(#lines + 2, math.floor(ui.height * 0.6))
  local row    = math.floor((ui.height - height) / 2)
  local col    = math.floor((ui.width  - width)  / 2)
  local fwin   = vim.api.nvim_open_win(fbuf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = " Source query ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("wrap",       false, { win = fwin })
  vim.api.nvim_set_option_value("number",     false, { win = fwin })
  vim.api.nvim_set_option_value("signcolumn", "no",  { win = fwin })
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, function()
      if vim.api.nvim_win_is_valid(fwin) then vim.api.nvim_win_close(fwin, true) end
    end, { buffer = fbuf, nowait = true, silent = true })
  end
end

local function get_or_create_buf_state(src_bufnr, buf_title)
  local existing = state.buffers[src_bufnr]
  if existing and existing.buffer:is_valid() then return existing end

  local buf = Buffer:new(buf_title, "belvedere_results", false, "nofile", "hide")
  vim.bo[buf.buf_id].buflisted = true
  table_fmt.setup_buf_hl(buf.buf_id)

  local bs = {
    buffer        = buf,
    table_data    = nil,
    segments      = {},
    raw_columns   = nil,
    raw_rows      = nil,
    vis_columns   = nil,
    rows_returned = nil,
    rows_total    = nil,
    duration_ms   = nil,
    page          = 1,
    query         = nil,
    query_ft      = nil,
  }
  state.buffers[src_bufnr] = bs

  buf:set_keymap("n", "q", function()
    local win_id = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_win_close, win_id, true)
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
  buf:set_keymap("n", "]", function()
    if not bs.raw_rows then return end
    local page_size   = config.options.results.page_size
    local total_pages = math.max(1, math.ceil(#bs.raw_rows / page_size))
    if bs.page < total_pages then
      bs.page = bs.page + 1
      render_table(bs)
    end
  end, { desc = "Next page", silent = true })
  buf:set_keymap("n", "[", function()
    if not bs.raw_rows or bs.page <= 1 then return end
    bs.page = bs.page - 1
    render_table(bs)
  end, { desc = "Previous page", silent = true })
  buf:set_keymap("n", "gq", function() show_source_query(bs) end,
    { desc = "Show source query", silent = true })

  return bs
end


-- label_line: 0-indexed buf line for the BelvedereRowCount highlight
-- tbl_offset: 0-indexed buf line where the table starts
local function apply_highlights(bs, tbl, label_line, tbl_offset)
  local rules = table_fmt.col_hl_rules("BelvedereHeaderRow", tbl_offset, 1, tbl)
  table.insert(rules, {
    higroup = "BelvedereRowCount",
    start   = { label_line, 0 },
    finish  = { label_line, -1 },
  })
  local null_rules = table_fmt.null_hl_rules(tbl)
  for _, r in ipairs(null_rules) do
    r.start[1]  = r.start[1]  + tbl_offset
    r.finish[1] = r.finish[1] + tbl_offset
  end
  vim.list_extend(rules, null_rules)
  bs.buffer:apply_highlight(rules)
end


render_table = function(bs)
  local page_size    = config.options.results.page_size
  local rows_ret     = bs.rows_returned or #bs.raw_rows
  local rows_tot     = bs.rows_total    or rows_ret
  local total_pages  = math.max(1, math.ceil(rows_ret / page_size))
  bs.page = math.max(1, math.min(bs.page, total_pages))

  local first = (bs.page - 1) * page_size + 1
  local last  = math.min(rows_ret, bs.page * page_size)

  local col_indices = {}
  for _, vc in ipairs(bs.vis_columns) do
    for i, rc in ipairs(bs.raw_columns) do
      if rc == vc then table.insert(col_indices, i); break end
    end
  end

  local display = { bs.vis_columns }
  for i = first, last do
    local row = {}
    for _, idx in ipairs(col_indices) do table.insert(row, bs.raw_rows[i][idx]) end
    table.insert(display, row)
  end

  local tbl = table_fmt.from_structured_data(display, 1)
  bs.table_data = tbl

  local label = rows_label(rows_ret, rows_tot, bs.page, page_size)
  if bs.duration_ms then
    label = label .. "  ·  " .. format_duration(bs.duration_ms)
  end
  local content = { label, "" }
  vim.list_extend(content, tbl.text)
  bs.buffer:set_content(content)
  apply_highlights(bs, tbl, 0, 2)
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
    table.insert(all_rules, { higroup = "BelvedereHeaderRow",
      start = { hdr_lnum, 0 }, finish = { hdr_lnum, -1 } })
    table.insert(all_lines, "")
  end
  bs.buffer:set_content(all_lines)
  bs.buffer:apply_highlight(all_rules)
  update_truncation_indicators()
end


-- Set the active source buffer for subsequent show calls. Creates the results
-- buffer if needed. src_bufnr is the number of the buffer the query was run from.
function M.set_query(sql, filetype)
  local bs = active_bs()
  if bs then
    bs.query    = sql
    bs.query_ft = filetype
  end
end

function M.set_conn_name(key, driver_label, src_bufnr)
  local display   = key and connections.conn_display_name(key) or nil
  local label     = display and (driver_label and (display .. " (" .. driver_label .. ")") or display)
  local buf_title = (label and (BUFNAME .. " [" .. label .. "]") or BUFNAME)
                    .. src_buf_suffix(src_bufnr)
  local buf_key   = src_bufnr or 0
  get_or_create_buf_state(buf_key, buf_title)
  state.active_src = buf_key
end

function M.begin_batch(n)
  local bs = active_bs()
  ensure_win(bs.buffer.buf_id)
  bs.table_data = nil
  bs.segments   = {}
  bs.buffer:set_content({ ("Executing %d quer%s…"):format(n, n == 1 and "y" or "ies") })
  bs.buffer:apply_highlight({})
end

function M.append_batch_result(idx, total, columns, rows, rows_returned, rows_total, duration_ms)
  local bs       = active_bs()
  local page_size = config.options.results.page_size
  rows_returned   = rows_returned or #rows
  rows_total      = rows_total    or rows_returned
  local display   = { columns }
  for i = 1, math.min(rows_returned, page_size) do table.insert(display, rows[i]) end
  local tbl   = table_fmt.from_structured_data(display, 1)
  local label = rows_label(rows_returned, rows_total, 1, page_size)
  if duration_ms then label = label .. "  ·  " .. format_duration(duration_ms) end
  local content = { label, "" }
  vim.list_extend(content, tbl.text)
  local rules = table_fmt.col_hl_rules("BelvedereHeaderRow", 2, 1, tbl)
  table.insert(rules, { higroup = "BelvedereRowCount",
    start = { 0, 0 }, finish = { 0, -1 } })
  table.insert(bs.segments, { header = make_separator(idx, total), lines = content, hl_rules = rules })
  render_segments(bs)
end

function M.append_batch_error(idx, total, msg)
  local bs    = active_bs()
  local lines = vim.split(msg, "\n", { plain = true })
  lines[1]    = "Error: " .. lines[1]
  table.insert(bs.segments, {
    header   = make_separator(idx, total),
    lines    = lines,
    hl_rules = { { higroup = "BelvedereError", start = { 0, 0 }, finish = { #lines - 1, -1 } } },
  })
  render_segments(bs)
end

function M.show_results(columns, rows, rows_returned, rows_total, duration_ms)
  local bs = active_bs()
  if not bs.raw_columns or not same_columns(bs.raw_columns, columns) then
    bs.vis_columns = vim.list_extend({}, columns)
  end
  bs.raw_columns    = columns
  bs.raw_rows       = rows
  bs.rows_returned  = rows_returned or #rows
  bs.rows_total     = rows_total    or bs.rows_returned
  bs.duration_ms    = duration_ms
  bs.page           = 1
  ensure_win(bs.buffer.buf_id)
  render_table(bs)
end

function M.show_rows_affected(n, verb, duration_ms)
  local bs = active_bs()
  bs.table_data = nil
  ensure_win(bs.buffer.buf_id)
  local msg = rows_affected_msg(n, verb)
  if duration_ms then msg = msg .. "  ·  " .. format_duration(duration_ms) end
  bs.buffer:set_content({ msg })
  bs.buffer:apply_highlight({
    { higroup = "BelvedereRowCount", start = { 0, 0 }, finish = { 0, -1 } },
  })
end

function M.append_batch_rows_affected(idx, total, n, verb, duration_ms)
  local bs = active_bs()
  local msg = rows_affected_msg(n, verb)
  if duration_ms then msg = msg .. "  ·  " .. format_duration(duration_ms) end
  table.insert(bs.segments, {
    header   = make_separator(idx, total),
    lines    = { msg },
    hl_rules = { { higroup = "BelvedereRowCount", start = { 0, 0 }, finish = { 0, -1 } } },
  })
  render_segments(bs)
end

function M.show_error(msg)
  local bs    = active_bs()
  bs.table_data = nil
  ensure_win(bs.buffer.buf_id)
  local lines = vim.split(msg, "\n", { plain = true })
  lines[1]    = "Error: " .. lines[1]
  bs.buffer:set_content(lines)
  bs.buffer:apply_highlight({
    { higroup = "BelvedereError", start = { 0, 0 }, finish = { #lines - 1, -1 } },
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
