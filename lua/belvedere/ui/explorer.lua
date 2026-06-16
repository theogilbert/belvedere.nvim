-- Tree-style DB explorer in a sidebar buffer.
-- Navigation: <CR> expands/collapses nodes; hover_key (default K) describes the item under cursor.
local M = {}

local Buffer  = require("belvedere.buffer")
local client  = require("belvedere.client")
local config  = require("belvedere.config")
local window  = require("belvedere.ui.window")
local Spinner = require("belvedere.ui.spinner")

local BUFNAME = "belvedere://explorer"

local TYPE_ICONS = {
  database       = "󰆼 ",
  schema         = "󱁳 ",
  table          = "󰓫 ",
  ["base table"] = "󰓫 ",
  view           = "󰈈 ",
  collection     = "󱃗 ",
  index          = "󰒻 ",
  constraint     = "󰌾 ",
}
local GROUP_ICON = { closed = " ", open = " " }
local FIELD_ICON = "󰠵 "

local function node_icon(node)
  if node.type == "group" then
    return node.expanded and GROUP_ICON.open or GROUP_ICON.closed
  end
  return TYPE_ICONS[node.type] or FIELD_ICON
end

local state = {
  buffer       = nil,
  tree         = {},
  conn_id      = nil,
  conn_label   = nil,  -- "name (driver)" shown in the buffer name
  root_loading = false,
}

local render  -- forward declaration so the spinner callback can reference it

local spinner = Spinner.new(function() render() end)

render = function()
  if state.root_loading then
    state.buffer:set_content({ "  " .. spinner:glyph() .. " Loading…" })
    return
  end
  local lines = {}
  local function walk(nodes, indent)
    for _, node in ipairs(nodes) do
      local chevron = node.expandable
          and (node.expanded and "▾ " or "▸ ")
          or  "  "
      local label = ""
      if not node.expandable and not TYPE_ICONS[node.type] and node.type ~= "group" then
        label = "  " .. node.type
      end
      lines[#lines + 1] = string.rep("  ", indent) .. chevron .. node_icon(node) .. node.name .. label
      if node.loading then
        lines[#lines + 1] = string.rep("  ", indent + 1) .. "  " .. spinner:glyph() .. " Loading…"
      elseif node.expanded and node.children then
        walk(node.children, indent + 1)
      end
    end
  end
  walk(state.tree, 0)
  state.buffer:set_content(lines)
end

local function make_node(item, path)
  return {
    name       = item.name,
    type       = item.type,
    path       = path,
    expandable = item.expandable,
    expanded   = false,
    children   = nil,
  }
end

local function node_at_line(line)
  local idx = 0
  local function walk(nodes)
    for _, node in ipairs(nodes) do
      idx = idx + 1
      if idx == line then return node end
      if node.expanded and node.children then
        local found = walk(node.children)
        if found then return found end
      end
    end
  end
  return walk(state.tree)
end

local function load_children(node)
  node.loading = true
  spinner:start()
  render()
  client.request("explore.list", { connection_id = state.conn_id, path = node.path }, function(err, result)
    node.loading = false
    spinner:stop()
    if err then
      vim.schedule(function()
        vim.notify("belvedere explorer: " .. err, vim.log.levels.ERROR)
        render()
      end)
      return
    end
    node.children = {}
    for _, item in ipairs(result.items or {}) do
      local child_path = vim.list_extend(vim.list_slice(node.path), { item.name })
      node.children[#node.children + 1] = make_node(item, child_path)
    end
    node.expanded = true
    vim.schedule(render)
  end)
end

local function on_enter()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local node = node_at_line(line)
  if not node or not node.expandable then return end
  if node.expanded then
    node.expanded = false
    render()
  else
    load_children(node)
  end
end

local function open_describe_float(details, node)
  if not details or details == vim.NIL then
    vim.notify("belvedere: nothing to describe for this node", vim.log.levels.WARN)
    return
  end

  local lines    = {}
  local hl_rules = {}

  local function add_hl(group, line_idx, col_s, col_e)
    table.insert(hl_rules, { group, line_idx, col_s, col_e })
  end

  local function is_nil_val(v) return v == nil or v == vim.NIL end

  local function rpad(s, n) return s .. string.rep(" ", math.max(0, n - #s)) end

  local win_title = details.type == "index"
    and (details.index or node.name)
    or  (not is_nil_val(details.schema) and details.schema and details.schema .. "." or "")
        .. (details.table or node.name)

  if details.type == "index" then
    local iname = details.index or node.name
    local title = node_icon(node) .. iname
    table.insert(lines, "  " .. title)
    add_hl("BelvedereHeaderRow", 0, 2, 2 + #title)
    table.insert(lines, "")

    local unique_s = details.unique and "unique" or "non-unique"
    table.insert(lines, "  " .. unique_s)
    table.insert(lines, "")

    local fields = details.fields
    if fields and #fields > 0 then
      local w_name, w_dir = #"Field", #"Direction"
      for _, f in ipairs(fields) do
        w_name = math.max(w_name, #f.name)
        w_dir  = math.max(w_dir,  #(f.direction or ""))
      end
      local hdr = "  " .. rpad("Field", w_name) .. "  " .. rpad("Direction", w_dir)
      table.insert(lines, hdr)
      add_hl("BelvedereHeaderRow", #lines - 1, 0, #hdr)
      local sep = "  " .. string.rep("─", #hdr - 2)
      table.insert(lines, sep)
      add_hl("BelvedereBorder", #lines - 1, 0, #sep)
      for _, f in ipairs(fields) do
        table.insert(lines, "  " .. rpad(f.name, w_name) .. "  " .. (f.direction or ""))
      end
    end

    local cond = not is_nil_val(details.condition) and details.condition or nil
    if cond then
      table.insert(lines, "")
      table.insert(lines, "  WHERE " .. cond)
    end
  else
    local tname  = details.table or node.name
    local schema = not is_nil_val(details.schema) and details.schema or nil
    local title  = node_icon(node) .. (schema and schema .. "." or "") .. tname

    table.insert(lines, "  " .. title)
    add_hl("BelvedereHeaderRow", 0, 2, 2 + #title)
    table.insert(lines, "")

    local cols = details.columns
    if cols and #cols > 0 then
      local w_name, w_type = #"Name", #"Type"
      for _, col in ipairs(cols) do
        w_name = math.max(w_name, #col.name)
        w_type = math.max(w_type, #col.type)
      end

      local hdr = "  " .. rpad("Name", w_name) .. "  " .. rpad("Type", w_type) .. "  Null  PK  Default"
      table.insert(lines, hdr)
      add_hl("BelvedereHeaderRow", #lines - 1, 0, #hdr)

      local sep = "  " .. string.rep("─", #hdr - 2)
      table.insert(lines, sep)
      add_hl("BelvedereBorder", #lines - 1, 0, #sep)

      for _, col in ipairs(cols) do
        local null_s    = col.nullable == true and "✓" or col.nullable == false and "✗" or " "
        local pk_s      = col.pk and "✓" or " "
        local default_s = not is_nil_val(col.default) and tostring(col.default) or "—"
        local row = "  " .. rpad(col.name, w_name)
                 .. "  " .. rpad(col.type, w_type)
                 .. "   " .. null_s
                 .. "    " .. pk_s
                 .. "   " .. default_s
        table.insert(lines, row)
        if col.pk then
          add_hl("BelvedereHeaderRow", #lines - 1, 2, 2 + #col.name)
        end
      end
    end
  end

  local max_w = 0
  for _, l in ipairs(lines) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end
  local width  = math.max(max_w + 2, 30)
  local height = math.min(#lines, math.floor(vim.o.lines * 0.7))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden  = "wipe"

  local ns = vim.api.nvim_create_namespace("BelvedereDescribeFloat")
  for _, rule in ipairs(hl_rules) do
    vim.api.nvim_buf_add_highlight(buf, ns, rule[1], rule[2], rule[3], rule[4])
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = math.floor((vim.o.lines - height) / 2),
    col       = math.floor((vim.o.columns - width)  / 2),
    width     = width,
    height    = height,
    style     = "minimal",
    border    = "rounded",
    title     = " " .. win_title .. " ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function() pcall(vim.api.nvim_win_close, win, true) end,
      { buffer = buf, silent = true, nowait = true })
  end
end

local function on_describe()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local node = node_at_line(line)
  if not node then return end
  client.request("explore.describe", { connection_id = state.conn_id, path = node.path }, function(err, result)
    if err then
      vim.schedule(function()
        vim.notify("belvedere: " .. err, vim.log.levels.ERROR)
      end)
      return
    end
    vim.schedule(function()
      open_describe_float(result.details, node)
    end)
  end)
end

-- Fetch the root node list from the server and repopulate state.tree.
-- @param reset_cache boolean|nil  pass true to discard the server-side cache
local function load_root(reset_cache)
  local params = { connection_id = state.conn_id, path = {} }
  if reset_cache then params.reset_cache = true end
  state.root_loading = true
  spinner:start()
  render()
  client.request("explore.list", params, function(err, result)
    state.root_loading = false
    spinner:stop()
    if err then
      vim.schedule(function()
        vim.notify("belvedere explorer: " .. err, vim.log.levels.ERROR)
        render()
      end)
      return
    end
    state.tree = {}
    for _, item in ipairs(result.items or {}) do
      state.tree[#state.tree + 1] = make_node(item, { item.name })
    end
    vim.schedule(render)
  end)
end

local function get_or_create_buffer()
  if state.buffer and state.buffer:is_valid() then return end
  state.buffer = Buffer:new(BUFNAME, "belvedere_explorer", false, "nofile")
  state.buffer:set_keymap("n", "<CR>", on_enter,
    { nowait = true, silent = true, desc = "Expand / collapse node" })
  state.buffer:set_keymap("n", config.options.keymaps.hover_key, on_describe,
    { nowait = true, silent = true, desc = "Describe item" })
  state.buffer:set_keymap("n", "R", function()
    state.tree = {}
    load_root(true)
  end, { nowait = true, silent = true, desc = "Refresh explorer" })
end

--- @param conn_id any
--- @param conn_name string
--- @param driver string
function M.open(conn_id, conn_name, driver)
  get_or_create_buffer()

  -- Reset the tree when switching to a different connection.
  if conn_id ~= state.conn_id then
    state.tree       = {}
    state.conn_id    = conn_id
    state.conn_label = conn_name .. " (" .. driver .. ")"
    pcall(vim.api.nvim_buf_set_name, state.buffer.buf_id,
      BUFNAME .. " [" .. state.conn_label .. "]")
  end

  local win = vim.fn.bufwinid(state.buffer.buf_id)
  if win == -1 then
    win = window.open_sidebar(state.buffer.buf_id, "left")
  end
  vim.api.nvim_set_current_win(win)

  if state.conn_label then
    -- Escape % so statusline format doesn't misinterpret it.
    local label = state.conn_label:gsub("%%", "%%%%")
    vim.api.nvim_set_option_value("winbar",
      "%#BelvedereHeaderRow#  " .. label, { win = win })
  end

  if #state.tree == 0 then
    load_root()
  else
    render()
  end
end

function M.reset()
  state.tree         = {}
  state.root_loading = false
  spinner:reset()
end

return M
