-- Query log viewer: four-panel float.
-- Left: search input (top) + filtered list (bottom), stitched with shared border.
-- Right: SQL preview (top) + results preview (bottom), stitched with shared border.
-- All stacked-border pairs use the save_query.lua technique: the lower window's top
-- border overlaps the upper window's bottom border row; zindex wins on that row.
local M = {}

local log       = require("belvedere.log")
local table_fmt = require("belvedere.table")
local hl        = require("belvedere.hl")

local SEARCH_PROMPT     = "/ "
local SEARCH_PROMPT_LEN = #SEARCH_PROMPT

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
  local status  = entry.status == "error"   and "✗ "
               or entry.status == "running" and "… "
               or "  "
  local time_s  = os.date("%H:%M:%S", entry.timestamp)
  local line_s  = ("ln:%-4d"):format((entry.source_line or 0) + 1)
  local prefix  = status .. time_s .. "  " .. line_s .. "  "
  local sql_one = vim.trim(entry.sql:gsub("%s+", " "))
  local sql_w   = math.max(0, content_w - vim.fn.strdisplaywidth(prefix))
  if vim.fn.strdisplaywidth(sql_one) > sql_w and sql_w > 1 then
    sql_one = vim.fn.strcharpart(sql_one, 0, sql_w - 1) .. "…"
  end
  return prefix .. sql_one
end

--- Open the log viewer for `conn_key`.
--- conn: { conn_id, driver, key, driver_label } — may be nil if connection is inactive.
function M.open(conn_key, conn)
  local entries = log.entries(conn_key)

  -- ── Layout ─────────────────────────────────────────────────────────────────
  -- Right side: sql_win (height=sql_h) stitched above res_win (height=res_h).
  -- Right visual height = 1(top) + sql_h + 1(shared) + res_h + 1(bottom) = sql_h+res_h+3.
  --
  -- Left side: input_win (height=1) stitched above list_win (height=list_h).
  -- Left visual height  = 1(top) + 1(input) + 1(shared) + list_h + 1(bottom) = list_h+4.
  -- For both sides to be the same height: list_h+4 = sql_h+res_h+3 → list_h = sql_h+res_h-1.
  local total_w  = math.min(math.floor(vim.o.columns * 0.92), 200)
  local sql_h    = math.max(3, math.floor(vim.o.lines * 0.30))
  local res_h    = math.max(3, math.floor(vim.o.lines * 0.25))
  local list_h   = math.max(2, sql_h + res_h - 1)
  local vis_h    = sql_h + res_h + 3  -- total visual height of either side

  local left_cw  = math.max(30, math.floor(total_w * 0.35) - 2)
  local left_vw  = left_cw + 2
  local gap      = 2
  local right_cw = math.max(10, total_w - left_vw - gap - 2)

  local start_row = math.max(0, math.floor((vim.o.lines   - vis_h)   / 2))
  local start_col = math.max(0, math.floor((vim.o.columns - total_w) / 2))
  local right_col = start_col + left_vw + gap

  -- ── Buffers ────────────────────────────────────────────────────────────────
  -- Search input (editable; cursor protected from eating the "/ " prompt).
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].bufhidden = "wipe"
  vim.bo[input_buf].complete  = ""   -- disable completion so <C-n>/<C-p> don't open a popup
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { SEARCH_PROMPT })

  -- Filtered entry list (read-only).
  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buf].bufhidden  = "wipe"
  vim.bo[list_buf].modifiable = false

  -- SQL preview (read-only, treesitter-highlighted).
  local sql_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[sql_buf].bufhidden  = "wipe"
  vim.bo[sql_buf].modifiable = false
  vim.bo[sql_buf].filetype   = driver_filetype(conn and conn.driver)
  pcall(vim.treesitter.start, sql_buf)

  -- Results preview (read-only).
  local res_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[res_buf].bufhidden  = "wipe"
  vim.bo[res_buf].modifiable = false

  -- ── Windows ────────────────────────────────────────────────────────────────
  -- Input window (top-left). Bottom border = ├─┤, shared with list_win's top.
  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative  = "editor",
    row       = start_row,
    col       = start_col,
    width     = left_cw,
    height    = 1,
    style     = "minimal",
    border    = { "╭", "─", "╮", "│", "┤", "─", "├", "│" },
    title     = " Query Log ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("number", false, { win = input_win })
  vim.api.nvim_set_option_value("wrap",   false, { win = input_win })
  vim.api.nvim_win_set_hl_ns(input_win, hl.NS_ID)

  -- List window (bottom-left). Top border overlaps input_win's bottom border row.
  -- zindex=51 so the ├─┤ top border renders on top of input_win's ├─┤ bottom border.
  local list_win = vim.api.nvim_open_win(list_buf, false, {
    relative  = "editor",
    row       = start_row + 2,  -- same screen row as input_win's bottom border
    col       = start_col,
    width     = left_cw,
    height    = list_h,
    style     = "minimal",
    border    = { "├", "─", "┤", "│", "╯", "─", "╰", "│" },
    zindex    = 51,
  })
  vim.api.nvim_set_option_value("cursorline", true,  { win = list_win })
  vim.api.nvim_set_option_value("number",     false, { win = list_win })
  vim.api.nvim_set_option_value("wrap",       false, { win = list_win })
  vim.api.nvim_win_set_hl_ns(list_win, hl.NS_ID)

  -- SQL window (top-right). Bottom border = ├─┤, shared with res_win's top.
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

  -- Results window (bottom-right). Top border overlaps sql_win's bottom border row.
  -- Window at row=R, height=H → bottom border at R+H+1. So res_win row = start_row+sql_h+1.
  local res_win = vim.api.nvim_open_win(res_buf, false, {
    relative  = "editor",
    row       = start_row + sql_h + 1,  -- same screen row as sql_win's bottom border
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

  local all_wins = { input_win, list_win, sql_win, res_win }

  -- ── Lifecycle helpers ──────────────────────────────────────────────────────
  local closed = false
  local aug    = vim.api.nvim_create_augroup("BelvedereQueryLog", { clear = true })

  local function close()
    if closed then return end
    closed = true
    vim.schedule(function() pcall(vim.api.nvim_del_augroup_by_id, aug) end)
    for _, w in ipairs(all_wins) do
      if vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
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

  local function set_buf_lines(buf, lines)
    -- nvim_buf_set_lines rejects items that contain \n; flatten them.
    local flat = {}
    for _, l in ipairs(lines) do
      if l:find("\n", 1, true) then
        for _, sub in ipairs(vim.split(l, "\n", { plain = true })) do
          flat[#flat + 1] = sub
        end
      else
        flat[#flat + 1] = l
      end
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, flat)
    vim.bo[buf].modifiable = false
  end

  -- ── Preview (right panels) ─────────────────────────────────────────────────
  local rows_cache = {}  -- [entry.id] = rows, to avoid re-reading the file every cursor move

  local function update_preview(entry)
    if not entry then
      set_buf_lines(sql_buf, {})
      set_buf_lines(res_buf, {})
      vim.api.nvim_buf_clear_namespace(res_buf, hl.NS_ID, 0, -1)
      return
    end

    set_buf_lines(sql_buf, vim.split(entry.sql, "\n", { plain = true }))

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
      if not rows_cache[entry.id] then rows_cache[entry.id] = log.load_rows(entry) end
      local rows     = rows_cache[entry.id]
      local cols     = entry.columns or {}
      local rows_ret = entry.rows_returned or #rows
      local rows_tot = entry.rows_total    or rows_ret

      local count_msg = rows_ret == rows_tot
          and (rows_ret .. " row" .. (rows_ret == 1 and "" or "s"))
          or  (rows_ret .. " returned  ·  " .. rows_tot .. " matched")
      if entry.duration_ms then count_msg = count_msg .. "  ·  " .. format_duration(entry.duration_ms) end

      res_lines = { count_msg, "" }
      res_rules = { { higroup = "BelvedereRowCount", start = { 0, 0 }, finish = { 0, -1 } } }

      if #cols > 0 then
        local display = { cols }
        for i = 1, math.min(#rows, 50) do table.insert(display, rows[i]) end
        local tbl        = table_fmt.from_structured_data(display, 1)
        local tbl_offset = 2

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

  -- ── List (left-bottom panel) ───────────────────────────────────────────────
  local line_map = {}  -- [1-indexed row] → entry; reassigned by update_list

  local function update_list(filter_text)
    local filtered = {}
    if filter_text == "" then
      filtered = entries
    else
      local lower = filter_text:lower()
      for _, e in ipairs(entries) do
        if e.sql:lower():find(lower, 1, true) then
          table.insert(filtered, e)
        end
      end
    end

    line_map = {}
    local list_lines, list_rules = {}, {}

    if #filtered == 0 then
      list_lines = { filter_text == "" and "(no queries executed yet)" or "(no matches)" }
    else
      for i, e in ipairs(filtered) do
        table.insert(list_lines, format_entry_line(e, left_cw))
        line_map[i] = e
        if e.status == "error" then
          table.insert(list_rules, { higroup = "BelvedereConnError",
            start = { i - 1, 0 }, finish = { i - 1, -1 } })
        elseif e.status == "running" then
          table.insert(list_rules, { higroup = "BelvedereHelp",
            start = { i - 1, 0 }, finish = { i - 1, -1 } })
        end
      end
    end

    set_buf_lines(list_buf, list_lines)
    vim.api.nvim_buf_clear_namespace(list_buf, hl.NS_ID, 0, -1)
    for _, rule in ipairs(list_rules) do
      vim.hl.range(list_buf, hl.NS_ID, rule.higroup, rule.start, rule.finish)
    end

    -- Clamp the list cursor and refresh the preview.
    if vim.api.nvim_win_is_valid(list_win) then
      local line_count = math.max(1, vim.api.nvim_buf_line_count(list_buf))
      local ok, cur    = pcall(vim.api.nvim_win_get_cursor, list_win)
      local row        = ok and math.min(cur[1], line_count) or 1
      pcall(vim.api.nvim_win_set_cursor, list_win, { row, 0 })
      update_preview(line_map[row])
    end
  end

  -- Initialise list and preview.
  update_list("")

  -- ── Autocmds ───────────────────────────────────────────────────────────────
  -- Keep cursor inside the search prompt in the input window.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group    = aug,
    buffer   = input_buf,
    callback = function()
      local col = vim.api.nvim_win_get_cursor(0)[2]
      if col < SEARCH_PROMPT_LEN then
        vim.api.nvim_win_set_cursor(0, { 1, SEARCH_PROMPT_LEN })
      end
    end,
  })

  -- Re-filter the list whenever the search text changes.
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    group    = aug,
    buffer   = input_buf,
    callback = function()
      local line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
      update_list(vim.trim(line:sub(SEARCH_PROMPT_LEN + 1)))
    end,
  })

  -- Update preview when the list cursor moves.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group    = aug,
    buffer   = list_buf,
    callback = function()
      if not vim.api.nvim_win_is_valid(list_win) then return end
      local row = vim.api.nvim_win_get_cursor(list_win)[1]
      update_preview(line_map[row])
    end,
  })

  -- Close when focus leaves the float entirely (e.g. <C-w>l).
  -- WinLeave fires before the new window is entered, so schedule the check.
  local all_wins_set = {}
  for _, w in ipairs(all_wins) do all_wins_set[w] = true end
  for _, buf in ipairs({ input_buf, list_buf }) do
    vim.api.nvim_create_autocmd("WinLeave", {
      group    = aug,
      buffer   = buf,
      callback = function()
        vim.schedule(function()
          if closed then return end
          if not all_wins_set[vim.api.nvim_get_current_win()] then close() end
        end)
      end,
    })
  end

  -- ── Keymaps ────────────────────────────────────────────────────────────────
  -- Move the list cursor from inside the search bar.
  local function list_move(delta)
    if not vim.api.nvim_win_is_valid(list_win) then return end
    local count = math.max(1, vim.api.nvim_buf_line_count(list_buf))
    local row   = vim.api.nvim_win_get_cursor(list_win)[1]
    local new   = math.max(1, math.min(count, row + delta))
    if new ~= row then
      vim.api.nvim_win_set_cursor(list_win, { new, 0 })
      update_preview(line_map[new])
    end
  end

  local function register_nav_keymaps()
    if not vim.api.nvim_buf_is_valid(input_buf) then return end
    for _, key in ipairs({ "<Down>", "<C-n>" }) do
      vim.keymap.set({ "i", "n" }, key, function() list_move(1)  end,
        { buffer = input_buf, nowait = true, silent = true })
    end
    for _, key in ipairs({ "<Up>", "<C-p>" }) do
      vim.keymap.set({ "i", "n" }, key, function() list_move(-1) end,
        { buffer = input_buf, nowait = true, silent = true })
    end
  end

  -- Register now (overrides BufEnter-based plugins like nvim-cmp).
  register_nav_keymaps()

  -- Re-register after InsertEnter so any InsertEnter-based plugin that sets
  -- buffer-local <C-n>/<C-p> keymaps gets overridden. vim.schedule defers
  -- until all InsertEnter handlers have completed.
  vim.api.nvim_create_autocmd("InsertEnter", {
    group    = aug,
    buffer   = input_buf,
    once     = true,
    callback = function() vim.schedule(register_nav_keymaps) end,
  })

  -- Block <BS> from eating the "/ " prompt.
  vim.keymap.set("i", "<BS>", function()
    if vim.api.nvim_win_get_cursor(0)[2] <= SEARCH_PROMPT_LEN then return end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<BS>", true, false, true), "n", false)
  end, { buffer = input_buf, nowait = true })

  -- <CR> in input: open the currently selected list entry.
  vim.keymap.set({ "i", "n" }, "<CR>", function()
    if not vim.api.nvim_win_is_valid(list_win) then return end
    local row   = vim.api.nvim_win_get_cursor(list_win)[1]
    local entry = line_map[row]
    if not entry then return end

    close()

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

    local results_ui = require("belvedere.ui.results")
    results_ui.set_conn_name(conn_key, conn and conn.driver_label, entry.bufnr)
    if entry.status == "success" then
      local rows = rows_cache[entry.id] or log.load_rows(entry)
      results_ui.show_results(
        entry.columns or {}, rows, entry.rows_returned, entry.rows_total, entry.duration_ms)
    elseif entry.status == "rows_affected" then
      results_ui.show_rows_affected(entry.rows_affected, entry.verb or "affected", entry.duration_ms)
    elseif entry.status == "error" then
      results_ui.show_error(entry.error_msg or "unknown error")
    end
  end, { buffer = input_buf, nowait = true, silent = true })

  -- <Esc> in input: if filter is non-empty, clear it; otherwise close.
  -- Insert mode: no `nowait` so that terminal arrow-key sequences (e.g. \x1b[A for
  -- <Up> over SSH) are not immediately consumed by the \x1b prefix before the rest
  -- of the sequence arrives. Normal mode: nowait is safe.
  local function esc_action()
    local line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
    local text = vim.trim(line:sub(SEARCH_PROMPT_LEN + 1))
    if text ~= "" then
      vim.cmd("stopinsert")
      vim.api.nvim_buf_set_lines(input_buf, 0, 1, false, { SEARCH_PROMPT })
      vim.api.nvim_win_set_cursor(input_win, { 1, SEARCH_PROMPT_LEN })
      update_list("")
    else
      close()
    end
  end
  vim.keymap.set("i", "<Esc>", esc_action, { buffer = input_buf, silent = true })
  vim.keymap.set("n", "<Esc>", esc_action, { buffer = input_buf, nowait = true, silent = true })

  -- Fallback close if the user somehow focuses the list (e.g. mouse click).
  vim.keymap.set("n", "q",     close, { buffer = list_buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = list_buf, nowait = true, silent = true })

  -- Start in search mode.
  vim.schedule(function() vim.cmd("startinsert!") end)
end

return M
