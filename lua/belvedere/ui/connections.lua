-- Panel listing all saved connections, grouped by driver.
-- Keymaps: <CR> expand/collapse group or connect, x explore, e edit, c clone, d disconnect, D delete, n new, G new group, R refresh, q close.
local M = {}

local Buffer      = require("belvedere.buffer")
local connections = require("belvedere.connections")
local config      = require("belvedere.config")
local hl          = require("belvedere.hl")
local window      = require("belvedere.ui.window")
local Spinner     = require("belvedere.ui.spinner")

local BUFNAME      = "belvedere://connections"
local ACTIVE_MARK  = " ✓"
local ERROR_MARK   = " ✗"
local ICON_DRIVER  = "\xEF\x87\x80"  -- U+F1C0  nf-fa-database
local ICON_GROUP   = "\xEF\x81\xBB"  -- U+F07B  nf-fa-folder
local ICON_CONN    = "\xEF\x83\x81"  -- U+F0C1  nf-fa-link

local state = {
  buffer      = nil,
  line_map    = {},  -- [line_nr] -> { type="header"|"conn", driver, name? }
  expanded    = {},  -- [driver]  -> bool (default false = folded)
  conn_errors = {},  -- [name]    -> string (error message)
  conn_loading = {}, -- [name]    -> Spinner (while a connect is in flight)
  hover_win    = nil,
}

local function build(conns, active_set, driver_labels, defined_groups)
  defined_groups = defined_groups or {}

  -- Group by {driver, server}.  Key uses NUL as separator (never in names).
  local groups, group_order = {}, {}
  for name, params in pairs(conns) do
    local driver = params.driver or "unknown"
    local server = params.server
    local gkey   = driver .. (server and ("\0" .. server) or "")
    local label  = params.driver_label or driver_labels[driver] or driver
    if not groups[gkey] then
      groups[gkey] = { label = label, server = server, names = {} }
      table.insert(group_order, gkey)
    end
    table.insert(groups[gkey].names, name)
  end

  -- Track which group names already have at least one connection (any section).
  local used_groups = {}
  for _, params in pairs(conns) do
    local sg = params.group ~= vim.NIL and params.group or nil
    if sg and sg ~= "" then used_groups[sg] = true end
  end

  -- Add driver sections for defined groups that are truly empty (no connections anywhere).
  -- Only create a new section if no existing section already covers that driver.
  for _, dg in ipairs(defined_groups) do
    if not used_groups[dg.name] then
      local covered = false
      for existing_gkey in pairs(groups) do
        if existing_gkey == dg.driver
        or existing_gkey:sub(1, #dg.driver + 1) == (dg.driver .. "\0") then
          covered = true
          break
        end
      end
      if not covered then
        local gkey = dg.driver
        groups[gkey] = { label = driver_labels[dg.driver] or dg.driver, server = nil, names = {} }
        table.insert(group_order, gkey)
      end
    end
  end

  table.sort(group_order)
  for _, gkey in ipairs(group_order) do table.sort(groups[gkey].names) end

  local lines, line_map, hl_rules, hl_server = {}, {}, {}, {}

  local function add_conn_row(name, indent)
    local active  = active_set[name]
    local loading = state.conn_loading[name]
    local has_err = state.conn_errors[name]
    local mark    = active  and ACTIVE_MARK
                 or loading and (" " .. loading:glyph())
                 or has_err and ERROR_MARK
                 or ""
    table.insert(lines,    string.rep(" ", indent) .. ICON_CONN .. " " .. name .. mark)
    table.insert(line_map, { type = "conn", name = name })
    if active      then hl_rules[#lines] = "BelvedereConnection"
    elseif has_err then hl_rules[#lines] = "BelvedereConnError" end
  end

  for _, gkey in ipairs(group_order) do
    local g        = groups[gkey]
    local expanded = state.expanded[gkey]
    local chevron  = expanded and "▾ " or "▸ "
    local server_tag = g.server and (" [" .. g.server .. "]") or ""
    table.insert(lines,    chevron .. ICON_DRIVER .. " " .. g.label .. server_tag .. " (" .. #g.names .. ")")
    table.insert(line_map, { type = "header", gkey = gkey })
    hl_rules[#lines] = "BelvedereHeaderRow"
    if g.server then
      -- Byte offset: chevron(4) + icon(3) + space(1) + label + space(1) = 9 + #label
      local col_s = 9 + #g.label
      hl_server[#lines] = { col_s, col_s + 1 + #g.server + 1 }  -- covers "[server]"
    end

    if expanded then
      -- Extract driver from gkey (part before the first NUL byte).
      local nul_pos = gkey:find("\0", 1, true)
      local driver_of_group = nul_pos and gkey:sub(1, nul_pos - 1) or gkey

      -- Partition into named subgroups and ungrouped connections.
      local sg_map, sg_order, ungrouped = {}, {}, {}
      for _, name in ipairs(g.names) do
        local p  = conns[name]
        local sg = p and p.group ~= vim.NIL and p.group or nil
        if sg and sg ~= "" then
          if not sg_map[sg] then sg_map[sg] = {}; table.insert(sg_order, sg) end
          table.insert(sg_map[sg], name)
        else
          table.insert(ungrouped, name)
        end
      end

      -- Merge in truly empty defined groups for this driver.
      -- Groups that have connections elsewhere show up naturally via those connections.
      for _, dg in ipairs(defined_groups) do
        if dg.driver == driver_of_group and not sg_map[dg.name] and not used_groups[dg.name] then
          sg_map[dg.name] = {}
          table.insert(sg_order, dg.name)
        end
      end
      table.sort(sg_order)

      for _, sg_name in ipairs(sg_order) do
        local skey    = gkey .. "\1" .. sg_name
        local sg_exp  = state.expanded[skey]
        local sg_chev = sg_exp and "▾ " or "▸ "
        table.insert(lines,    "  " .. sg_chev .. ICON_GROUP .. " " .. sg_name .. " (" .. #sg_map[sg_name] .. ")")
        table.insert(line_map, { type = "subgroup", gkey = gkey, subgroup = sg_name })
        hl_rules[#lines] = "BelvedereHeaderRow"
        if sg_exp then
          for _, name in ipairs(sg_map[sg_name]) do add_conn_row(name, 6) end
        end
      end

      for _, name in ipairs(ungrouped) do add_conn_row(name, 4) end
    end
  end

  return lines, line_map, hl_rules, hl_server
end

local FOOTER = "Press g? in any pane for help"

-- Pad `lines` with blank lines so the footer lands on the last visible row.
local function append_footer(lines)
  local win        = state.buffer and vim.fn.bufwinid(state.buffer.buf_id) or -1
  local win_height = win ~= -1 and vim.api.nvim_win_get_height(win) or 0
  local padding    = math.max(0, win_height - #lines - 2)
  for _ = 1, padding do table.insert(lines, "") end
  table.insert(lines, "")
  table.insert(lines, FOOTER)
end

local function refresh()
  local db = require("belvedere")  -- lazy: avoids circular dependency
  local active_set = {}
  for _, n in ipairs(db.active_names()) do active_set[n] = true end

  local driver_labels = {}
  local caps = require("belvedere.client").capabilities()
  if caps then
    for _, d in ipairs(caps.drivers or {}) do
      if d.label then driver_labels[d.driver] = d.label end
    end
  end

  local conns          = connections.load()
  local defined_groups = connections.load_groups()
  local lines, line_map, hl_rules, hl_server = build(conns, active_set, driver_labels, defined_groups)
  state.line_map = line_map

  if #lines == 0 then lines = { "(no saved connections)" } end

  append_footer(lines)
  state.buffer:set_content(lines)

  local rules = {}
  for lnum, group in pairs(hl_rules) do
    table.insert(rules, {
      higroup = group,
      start   = { lnum - 1, 0 },
      finish  = { lnum - 1, -1 },
    })
  end
  for lnum, cols in pairs(hl_server) do
    table.insert(rules, {
      higroup = "BelvedereServerLabel",
      start   = { lnum - 1, cols[1] },
      finish  = { lnum - 1, cols[2] },
    })
  end
  table.insert(rules, {
    higroup = "BelvedereHelp",
    start   = { #lines - 1, 0 },
    finish  = { #lines - 1, -1 },
  })
  state.buffer:apply_highlight(rules)
end


local function entry_at_cursor()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return state.line_map[line]
end

local function on_enter()
  local entry = entry_at_cursor()
  if not entry then return end
  if entry.type == "header" then
    state.expanded[entry.gkey] = not state.expanded[entry.gkey]
    refresh()
  elseif entry.type == "subgroup" then
    local skey = entry.gkey .. "\1" .. entry.subgroup
    state.expanded[skey] = not state.expanded[skey]
    refresh()
  else
    state.conn_errors[entry.name] = nil
    local db = require("belvedere")
    db.connect(entry.name)
  end
end

local function on_delete()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  vim.ui.select({ "No", "Yes" }, {
    prompt = ('Delete connection %q?'):format(entry.name),
  }, function(choice)
    if choice ~= "Yes" then return end
    connections.delete(entry.name)
    refresh()
  end)
end

local function on_disconnect()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  local db = require("belvedere")
  db.disconnect(entry.name)
end

local function on_edit()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  local caps = require("belvedere.client").capabilities()
  connections.edit(entry.name, caps, function(new_name, _params)
    if not new_name then return end
    refresh()
  end)
end

local function on_clone()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  vim.ui.input({ prompt = "Clone as: ", default = entry.name .. "-copy" }, function(new_name)
    if not new_name or new_name == "" then return end
    local conns = connections.load()
    if conns[new_name] then
      vim.notify(("belvedere: connection %q already exists"):format(new_name), vim.log.levels.ERROR)
      return
    end
    local caps = require("belvedere.client").capabilities()
    connections.clone(entry.name, new_name, caps, function(name, _)
      if not name then return end
      refresh()
    end)
  end)
end

local function on_new()
  local db = require("belvedere")
  db.ensure_backend_with_caps(function(caps)
    connections.create(caps, function(name, params)
      if not name then return end
      db._do_connect(name, params)
      refresh()
    end)
  end)
end

local function on_new_group()
  local db = require("belvedere")
  db.ensure_backend_with_caps(function(caps)
    vim.ui.input({ prompt = "Group name: " }, function(name)
      if not name or name == "" then return end
      vim.schedule(function()
        vim.ui.select(caps.drivers, {
          prompt      = "Driver:",
          format_item = function(d) return d.label or d.driver end,
        }, function(d)
          if not d then return end
          local ok = connections.create_group(name, d.driver)
          if ok then refresh() end
        end)
      end)
    end)
  end)
end

local function on_explore()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  local db = require("belvedere")
  db.open_explorer_for(entry.name)
end

local function on_jump()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end
  local db   = require("belvedere")
  local bufs = db.buffers_for(entry.name)
  if #bufs == 0 then
    vim.notify("belvedere: no buffers associated with " .. entry.name, vim.log.levels.WARN)
    return
  end
  local panel_win = vim.fn.bufwinid(state.buffer.buf_id)
  local function jump_to(bufnr)
    -- Prefer a window already showing this buffer.
    for _, w in ipairs(vim.fn.win_findbuf(bufnr)) do
      if w ~= panel_win then
        vim.api.nvim_set_current_win(w)
        return
      end
    end
    -- Reuse any normal editing window.
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= panel_win and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "" then
        vim.api.nvim_set_current_win(w)
        vim.api.nvim_set_current_buf(bufnr)
        return
      end
    end
    -- No suitable window — open one to the left of the panel.
    vim.cmd("leftabove vsplit")
    vim.api.nvim_set_current_buf(bufnr)
  end
  if #bufs == 1 then
    jump_to(bufs[1])
  else
    local names = vim.tbl_map(function(b)
      local name = vim.api.nvim_buf_get_name(b)
      return name ~= "" and name or ("[No Name] #" .. b)
    end, bufs)
    vim.ui.select(names, { prompt = "Open buffer:" }, function(_, idx)
      if idx then jump_to(bufs[idx]) end
    end)
  end
end

local function on_help()
  local entry = entry_at_cursor()
  if not entry then return end
  local driver
  if entry.type == "header" or entry.type == "subgroup" then
    local sep = entry.gkey:find("\0")
    driver = sep and entry.gkey:sub(1, sep - 1) or entry.gkey
  else
    local params = connections.get(entry.name)
    driver = params and params.driver
  end
  if not driver then return end
  require("belvedere").open_driver_help(driver)
end

-- Fields from the saved connection that are client-only and not displayed.
local HIDDEN_CONN_FIELDS = { password = true, requires_password = true, server = true, driver_label = true, group = true }

local function open_hover_float(lines, title, border_hl, line_hl)
  local max_w = 1
  for _, l in ipairs(lines) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end
  local win_w = math.min(max_w, vim.o.columns - 6)

  local height = 0
  for _, l in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(l)
    height = height + (w == 0 and 1 or math.ceil(w / win_w))
  end

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].bufhidden  = "wipe"
  if line_hl then
    for i = 0, #lines - 1 do
      vim.api.nvim_buf_add_highlight(fbuf, -1, line_hl, i, 0, -1)
    end
  end

  local fwin = vim.api.nvim_open_win(fbuf, false, {
    relative  = "cursor",
    row       = 1,
    col       = 0,
    width     = win_w,
    height    = height,
    style     = "minimal",
    border    = "rounded",
    title     = " " .. title .. " ",
    title_pos = "center",
    focusable = false,
  })
  if border_hl then
    vim.api.nvim_set_option_value("winhl", "FloatBorder:" .. border_hl, { win = fwin })
  end
  vim.api.nvim_set_option_value("wrap", true, { win = fwin })

  state.hover_win = fwin

  vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
    group    = vim.api.nvim_create_augroup("BelvedereHoverFloat", { clear = true }),
    buffer   = state.buffer.buf_id,
    once     = true,
    callback = function()
      pcall(vim.api.nvim_win_close, state.hover_win, true)
      state.hover_win = nil
    end,
  })
end

local function on_hover()
  local entry = entry_at_cursor()
  if not entry or entry.type ~= "conn" then return end

  -- Second K: enter the existing float so the user can read/scroll.
  if state.hover_win and vim.api.nvim_win_is_valid(state.hover_win) then
    pcall(vim.api.nvim_del_augroup_by_name, "BelvedereHoverFloat")
    local fwin = state.hover_win
    local fbuf = vim.api.nvim_win_get_buf(fwin)
    local prev = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_config(fwin, { focusable = true })
    vim.api.nvim_set_current_win(fwin)
    for _, key in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", key, function()
        pcall(vim.api.nvim_win_close, fwin, true)
        state.hover_win = nil
        if vim.api.nvim_win_is_valid(prev) then
          vim.api.nvim_set_current_win(prev)
        end
      end, { buffer = fbuf, silent = true, nowait = true })
    end
    return
  end

  local err_msg = state.conn_errors[entry.name]
  if err_msg then
    open_hover_float(
      vim.split(err_msg, "\n", { plain = true }),
      "error", "BelvedereConnError", "BelvedereConnError")
    return
  end

  -- No error: show saved connection details.
  local params = connections.load()[entry.name]
  if not params then return end

  -- Build a key→label map from cached capabilities for the matching driver.
  local labels = {}
  local caps = require("belvedere.client").capabilities()
  if caps then
    for _, db in ipairs(caps.drivers or {}) do
      if db.driver == params.driver then
        for _, p in ipairs(db.params or {}) do
          if p.key and p.label then labels[p.key] = p.label end
        end
        break
      end
    end
  end

  local keys = {}
  for k in pairs(params) do
    if not HIDDEN_CONN_FIELDS[k] then table.insert(keys, k) end
  end
  table.sort(keys, function(a, b)
    if a == "driver" then return true end
    if b == "driver" then return false end
    return a < b
  end)

  local label_w = 0
  for _, k in ipairs(keys) do
    label_w = math.max(label_w, #(labels[k] or k))
  end
  local lines = {}
  for _, k in ipairs(keys) do
    local label = labels[k] or k
    table.insert(lines, label .. string.rep(" ", label_w - #label) .. "  " .. tostring(params[k]))
  end

  open_hover_float(lines, entry.name, nil, nil)
end


function M.open()
  -- Warm the capabilities cache so hover labels are available immediately.
  local db = require("belvedere")
  db.ensure_backend_with_caps(function() M.refresh() end)

  if not (state.buffer and state.buffer:is_valid()) then
    state.buffer = Buffer:new(BUFNAME, "belvedere_connections", false, "nofile")
    vim.api.nvim_create_autocmd("WinResized", {
      callback = function() M.refresh() end,
    })
    local hover_key = config.options.keymaps.hover_key
    state.buffer:set_keymap("n", "<CR>",     on_enter,      { nowait = true, silent = true, desc = "Expand/collapse or connect", group = "Navigate" })
    state.buffer:set_keymap("n", "b",        on_jump,       { nowait = true, silent = true, desc = "Jump to associated buffer",  group = "Navigate" })
    state.buffer:set_keymap("n", "q", function()
      local win = vim.fn.bufwinid(state.buffer.buf_id)
      if win ~= -1 then vim.api.nvim_win_close(win, true) end
    end, { nowait = true, silent = true, desc = "Close panel", group = "Navigate" })
    state.buffer:set_keymap("n", "n",        on_new,        { nowait = true, silent = true, desc = "New connection",            group = "Manage" })
    state.buffer:set_keymap("n", "G",        on_new_group,  { nowait = true, silent = true, desc = "New group",                 group = "Manage" })
    state.buffer:set_keymap("n", "e",        on_edit,       { nowait = true, silent = true, desc = "Edit",                      group = "Manage" })
    state.buffer:set_keymap("n", "c",        on_clone,      { nowait = true, silent = true, desc = "Clone",                     group = "Manage" })
    state.buffer:set_keymap("n", "D",        on_delete,     { nowait = true, silent = true, desc = "Delete",                    group = "Manage" })
    state.buffer:set_keymap("n", "d",        on_disconnect, { nowait = true, silent = true, desc = "Disconnect",                group = "Session" })
    state.buffer:set_keymap("n", "x",        on_explore,    { nowait = true, silent = true, desc = "Open explorer",             group = "Session" })
    state.buffer:set_keymap("n", hover_key,  on_hover,      { nowait = true, silent = true, desc = "Hover details / error",     group = "Info" })
    state.buffer:set_keymap("n", "?",        on_help,       { nowait = true, silent = true, desc = "Driver help",               group = "Info" })
    state.buffer:set_keymap("n", "R",        refresh,       { nowait = true, silent = true, desc = "Refresh",                   group = "Info" })
  end

  local win = vim.fn.bufwinid(state.buffer.buf_id)
  if win ~= -1 then
    vim.api.nvim_win_close(win, true)
    return
  end

  local win = window.open_sidebar(state.buffer.buf_id, "right")
  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)
  refresh()
end

function M.refresh()
  if state.buffer and state.buffer:is_valid() then
    refresh()
  end
end

function M.set_conn_error(name, msg)
  state.conn_errors[name] = msg or "unknown error"
  M.refresh()
end

function M.clear_conn_loading(name)
  local spinner = state.conn_loading[name]
  if not spinner then return end
  state.conn_loading[name] = nil
  spinner:reset()
end

function M.set_conn_loading(name)
  M.clear_conn_loading(name)
  local spinner = Spinner.new(function() M.refresh() end)
  state.conn_loading[name] = spinner
  spinner:start()
end

return M
