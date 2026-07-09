-- Query results window.
--
-- One buffer per (source buffer, connection) pair, named:
--   "belvedere://results [conn (driver)] [filename]"   (named source buf)
--   "belvedere://results [conn (driver)] #N"            (unnamed source buf)
-- Changing a source buffer's connection and running another query therefore opens
-- a new results buffer rather than renaming/reusing the old one; the old one stays
-- listed so the user can still :b back to it.
-- Buffers are listed so the user can :b between them.
-- One results window per tab: running a query in tab A never clobbers tab B.
local Buffer      = require("belvedere.buffer")
local table_fmt   = require("belvedere.table")
local hl          = require("belvedere.hl")
local config      = require("belvedere.config")
local col_picker  = require("belvedere.ui.col_picker")
local connections = require("belvedere.connections")
local export      = require("belvedere.export")
local client      = require("belvedere.client")
local hover       = require("belvedere.ui.hover")
local column_ui   = require("belvedere.ui.column")

local M = {}

local BUFNAME = "belvedere://results"

local render_table              -- forward declaration; defined after apply_highlights
local export_results            -- forward declaration; defined after open_export_buffer
local toggle_thousands_separator -- forward declaration; defined after rebuild_segments

--- Return true when column arrays `a` and `b` are identical.
--- @param a string[]
--- @param b string[]
--- @return boolean
local function same_columns(a, b)
  if #a ~= #b then return false end
  for i, c in ipairs(a) do if c ~= b[i] then return false end end
  return true
end

--- Return the `bs.raw_columns` indices for `bs.vis_columns`, in display order.
--- @param bs table  buf_state
--- @return integer[]
local function visible_col_indices(bs)
  local indices = {}
  for _, vc in ipairs(bs.vis_columns) do
    for i, rc in ipairs(bs.raw_columns) do
      if rc == vc then table.insert(indices, i); break end
    end
  end
  return indices
end

--- Build the row-count label shown above the results table.
--- @param rows_returned integer
--- @param rows_total    integer
--- @param page          integer  1-indexed current page
--- @param page_size     integer
--- @return string
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

--- Build a per-display-column thousands-separator array from the set of columns the
--- user has toggled on for `bs`. The separator is off by default for every column;
--- `t` on a results-pane cell toggles it for that column only.
--- @param display_columns string[]  columns in display order
--- @param sep_columns     table     set of column names with the separator toggled on
--- @return string[]|nil
local function sep_array_for(display_columns, sep_columns)
  local char = config.options.results.thousands_separator
  char = (char and char ~= "") and char or nil
  if not char or not next(sep_columns) then return nil end
  local arr, any = {}, false
  for i, name in ipairs(display_columns) do
    if sep_columns[name] then arr[i] = char; any = true end
  end
  return any and arr or nil
end

--- Return the "N row(s) <verb>" message for a DML result.
--- @param n    integer
--- @param verb string
--- @return string
local function rows_affected_msg(n, verb)
  return n .. " row" .. (n == 1 and "" or "s") .. " " .. verb
end

--- Format a duration in milliseconds as a human-readable string ("1.234s", "2m 5s", etc.).
--- @param ms number
--- @return string
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


-- state.buffers[buf_key] = buf_state        (buf_key = buf_key_for(src_bufnr, conn_key))
-- state.win_ids[tabpage] = win_id            (one results window per tab)
-- state.autocmds[win_id] = { scroll, close }
local state = {
  buffers    = {},
  win_ids    = {},
  autocmds   = {},
  active_src = nil,  -- buf_key set by set_conn_name before each query
}

--- Return the buf_state for the currently active source buffer, or nil.
--- @return table|nil
local function active_bs()
  return state.active_src and state.buffers[state.active_src]
end

--- Return the buf_state whose Buffer.buf_id matches the buffer in `win_id`, or nil.
--- @param win_id integer
--- @return table|nil
local function win_bs_for(win_id)
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then return nil end
  local buf_id = vim.api.nvim_win_get_buf(win_id)
  for _, bs in pairs(state.buffers) do
    if bs.buffer.buf_id == buf_id then return bs end
  end
  return nil
end

--- Return the results window id for the current tab, or nil.
--- @return integer|nil
local function current_results_win()
  return state.win_ids[vim.api.nvim_get_current_tabpage()]
end

--- Return the buf_state for the results window in the current tab, or nil.
--- @return table|nil
local function win_bs()
  return win_bs_for(current_results_win())
end


--- Scroll the results window left (direction < 0) or right (direction > 0) by one column.
--- @param direction integer  positive = right, negative = left
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


--- Reset the results window cursor to line 1, column 0, with no horizontal scroll.
local function reset_cursor()
  local win_id = current_results_win()
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then return end
  vim.api.nvim_win_set_cursor(win_id, { 1, 0 })
  vim.api.nvim_win_call(win_id, function() vim.fn.winrestview({ leftcol = 0 }) end)
end

--- Redraw truncation indicator extmarks (◂/▸) based on the current scroll position.
--- @param win_id integer|nil  defaults to the current tab's results window
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


--- Remove autocmds and win_ids tracking for a closed results window.
--- @param win_id integer
local function teardown(win_id)
  local ac = state.autocmds[win_id]
  if ac then
    pcall(vim.api.nvim_del_autocmd, ac.scroll)
    pcall(vim.api.nvim_del_autocmd, ac.close)
    state.autocmds[win_id] = nil
  end
  for tab, wid in pairs(state.win_ids) do
    if wid == win_id then state.win_ids[tab] = nil; break end
  end
end

--- Set the display options and highlight namespace any window showing a results
--- buffer should have, regardless of how it was opened.
--- @param win_id integer
local function configure_win_chrome(win_id)
  vim.api.nvim_set_option_value("number",       false, { win = win_id })
  vim.api.nvim_set_option_value("signcolumn",   "no",  { win = win_id })
  vim.api.nvim_set_option_value("winfixheight", true,  { win = win_id })
  vim.api.nvim_set_option_value("winfixwidth",  true,  { win = win_id })
  vim.api.nvim_set_option_value("wrap",         false, { win = win_id })
  vim.api.nvim_win_set_hl_ns(win_id, hl.NS_ID)
end

--- Ensure chrome, scroll tracking, and close-cleanup are wired up for any window
--- displaying a results buffer — whether it was opened by running a query or by
--- the user navigating there directly (`:sb`, `:b`, buffer list, etc.).
--- @param win_id integer
local function ensure_win_setup(win_id)
  configure_win_chrome(win_id)
  update_truncation_indicators(win_id)
  if state.autocmds[win_id] then return end
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
end

vim.api.nvim_create_autocmd("BufWinEnter", {
  pattern  = BUFNAME .. "*",
  callback = function() ensure_win_setup(vim.api.nvim_get_current_win()) end,
})

--- Open a new results split/vsplit for the current tab.
--- @param buf_id integer
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
  vim.api.nvim_set_current_win(prev_win)
end

--- Open the results window for the current tab if closed; otherwise swap the buffer.
--- @param buf_id integer
local function ensure_win(buf_id)
  local tab    = vim.api.nvim_get_current_tabpage()
  local win_id = state.win_ids[tab]
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_win_set_buf(win_id, buf_id)
  else
    open_win(buf_id)
  end
end

--- Return a short suffix that identifies the source buffer (" [filename]" or " #N").
--- @param src_bufnr integer|nil
--- @return string
local function src_buf_suffix(src_bufnr)
  if not src_bufnr then return "" end
  local name = vim.api.nvim_buf_get_name(src_bufnr)
  if name ~= "" then
    return " [" .. vim.fn.fnamemodify(name, ":t") .. "]"
  end
  return " #" .. src_bufnr
end

--- Build the `state.buffers` key for a (source buffer, connection) pair. Two calls
--- with the same source buffer but different connections must produce different
--- keys, so changing a buffer's connection routes to a fresh results buffer.
--- @param src_bufnr integer|nil
--- @param conn_key  string|nil
--- @return string
local function buf_key_for(src_bufnr, conn_key)
  return (src_bufnr or 0) .. "\0" .. (conn_key or "")
end

--- Open a float showing the SQL text that produced the current results.
--- @param bs table  buf_state
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

--- Open `content` in a new unnamed, listed buffer in a new tab so the user can inspect or :w it.
--- @param content  string  newline-joined export text
--- @param filetype string  Neovim filetype to assign, or "" for none
local function open_export_buffer(content, filetype)
  local lines = vim.split(content, "\n", { plain = true })
  local buf   = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if filetype ~= "" then vim.bo[buf].filetype = filetype end
  vim.cmd("tab sbuffer " .. buf)
end

--- Prompt for an export format and open the full (unpaginated) result set in a scratch buffer.
--- @param bs table  buf_state
export_results = function(bs)
  if not bs.raw_columns or not bs.raw_rows then return end
  vim.ui.select(export.FORMATS, { prompt = "Export results as:" }, function(format)
    if not format then return end
    local indices = visible_col_indices(bs)
    local rows = {}
    for _, row in ipairs(bs.raw_rows) do
      local r = {}
      for _, idx in ipairs(indices) do table.insert(r, row[idx]) end
      table.insert(rows, r)
    end
    local content = export.render(format, bs.vis_columns, rows)
    open_export_buffer(content, export.FILETYPES[format])
  end)
end

--- Show a condensed column-description hover float for the column under the cursor.
--- Only available when the current results came from an explorer table preview
--- (`bs.table_path` set); a no-op otherwise, since arbitrary query results have
--- no reliable way to resolve which table a column came from.
--- @param bs table  buf_state
local function show_column_hover(bs)
  if not bs.table_path or not bs.table_data or not bs.vis_columns then return end
  local col_idx  = table_fmt.get_column_at_cursor(bs.table_data.columns_width, vim.fn.virtcol("."))
  local col_name = col_idx and bs.vis_columns[col_idx]
  if not col_name then return end

  local conn = bs.conn_key and require("belvedere").get_conn(bs.conn_key)
  if not conn then return end

  local function show(details)
    local lines, hls = column_ui.hover_lines(details)
    hover.open(lines, bs.buffer.buf_id, { hls = hls, above = true })
  end

  bs.column_cache = bs.column_cache or {}
  local cached = bs.column_cache[col_name]
  if cached then show(cached) return end

  local path = vim.list_extend(vim.list_slice(bs.table_path), { "columns", col_name })
  client.request("explore.describe", { connection_id = conn.conn_id, path = path }, function(err, result)
    vim.schedule(function()
      if err or not result or not result.details then return end
      bs.column_cache[col_name] = result.details
      show(result.details)
    end)
  end)
end

--- Return an existing valid buf_state for `buf_key` (see `buf_key_for`), or create
--- and register a new one.
--- @param buf_key   string
--- @param buf_title string
--- @return table
local function get_or_create_buf_state(buf_key, buf_title)
  local existing = state.buffers[buf_key]
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
    conn_key      = nil,
    table_path    = nil,  -- explore-tree path to the source table, if known
    column_cache  = nil,  -- column name -> ColumnDescription, reset with table_path
    sep_columns   = {},   -- column name -> true, thousands separator toggled on via `t`
  }
  state.buffers[buf_key] = bs

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
  buf:set_keymap("n", "e", function() export_results(bs) end,
    { desc = "Export results", silent = true })
  buf:set_keymap("n", config.options.keymaps.hover_key, function() show_column_hover(bs) end,
    { desc = "Show column info", silent = true })
  buf:set_keymap("n", "t", function() toggle_thousands_separator(bs) end,
    { desc = "Toggle thousands separator for column", silent = true })
  return bs
end


--- Apply header, row-count, and NULL highlight rules to `bs.buffer`.
--- `label_line` and `tbl_offset` are 0-indexed buffer rows.
--- @param bs         table   buf_state
--- @param tbl        table   FormattedTable from table_fmt.from_structured_data
--- @param label_line integer  0-indexed row for BelvedereRowCount
--- @param tbl_offset integer  0-indexed row where the table starts
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
  local sep_rules = table_fmt.thousands_hl_rules(tbl)
  for _, r in ipairs(sep_rules) do
    r.start[1]  = r.start[1]  + tbl_offset
    r.finish[1] = r.finish[1] + tbl_offset
  end
  vim.list_extend(rules, sep_rules)
  bs.buffer:apply_highlight(rules)
end


--- Re-render the results table for `bs`, respecting the current page and visible columns.
--- @param bs table  buf_state
render_table = function(bs)
  local page_size    = config.options.results.page_size
  local rows_ret     = bs.rows_returned or #bs.raw_rows
  local rows_tot     = bs.rows_total    or rows_ret
  local total_pages  = math.max(1, math.ceil(rows_ret / page_size))
  bs.page = math.max(1, math.min(bs.page, total_pages))

  local first = (bs.page - 1) * page_size + 1
  local last  = math.min(rows_ret, bs.page * page_size)

  local col_indices = visible_col_indices(bs)

  local display = { bs.vis_columns }
  for i = first, last do
    local row = {}
    for _, idx in ipairs(col_indices) do table.insert(row, bs.raw_rows[i][idx]) end
    table.insert(display, row)
  end

  local sep = sep_array_for(bs.vis_columns, bs.sep_columns)
  local tbl = table_fmt.from_structured_data(display, 1, sep, config.options.results.decimal_separator)
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


--- Return the batch header separator line for statement `idx` of `total`.
--- @param idx   integer
--- @param total integer
--- @return string
local function make_separator(idx, total)
  return ("── Query %d / %d "):format(idx, total) .. string.rep("─", 44)
end

--- Concatenate all batch segments into the results buffer.
--- @param bs table  buf_state
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
  reset_cursor()
end


--- Store the SQL and filetype on the active buf_state for the "source query" float.
--- @param sql      string
--- @param filetype string
function M.set_query(sql, filetype)
  local bs = active_bs()
  if bs then
    bs.query    = sql
    bs.query_ft = filetype
  end
end

--- Create (if needed) the results buffer for `src_bufnr` and make it the active source.
--- @param key        string|nil  connection key
--- @param driver_label string|nil
--- @param src_bufnr  integer|nil  source buffer number
function M.set_conn_name(key, driver_label, src_bufnr)
  local display   = key and connections.conn_display_name(key) or nil
  local label     = display and (driver_label and (display .. " (" .. driver_label .. ")") or display)
  local buf_title = (label and (BUFNAME .. " [" .. label .. "]") or BUFNAME)
                    .. src_buf_suffix(src_bufnr)
  local buf_key   = buf_key_for(src_bufnr, key)
  local bs        = get_or_create_buf_state(buf_key, buf_title)
  bs.conn_key      = key
  bs.table_path    = nil
  bs.column_cache  = nil
  state.active_src = buf_key
end

--- Record the explore-tree path to the table backing the current results, enabling
--- the column-hover float (`K`) to resolve columns via `explore.describe`.
--- Cleared by `set_conn_name` at the start of every new query context.
--- @param path string[]  explore-tree path to the table (e.g. {"public", "users"})
function M.set_source_table(path)
  local bs = active_bs()
  if bs then
    bs.table_path   = path
    bs.column_cache = {}
  end
end

--- Prepare the results buffer for a batch of `n` statements.
--- @param n integer
function M.begin_batch(n)
  local bs = active_bs()
  ensure_win(bs.buffer.buf_id)
  bs.table_data = nil
  bs.segments   = {}
  bs.buffer:set_content({ ("Executing %d quer%s…"):format(n, n == 1 and "y" or "ies") })
  bs.buffer:apply_highlight({})
end

--- Build a batch-view segment for one SELECT-type statement, honoring `sep_columns`.
--- Stores the raw inputs alongside the rendered `tbl`/`lines`/`hl_rules` so the segment
--- can be rebuilt later when the user toggles the thousands separator on a column.
--- @param idx           integer
--- @param total         integer
--- @param columns       string[]
--- @param rows          table[]
--- @param rows_returned integer
--- @param rows_total    integer
--- @param duration_ms   number|nil
--- @param sep_columns   table  set of column names with the separator toggled on
--- @return table  segment
local function build_segment(idx, total, columns, rows, rows_returned, rows_total, duration_ms, sep_columns)
  local page_size = config.options.results.page_size
  local display   = { columns }
  for i = 1, math.min(rows_returned, page_size) do table.insert(display, rows[i]) end
  local sep   = sep_array_for(columns, sep_columns)
  local tbl   = table_fmt.from_structured_data(display, 1, sep, config.options.results.decimal_separator)
  local label = rows_label(rows_returned, rows_total, 1, page_size)
  if duration_ms then label = label .. "  ·  " .. format_duration(duration_ms) end
  local content = { label, "" }
  vim.list_extend(content, tbl.text)
  local rules = table_fmt.col_hl_rules("BelvedereHeaderRow", 2, 1, tbl)
  table.insert(rules, { higroup = "BelvedereRowCount",
    start = { 0, 0 }, finish = { 0, -1 } })
  for _, r in ipairs(table_fmt.thousands_hl_rules(tbl)) do
    table.insert(rules, {
      higroup = r.higroup,
      start   = { r.start[1]  + 2, r.start[2] },
      finish  = { r.finish[1] + 2, r.finish[2] },
    })
  end
  return {
    header = make_separator(idx, total), lines = content, hl_rules = rules, tbl = tbl,
    idx = idx, total = total, columns = columns, rows = rows,
    rows_returned = rows_returned, rows_total = rows_total, duration_ms = duration_ms,
  }
end

--- Rebuild every SELECT-type segment in `bs.segments` from its stored raw inputs,
--- picking up the current `bs.sep_columns` state. Non-SELECT segments (errors,
--- row-count messages) have no `tbl` and are left untouched.
--- @param bs table  buf_state
local function rebuild_segments(bs)
  for i, seg in ipairs(bs.segments) do
    if seg.tbl then
      bs.segments[i] = build_segment(seg.idx, seg.total, seg.columns, seg.rows,
        seg.rows_returned, seg.rows_total, seg.duration_ms, bs.sep_columns)
    end
  end
end

--- Return the batch segment covering 0-indexed buffer line `line0`, or nil.
--- Mirrors the line layout `render_segments` builds: each segment occupies its
--- header line, its content lines, and one trailing blank line.
--- @param bs    table  buf_state
--- @param line0 integer  0-indexed buffer line
--- @return table|nil
local function segment_at_line(bs, line0)
  local offset = 0
  for _, seg in ipairs(bs.segments) do
    local seg_len = 1 + #seg.lines + 1
    if line0 < offset + seg_len then return seg end
    offset = offset + seg_len
  end
end

--- Toggle the thousands separator for the column under the cursor, in whichever
--- results view (single-page or batch) is currently showing.
--- @param bs table  buf_state
toggle_thousands_separator = function(bs)
  local col_name
  if bs.table_data then
    local col_idx = table_fmt.get_column_at_cursor(bs.table_data.columns_width, vim.fn.virtcol("."))
    col_name = col_idx and bs.vis_columns[col_idx]
  elseif #bs.segments > 0 then
    local seg = segment_at_line(bs, vim.fn.line(".") - 1)
    if seg and seg.tbl then
      local col_idx = table_fmt.get_column_at_cursor(seg.tbl.columns_width, vim.fn.virtcol("."))
      col_name = col_idx and seg.columns[col_idx]
    end
  end
  if not col_name then return end

  bs.sep_columns[col_name] = not bs.sep_columns[col_name] or nil

  if bs.table_data then
    render_table(bs)
  else
    rebuild_segments(bs)
    render_segments(bs)
  end
end

--- Append the result of one SELECT-type statement to the batch view.
--- @param idx           integer
--- @param total         integer
--- @param columns       string[]
--- @param rows          table[]
--- @param rows_returned integer
--- @param rows_total    integer|nil
--- @param duration_ms   number|nil
function M.append_batch_result(idx, total, columns, rows, rows_returned, rows_total, duration_ms)
  local bs = active_bs()
  rows_returned = rows_returned or #rows
  rows_total    = rows_total    or rows_returned
  table.insert(bs.segments, build_segment(idx, total, columns, rows, rows_returned, rows_total, duration_ms, bs.sep_columns))
  render_segments(bs)
end

--- Append an error message from one batch statement.
--- @param idx   integer
--- @param total integer
--- @param msg   string
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

--- Display the SELECT results, preserving column visibility when columns match the previous query.
--- @param columns       string[]
--- @param rows          table[]
--- @param rows_returned integer
--- @param rows_total    integer|nil
--- @param duration_ms   number|nil
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
  reset_cursor()
end

--- Display a DML row-count message.
--- @param n           integer
--- @param verb        string
--- @param duration_ms number|nil
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
  reset_cursor()
end

--- Append a DML row-count message to the batch view.
--- @param idx         integer
--- @param total       integer
--- @param n           integer
--- @param verb        string
--- @param duration_ms number|nil
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

--- Display an error message in the results window.
--- @param msg string
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
  reset_cursor()
end

--- Display a plain text message in the results window (e.g. "Executing…").
--- @param msg string
function M.show_message(msg)
  local bs = active_bs()
  bs.table_data = nil
  ensure_win(bs.buffer.buf_id)
  bs.buffer:set_content({ msg })
  bs.buffer:apply_highlight({})
  reset_cursor()
end

--- Return true when `buf_id` is a belvedere results buffer.
--- @param buf_id integer
--- @return boolean
function M.is_results_buf(buf_id)
  return vim.startswith(vim.api.nvim_buf_get_name(buf_id), BUFNAME)
end

--- Return the connection key associated with a results buffer, or nil.
--- @param buf_id integer
--- @return string|nil
function M.conn_key_for_buf(buf_id)
  for _, bs in pairs(state.buffers) do
    if bs.buffer.buf_id == buf_id then return bs.conn_key end
  end
end

return M
