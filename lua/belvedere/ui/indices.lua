-- Two-pane floating window for browsing all indexes of a table.
-- Left pane: navigable list of index names. Right pane: detail view, updates live.
-- Keymaps: j/k navigate left · l/<Tab> focus right · h/<Tab> back · q/<Esc> close both.
local M = {}

local ICON  = "󰒻 "
local SEP   = string.rep("─", 48)
local NS    = vim.api.nvim_create_namespace("BelvedereIndices")

local function is_nil(v) return v == nil or v == vim.NIL end

-- Estimate how many lines render_right will produce for a given index.
local function estimate_lines(idx)
  local n = 2  -- one-liner + blank
  local tables   = type(idx.tables)           == "table" and idx.tables           or {}
  local fields   = type(idx.fields)           == "table" and idx.fields           or {}
  local included = type(idx.included_columns) == "table" and idx.included_columns or {}
  if #tables > 1 then n = n + 4 end  -- section + sep + line + blank
  if #fields   > 0 then n = n + 3 + #fields end  -- section + sep + N fields + blank
  if #included > 0 then n = n + 4 end  -- section + sep + line + blank
  if not is_nil(idx.condition) and idx.condition ~= "" then n = n + 4 end
  if not is_nil(idx.ddl) and idx.ddl ~= "" then
    n = n + 2 + #vim.split(idx.ddl, "\n", { plain = true })  -- section + sep + lines
  end
  return n
end

-- ── right-panel renderer ─────────────────────────────────────────────────────

local function render_right(buf, idx)
  local lines = {}
  local hls   = {}  -- { group, row, col_s, col_e }

  local function hl(group, row, cs, ce)
    hls[#hls + 1] = { group, row, cs, ce }
  end

  local function section(title)
    local row = #lines
    lines[#lines + 1] = "  " .. title
    hl("BelvedereHeaderRow", row, 2, 2 + #title)
    row = #lines
    lines[#lines + 1] = "  " .. SEP
    hl("BelvedereBorder", row, 2, 2 + #SEP)
  end

  -- One-liner: type · unique/non-unique · [clustered] · [invisible/disabled]
  local tags = {}
  if not is_nil(idx.index_type) and idx.index_type ~= "" then
    tags[#tags + 1] = idx.index_type
  end
  tags[#tags + 1] = idx.unique and "unique" or "non-unique"
  if idx.clustered then tags[#tags + 1] = "clustered" end
  if not is_nil(idx.visible) and not idx.visible then
    tags[#tags + 1] = "invisible"
    hl("BelvedereError", 0, 0, -1)
  end

  local oneliner = "  " .. table.concat(tags, "  ·  ")
  lines[#lines + 1] = oneliner
  lines[#lines + 1] = ""

  -- Tables — only when more than one (parent table is already implicit from context)
  if type(idx.tables) == "table" and #idx.tables > 1 then
    section("Tables")
    lines[#lines + 1] = "  " .. table.concat(idx.tables, ", ")
    lines[#lines + 1] = ""
  end

  -- Fields
  local fields = type(idx.fields) == "table" and idx.fields or {}
  if #fields > 0 then
    section("Fields")
    for _, f in ipairs(fields) do
      local dir = f.direction == "asc"  and " ↑"
               or f.direction == "desc" and " ↓"
               or (f.direction and ("  " .. f.direction) or "")
      lines[#lines + 1] = "  " .. f.name .. dir
    end
    lines[#lines + 1] = ""
  end

  -- Included columns
  local included = type(idx.included_columns) == "table" and idx.included_columns or {}
  if #included > 0 then
    section("Included columns")
    lines[#lines + 1] = "  " .. table.concat(included, ", ")
    lines[#lines + 1] = ""
  end

  -- Condition / WHERE
  if not is_nil(idx.condition) and idx.condition ~= "" then
    section("Condition")
    lines[#lines + 1] = "  " .. idx.condition
    lines[#lines + 1] = ""
  end

  -- DDL
  if not is_nil(idx.ddl) and idx.ddl ~= "" then
    section("DDL")
    for _, line in ipairs(vim.split(idx.ddl, "\n", { plain = true })) do
      lines[#lines + 1] = "  " .. line
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(buf, NS, h[1], h[2], h[3], h[4])
  end
end

-- ── public entry point ────────────────────────────────────────────────────────

--- Open the two-pane indices browser.
--- @param details table  IndicesDescription as decoded from the server response
function M.open(details)
  local indices = type(details.indices) == "table" and details.indices or {}
  if #indices == 0 then
    vim.notify("belvedere: no indices found for this table", vim.log.levels.WARN)
    return
  end

  -- Title for the left pane header
  local ctx = (not is_nil(details.schema) and details.schema .. "." or "")
           .. (not is_nil(details.table)  and details.table  or "")
  local left_title = ctx ~= "" and (" Indices · " .. ctx .. " ") or " Indices "

  -- Window geometry
  local ew       = vim.o.columns
  local eh       = vim.o.lines
  local left_w   = math.min(36, math.max(24, math.floor(ew * 0.22)))
  local right_w  = math.min(math.floor(ew * 0.60), 110)
  local max_h    = math.max(math.floor(eh * 0.72), 8)
  local left_h   = math.min(math.max(#indices + 2, 8), max_h)
  local max_content = 8
  for _, idx in ipairs(indices) do
    max_content = math.max(max_content, estimate_lines(idx))
  end
  local right_h  = math.min(max_content, max_h)
  -- +2 for borders on each window, +1 gap between them
  local total    = left_w + 2 + 1 + right_w + 2
  local col0     = math.max(0, math.floor((ew - total) / 2))
  local row0     = math.max(0, math.floor((eh - right_h - 2) / 2))

  -- Create buffers
  local lbuf = vim.api.nvim_create_buf(false, true)
  local rbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[lbuf].bufhidden = "wipe"
  vim.bo[rbuf].bufhidden = "wipe"

  -- Populate left buffer
  local llines = {}
  for _, idx in ipairs(indices) do
    llines[#llines + 1] = "  " .. idx.index
  end
  vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, llines)
  vim.bo[lbuf].modifiable = false
  vim.bo[rbuf].modifiable = false

  -- Open windows
  local lwin = vim.api.nvim_open_win(lbuf, true, {
    relative  = "editor",
    row       = row0, col = col0,
    width     = left_w, height = left_h,
    style     = "minimal", border = "rounded",
    title     = left_title, title_pos = "center",
  })
  local rwin = vim.api.nvim_open_win(rbuf, false, {
    relative  = "editor",
    row       = row0, col = col0 + left_w + 3,
    width     = right_w, height = right_h,
    style     = "minimal", border = "rounded",
  })

  vim.api.nvim_set_option_value("cursorline", true,  { win = lwin })
  vim.api.nvim_set_option_value("wrap",       false, { win = rwin })

  -- Update right panel to match cursor row in left panel
  local function sync()
    local row = vim.api.nvim_win_get_cursor(lwin)[1]
    local idx = indices[row]
    if not idx then return end
    pcall(vim.api.nvim_win_set_config, rwin, {
      title     = " " .. ICON .. idx.index .. " ",
      title_pos = "center",
    })
    render_right(rbuf, idx)
    pcall(vim.api.nvim_win_set_cursor, rwin, { 1, 0 })
  end

  sync()  -- render initial state

  -- Cleanup: close both windows and delete the autocmd group
  local aug = vim.api.nvim_create_augroup("BelvedereIndices_" .. lbuf, { clear = true })

  local function close()
    pcall(vim.api.nvim_win_close, lwin, true)
    pcall(vim.api.nvim_win_close, rwin, true)
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    group   = aug,
    pattern = tostring(lwin),
    once    = true,
    callback = function()
      pcall(vim.api.nvim_win_close, rwin, true)
      vim.api.nvim_del_augroup_by_id(aug)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group   = aug,
    pattern = tostring(rwin),
    once    = true,
    callback = function()
      pcall(vim.api.nvim_win_close, lwin, true)
      vim.api.nvim_del_augroup_by_id(aug)
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group  = aug,
    buffer = lbuf,
    callback = sync,
  })

  -- Keymaps — left pane
  local function lmap(key, fn)
    vim.keymap.set("n", key, fn, { buffer = lbuf, nowait = true, silent = true })
  end
  lmap("q",     close)
  lmap("<Esc>", close)
  lmap("l",     function() vim.api.nvim_set_current_win(rwin) end)
  lmap("<Tab>", function() vim.api.nvim_set_current_win(rwin) end)

  -- Keymaps — right pane
  local function rmap(key, fn)
    vim.keymap.set("n", key, fn, { buffer = rbuf, nowait = true, silent = true })
  end
  rmap("q",       close)
  rmap("<Esc>",   close)
  rmap("h",       function() vim.api.nvim_set_current_win(lwin) end)
  rmap("<Tab>",   function() vim.api.nvim_set_current_win(lwin) end)
  rmap("<S-Tab>", function() vim.api.nvim_set_current_win(lwin) end)
end

return M
