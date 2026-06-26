-- Query log viewer: three-panel float (left=list, top-right=SQL, bottom-right=results preview).
-- Layout borrows the save_query.lua pattern: the SQL and results windows share a border row.
local M = {}

local log       = require("belvedere.log")
local table_fmt = require("belvedere.table")
local hl        = require("belvedere.hl")

local function driver_filetype(driver)
  if not driver then return "sql" end
  local d = driver:lower()
  if d == "neo4j" or d:find("cypher") then return "cypher" end
  return "sql"
end

local function format_duration(ms)
  return ("%.3f"):format(ms / 1000):gsub("0+$", ""):gsub("%.$", "") .. "s"
end

local function format_entry_line(entry, content_w)
  local status = entry.status == "error"   and "✗ "
              or entry.status == "running" and "… "
              or "  "
  local time_s = os.date("%H:%M:%S", entry.timestamp)
  local line_s = ("ln:%-4d"):format((entry.source_line or 0) + 1)
  local prefix = status .. time_s .. "  " .. line_s .. "  "
  -- Collapse SQL to one line and truncate to remaining width.
  local sql_one = vim.trim(entry.sql:gsub("%s+", " "))
  local sql_w = math.max(0, content_w - vim.fn.strdisplaywidth(prefix))
  if vim.fn.strdisplaywidth(sql_one) > sql_w and sql_w > 1 then
    sql_one = vim.fn.strcharpart(sql_one, 0, sql_w - 1) .. "…"
  end
  return prefix .. sql_one
end

--- Open the log viewer for `conn_key`.
--- conn: { conn_id, driver, key, driver_label } (may be nil if connection is not active)
function M.open(conn_key, conn)
  local entries = log.entries(conn_key)

  -- ── Layout ─────────────────────────────────────────────────────────────────
  local total_w   = math.min(math.floor(vim.o.columns * 0.92), 200)
  local total_h   = math.floor(vim.o.lines * 0.75)
  -- Left panel
  local left_cw   = math.max(30, math.floor(total_w * 0.35) - 2)  -- content width
  local left_vw   = left_cw + 2                                    -- visual width (+ borders)
  local gap       = 2
  -- Right panel (save_query stacked design)
  local right_cw  = total_w - left_vw - gap - 2                    -- content width
  local sql_h     = math.max(3, math.floor((total_h - 3) * 0.45))
  local res_h     = math.max(3, total_h - 3 - sql_h)
  local left_h    = sql_h + res_h + 1                              -- content height = right visual - 2 borders + 1 shared border
  -- Positions
  local start_row = math.max(0, math.floor((vim.o.lines   - (left_h + 2)) / 2))
  local start_col = math.max(0, math.floor((vim.o.columns - total_w)      / 2))
  local right_col = start_col + left_vw + gap

  -- ── Buffers ────────────────────────────────────────────────────────────────
  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buf].bufhidden  = "wipe"
  vim.bo[list_buf].modifiable = false

  local sql_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[sql_buf].bufhidden   = "wipe"
  vim.bo[sql_buf].modifiable  = false
  vim.bo[sql_buf].filetype    = driver_filetype(conn and conn.driver)
  pcall(vim.treesitter.start, sql_buf)

  local res_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[res_buf].bufhidden   = "wipe"
  vim.bo[res_buf].modifiable  = false

  -- ── Windows ────────────────────────────────────────────────────────────────
  local list_win = vim.api.nvim_open_win(list_buf, true, {
    relative  = "editor",
    row       = start_row,
    col       = start_col,
    width     = left_cw,
    height    = left_h,
    style     = "minimal",
    border    = "rounded",
    title     = " Query Log ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("cursorline", true,  { win = list_win })
  vim.api.nvim_set_option_value("number",     false, { win = list_win })
  vim.api.nvim_set_option_value("wrap",       false, { win = list_win })
  vim.api.nvim_win_set_hl_ns(list_win, hl.NS_ID)

  -- SQL window (top-right). Bottom border uses ├─┤ so it stitches with results top.
  local sql_win = vim.api.nvim_open_win(sql_buf, false, {
    relative  = "editor",
    row       = start_row,
    col       = right_col,
    width     = right_cw,
    height    = sql_h,
    style     = "minimal",
    border    = { "╭", "─", "╮", "│", "┤", "─", "├", "│" },
    title     = " SQL ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("number", false, { win = sql_win })
  vim.api.nvim_set_option_value("wrap",   false, { win = sql_win })
  vim.api.nvim_win_set_hl_ns(sql_win, hl.NS_ID)

  -- Results window (bottom-right). Overlaps sql_win's bottom border row.
  -- zindex 51 > default 50 so its top border (├─ Results ─┤) wins on that shared row.
  local res_win = vim.api.nvim_open_win(res_buf, false, {
    relative  = "editor",
    row       = start_row + sql_h + 2,  -- same screen row as sql_win's bottom border
    col       = right_col,
    width     = right_cw,
    height    = res_h,
    style     = "minimal",
    border    = { "├", "─", "┤", "│", "╯", "─", "╰", "│" },
    title     = " Results ",
    title_pos = "center",
    zindex    = 51,
  })
  vim.api.nvim_set_option_value("number", false, { win = res_win })
  vim.api.nvim_set_option_value("wrap",   false, { win = res_win })
  vim.api.nvim_win_set_hl_ns(res_win, hl.NS_ID)

  local all_wins = { list_win, sql_win, res_win }

  -- ── Close helper ──────────────────────────────────────────────────────────
  local closed = false
  local aug    = vim.api.nvim_create_augroup("BelvedereQueryLog", { clear = true })

  local function close()
    if closed then return end
    closed = true
    vim.schedule(function() pcall(vim.api.nvim_del_augroup_by_id, aug) end)
    for _, w in ipairs(all_wins) do
      if vim.api.nvim_win_is_valid(w) then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end

  for _, w in ipairs(all_wins) do
    vim.api.nvim_create_autocmd("WinClosed", {
      group    = aug,
      pattern  = tostring(w),
      once     = true,
      callback = function() close() end,
    })
  end

  -- ── Build list content ────────────────────────────────────────────────────
  local line_map = {}  -- [1-indexed lnum] = entry
  local list_lines, list_hl_rules = {}, {}

  if #entries == 0 then
    list_lines = { "(no queries executed yet)" }
  else
    for i, entry in ipairs(entries) do
      table.insert(list_lines, format_entry_line(entry, left_cw))
      line_map[i] = entry
      if entry.status == "error" then
        table.insert(list_hl_rules, { higroup = "BelvedereConnError",
          start = { i - 1, 0 }, finish = { i - 1, -1 } })
      elseif entry.status == "running" then
        table.insert(list_hl_rules, { higroup = "BelvedereHelp",
          start = { i - 1, 0 }, finish = { i - 1, -1 } })
      end
    end
  end

  vim.bo[list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, list_lines)
  vim.bo[list_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(list_buf, hl.NS_ID, 0, -1)
  for _, rule in ipairs(list_hl_rules) do
    vim.hl.range(list_buf, hl.NS_ID, rule.higroup, rule.start, rule.finish)
  end

  -- ── Preview update ────────────────────────────────────────────────────────
  local rows_cache = {}  -- [entry.id] = rows (avoid re-reading file on every cursor move)

  local function set_buf_lines(buf, lines)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end

  local function update_preview(entry)
    if not entry then
      set_buf_lines(sql_buf, {})
      set_buf_lines(res_buf, {})
      vim.api.nvim_buf_clear_namespace(res_buf, hl.NS_ID, 0, -1)
      return
    end

    -- SQL panel: just update content; treesitter re-highlights automatically.
    set_buf_lines(sql_buf, vim.split(entry.sql, "\n", { plain = true }))

    -- Results panel
    local res_lines, res_rules = {}, {}

    if entry.status == "running" then
      res_lines = { "Executing…" }

    elseif entry.status == "error" then
      res_lines = { "Error: " .. (entry.error_msg or "unknown error") }
      res_rules = { { higroup = "BelvedereError", start = { 0, 0 }, finish = { 0, -1 } } }

    elseif entry.status == "rows_affected" then
      local msg = (entry.rows_affected or 0) .. " row"
          .. ((entry.rows_affected or 0) == 1 and "" or "s")
          .. " " .. (entry.verb or "affected")
      if entry.duration_ms then msg = msg .. "  ·  " .. format_duration(entry.duration_ms) end
      res_lines = { msg }
      res_rules = { { higroup = "BelvedereRowCount", start = { 0, 0 }, finish = { 0, -1 } } }

    elseif entry.status == "success" then
      local rows
      if rows_cache[entry.id] then
        rows = rows_cache[entry.id]
      else
        rows = log.load_rows(entry)
        rows_cache[entry.id] = rows
      end

      local cols     = entry.columns or {}
      local rows_ret = entry.rows_returned or #rows
      local rows_tot = entry.rows_total    or rows_ret

      local count_msg
      if rows_ret == rows_tot then
        count_msg = rows_ret .. " row" .. (rows_ret == 1 and "" or "s")
      else
        count_msg = rows_ret .. " returned  ·  " .. rows_tot .. " matched"
      end
      if entry.duration_ms then
        count_msg = count_msg .. "  ·  " .. format_duration(entry.duration_ms)
      end

      res_lines = { count_msg, "" }
      res_rules = { { higroup = "BelvedereRowCount", start = { 0, 0 }, finish = { 0, -1 } } }

      if #cols > 0 then
        local MAX_ROWS = 50
        local display  = { cols }
        for i = 1, math.min(#rows, MAX_ROWS) do table.insert(display, rows[i]) end
        local tbl        = table_fmt.from_structured_data(display, 1)
        local tbl_offset = 2  -- after count_msg + blank line

        for _, l in ipairs(tbl.text) do table.insert(res_lines, l) end

        for _, r in ipairs(table_fmt.col_hl_rules("BelvedereHeaderRow", tbl_offset, 1, tbl)) do
          table.insert(res_rules, r)
        end
        for _, r in ipairs(table_fmt.null_hl_rules(tbl)) do
          table.insert(res_rules, {
            higroup = r.higroup,
            start   = { r.start[1]  + tbl_offset, r.start[2] },
            finish  = { r.finish[1] + tbl_offset, r.finish[2] },
          })
        end
      end
    end

    set_buf_lines(res_buf, res_lines)
    vim.api.nvim_buf_clear_namespace(res_buf, hl.NS_ID, 0, -1)
    for _, rule in ipairs(res_rules) do
      vim.hl.range(res_buf, hl.NS_ID, rule.higroup, rule.start, rule.finish)
    end
  end

  -- Initialise the right panels with the first (= most recent) entry.
  update_preview(line_map[1])

  vim.api.nvim_create_autocmd("CursorMoved", {
    group    = aug,
    buffer   = list_buf,
    callback = function()
      if not vim.api.nvim_win_is_valid(list_win) then return end
      local row = vim.api.nvim_win_get_cursor(list_win)[1]
      update_preview(line_map[row])
    end,
  })

  -- ── Keymaps ────────────────────────────────────────────────────────────────
  local function km(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = list_buf, nowait = true, silent = true, desc = desc })
  end

  km("q",     close, "Close query log")
  km("<Esc>", close, "Close query log")

  km("<CR>", function()
    if not vim.api.nvim_win_is_valid(list_win) then return end
    local row   = vim.api.nvim_win_get_cursor(list_win)[1]
    local entry = line_map[row]
    if not entry then return end

    close()

    -- Jump to source buffer + line.
    if entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) then
      local buf_wins = vim.tbl_filter(function(w)
        return vim.api.nvim_win_is_valid(w)
            and vim.api.nvim_win_get_config(w).relative == ""
      end, vim.fn.win_findbuf(entry.bufnr))

      if #buf_wins > 0 then
        vim.api.nvim_set_current_win(buf_wins[1])
      else
        vim.api.nvim_set_current_buf(entry.bufnr)
      end
      if entry.source_line then
        vim.api.nvim_win_set_cursor(0, { entry.source_line + 1, 0 })
      end
    end

    -- Restore result in the results window.
    local results_ui = require("belvedere.ui.results")
    results_ui.set_conn_name(conn_key, conn and conn.driver_label)

    if entry.status == "success" then
      local rows = rows_cache[entry.id] or log.load_rows(entry)
      results_ui.show_results(
        entry.columns or {}, rows, entry.rows_returned, entry.rows_total, entry.duration_ms)
    elseif entry.status == "rows_affected" then
      results_ui.show_rows_affected(
        entry.rows_affected, entry.verb or "affected", entry.duration_ms)
    elseif entry.status == "error" then
      results_ui.show_error(entry.error_msg or "unknown error")
    end
  end, "Jump to source and restore result")
end

return M
