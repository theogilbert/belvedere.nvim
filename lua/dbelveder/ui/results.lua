-- Query results window.
--
-- Uses box-drawing characters for the table (table_fmt), a Buffer class for
-- clean content/highlight management (buffer), and truncation indicators plus
-- column-boundary scrolling adapted from nvim-dap-df/pane.lua.
local Buffer    = require("dbelveder.buffer")
local table_fmt = require("dbelveder.table")
local hl        = require("dbelveder.hl")
local config    = require("dbelveder.config")

local M = {}

local BUFNAME = "dbelveder://results"


local state = {
  buffer            = nil,  -- Buffer instance
  win_id            = nil,
  table_data        = nil,  -- FormattedTable from table_fmt, or nil (batch mode)
  scroll_autocmd_id = nil,
  close_autocmd_id  = nil,
  segments          = {},   -- batch mode: { {header, lines, hl_rules} }
}


local function scroll_columns(direction)
  if not state.win_id or not vim.api.nvim_win_is_valid(state.win_id) then return end
  if not state.table_data then return end
  local boundaries = table_fmt.column_boundaries(state.table_data.columns_width)

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
  local buf_id = state.buffer.buf_id
  vim.api.nvim_buf_clear_namespace(buf_id, hl.TRUNCATION_NS_ID, 0, -1)

  if not state.table_data then return end
  local boundaries = table_fmt.column_boundaries(state.table_data.columns_width)

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

local function open_win()
  if is_open() then return end
  local opts     = config.options.results
  local cmd      = opts.split == "right"
      and "botright vsplit"
      or  ("botright " .. opts.height .. "split")
  local prev_win = vim.api.nvim_get_current_win()
  vim.cmd(cmd)
  state.win_id = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win_id, state.buffer.buf_id)

  vim.api.nvim_set_option_value("number",      false, { win = state.win_id })
  vim.api.nvim_set_option_value("signcolumn",  "no",  { win = state.win_id })
  vim.api.nvim_set_option_value("winfixheight", true, { win = state.win_id })
  vim.api.nvim_set_option_value("winfixwidth",  true, { win = state.win_id })
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

local function get_or_create_buffer()
  if state.buffer and state.buffer:is_valid() then return end
  state.buffer = Buffer:new(BUFNAME, "dbelveder_results", false, "nofile")
  table_fmt.setup_buf_hl(state.buffer.buf_id)
  -- Keymaps live on the buffer and survive window close/reopen.
  state.buffer:set_keymap("n", "q", function()
    if is_open() then
      local win = state.win_id
      teardown()
      vim.api.nvim_win_close(win, true)
    end
  end, { desc = "Close results window", silent = true })
  state.buffer:set_keymap("n", "L", function() scroll_columns(1)  end,
    { desc = "Scroll right one column", silent = true })
  state.buffer:set_keymap("n", "H", function() scroll_columns(-1) end,
    { desc = "Scroll left one column",  silent = true })

end


local function apply_highlights(tbl, total_rows, max_rows)
  -- Header row (buffer line 0): per-column bold highlight
  local rules = table_fmt.col_hl_rules("DbelvederHeaderRow", 0, 1, tbl)
  -- Row-count line: last line in the buffer
  local rowcount_buf_line = #tbl.text + 1  -- blank line is at #tbl.text, count at +1
  table.insert(rules, {
    higroup = "DbelvederRowCount",
    start   = { rowcount_buf_line, 0 },
    finish  = { rowcount_buf_line, -1 },
  })
  state.buffer:apply_highlight(rules)
end


local function make_separator(idx, total)
  return ("── Query %d / %d "):format(idx, total) .. string.rep("─", 44)
end

local function render_segments()
  local all_lines, all_rules = {}, {}
  for _, seg in ipairs(state.segments) do
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
  state.buffer:set_content(all_lines)
  state.buffer:apply_highlight(all_rules)
  update_truncation_indicators()
end

function M.begin_batch(n)
  get_or_create_buffer()
  open_win()
  state.table_data = nil
  state.segments   = {}
  state.buffer:set_content({ ("Executing %d quer%s…"):format(n, n == 1 and "y" or "ies") })
  state.buffer:apply_highlight({})
end

function M.append_batch_result(idx, total, columns, rows)
  local max_rows   = config.options.results.max_rows
  local total_rows = #rows
  local display    = { columns }
  for i = 1, math.min(total_rows, max_rows) do table.insert(display, rows[i]) end
  local tbl     = table_fmt.from_structured_data(display, 1)
  local content = vim.list_extend({}, tbl.text)
  table.insert(content, "")
  local label = total_rows .. " row" .. (total_rows == 1 and "" or "s")
  if total_rows > max_rows then
    label = max_rows .. " of " .. total_rows .. " rows (truncated)"
  end
  table.insert(content, label)
  local rules = table_fmt.col_hl_rules("DbelvederHeaderRow", 0, 1, tbl)
  table.insert(rules, { higroup = "DbelvederRowCount",
    start = { #tbl.text + 1, 0 }, finish = { #tbl.text + 1, -1 } })
  table.insert(state.segments, { header = make_separator(idx, total), lines = content, hl_rules = rules })
  render_segments()
end

function M.append_batch_error(idx, total, msg)
  table.insert(state.segments, {
    header   = make_separator(idx, total),
    lines    = { "Error: " .. msg },
    hl_rules = { { higroup = "DbelvederError", start = { 0, 0 }, finish = { 0, -1 } } },
  })
  render_segments()
end

function M.show_results(columns, rows)
  get_or_create_buffer()
  open_win()

  local max_rows    = config.options.results.max_rows
  local total_rows  = #rows
  local display     = { columns }
  for i = 1, math.min(total_rows, max_rows) do
    table.insert(display, rows[i])
  end

  local tbl = table_fmt.from_structured_data(display, 1)
  state.table_data = tbl

  -- Buffer content: formatted table + blank line + row count
  local content = vim.list_extend({}, tbl.text)
  table.insert(content, "")
  local count_label = total_rows .. " row" .. (total_rows == 1 and "" or "s")
  if total_rows > max_rows then
    count_label = max_rows .. " of " .. total_rows .. " rows (truncated)"
  end
  table.insert(content, count_label)

  state.buffer:set_content(content)
  apply_highlights(tbl, total_rows, max_rows)
  update_truncation_indicators()
end

function M.show_error(msg)
  get_or_create_buffer()
  open_win()
  state.table_data = nil
  state.buffer:set_content({ "Error: " .. msg })
  state.buffer:apply_highlight({
    { higroup = "DbelvederError", start = { 0, 0 }, finish = { 0, -1 } },
  })
end

function M.show_message(msg)
  get_or_create_buffer()
  open_win()
  state.table_data = nil
  state.buffer:set_content({ msg })
  state.buffer:apply_highlight({})
end

return M
