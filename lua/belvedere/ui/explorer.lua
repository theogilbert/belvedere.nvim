-- Tree-style DB explorer in a sidebar buffer.
-- Navigation: <CR> expands/collapses nodes; hover_key (default K) describes the item under cursor.
local M = {}

local Buffer  = require("belvedere.buffer")
local client  = require("belvedere.client")
local config  = require("belvedere.config")
local hl      = require("belvedere.hl")
local results = require("belvedere.ui.results")
local window  = require("belvedere.ui.window")
local Spinner = require("belvedere.ui.spinner")

local BUFNAME = "belvedere://explorer"

local EXPLORER_NS = vim.api.nvim_create_namespace("BelvedereExplorer")

local EXPLORER_HL = {
  database       = "BelvedereExplorerDatabase",
  schema         = "BelvedereExplorerSchema",
  table          = "BelvedereExplorerTable",
  ["base table"] = "BelvedereExplorerTable",
  view           = "BelvedereExplorerView",
  collection     = "BelvedereExplorerCollection",
  index          = "BelvedereExplorerIndex",
  constraint     = "BelvedereExplorerConstraint",
  group          = "BelvedereExplorerGroup",
}

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

--- Return the icon glyph for `node`, based on its type and expansion state.
--- @param node ExplorerNode
--- @return string
local function node_icon(node)
  if node.type == "group" then
    return node.expanded and GROUP_ICON.open or GROUP_ICON.closed
  end
  return TYPE_ICONS[node.type] or FIELD_ICON
end

local state = {
  buffer           = nil,
  tree             = {},
  conn_id          = nil,
  conn_label       = nil,  -- "name (driver)" shown in the buffer name
  conn_key         = nil,  -- storage key for results panel header
  conn_driver_label = nil,
  root_loading     = false,
}


local render  -- forward declaration so the spinner callback can reference it

local spinner = Spinner.new(function() render() end)

--- Redraw the explorer buffer from state.tree.
render = function()
  local buf = state.buffer.buf_id
  if state.root_loading then
    state.buffer:set_content({ "  " .. spinner:glyph() .. " Loading…" })
    vim.api.nvim_buf_clear_namespace(buf, EXPLORER_NS, 0, -1)
    return
  end

  local lines = {}
  local hls   = {}

  --- Accumulate a highlight rule for a single buffer row.
  --- @param row   integer  0-indexed
  --- @param col_s integer  byte start column
  --- @param col_e integer  byte end column
  --- @param group string   highlight group name
  local function add_hl(row, col_s, col_e, group)
    hls[#hls + 1] = { row, col_s, col_e, group }
  end

  --- Recursively append nodes at `indent` depth to `lines`/`hls`.
  --- @param nodes  table[]
  --- @param indent integer
  local function walk(nodes, indent)
    for _, node in ipairs(nodes) do
      local indent_s  = string.rep("  ", indent)
      local chevron_s = node.expandable
          and (node.expanded and "▾ " or "▸ ") or "  "
      local icon_s    = node_icon(node)
      local label     = ""
      if not node.expandable and not TYPE_ICONS[node.type] and node.type ~= "group" then
        label = "  " .. node.type
      end

      local row = #lines  -- 0-based
      local desc_s = node.describing and (" " .. spinner:glyph()) or ""
      lines[#lines + 1] = indent_s .. chevron_s .. icon_s .. node.name .. label .. desc_s

      -- Byte column boundaries (Lua # gives byte length).
      local c0 = #indent_s
      local c1 = c0 + #chevron_s
      local c2 = c1 + #icon_s
      local c3 = c2 + #node.name

      if node.expandable then
        add_hl(row, c0, c1, "BelvedereExplorerDim")
      end
      local type_hl = EXPLORER_HL[node.type]
      if type_hl then
        add_hl(row, c1, c3, type_hl)
      end
      if label ~= "" then
        -- skip the two-space separator before the type string
        add_hl(row, c3 + 2, c3 + 2 + #node.type, "BelvedereExplorerDim")
      end

      if node.loading then
        lines[#lines + 1] = string.rep("  ", indent + 1) .. "  " .. spinner:glyph() .. " Loading…"
      elseif node.expanded and node.children then
        walk(node.children, indent + 1)
      end
    end
  end

  walk(state.tree, 0)
  state.buffer:set_content(lines)
  vim.api.nvim_buf_clear_namespace(buf, EXPLORER_NS, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(buf, EXPLORER_NS, h[4], h[1], h[2], h[3])
  end
end

--- @class ServerItem
--- @field name       string
--- @field type       string
--- @field expandable boolean

--- Construct a tree node from a server item and its absolute path.
--- @param item ServerItem
--- @param path string[]  absolute path from the root
--- @return ExplorerNode
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

--- Walk state.tree and return the node at `path`, or nil when not found.
--- @param path string[]
--- @return table|nil
local function node_at_path(path)
  local nodes = state.tree
  local node
  for _, name in ipairs(path) do
    node = nil
    for _, n in ipairs(nodes) do
      if n.name == name then
        node = n
        nodes = n.children or {}
        break
      end
    end
    if not node then return nil end
  end
  return node
end

--- Return the node that occupies 1-indexed `line` in the current rendering, or nil.
--- @param line integer  1-indexed
--- @return table|nil
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

--- Send an explore.list request for `node`, populate its children, and re-render.
--- `reset_cache` = true instructs the server to discard its cache.
--- @param node        ExplorerNode
--- @param reset_cache boolean|nil
local function load_children(node, reset_cache)
  node.loading = true
  spinner:start()
  render()
  local params = { connection_id = state.conn_id, path = node.path }
  if reset_cache then params.reset_cache = true end
  client.request("explore.list", params, function(err, result)
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

--- Handle <CR>: toggle expansion of the node under the cursor.
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

--- @class ExplorerNode
--- @field name        string
--- @field type        string
--- @field path        string[]
--- @field expandable  boolean
--- @field expanded    boolean
--- @field children    ExplorerNode[]|nil
--- @field loading     boolean|nil
--- @field describing  boolean|nil

--- @class TableColumn
--- @field name            string
--- @field type            string
--- @field nullable        boolean|nil
--- @field pk              boolean|nil
--- @field default         any
--- @field exclusive_index boolean|nil
--- @field composite_index boolean|nil

--- @class TableDetails
--- @field table   string|nil
--- @field schema  string|nil
--- @field columns TableColumn[]|nil
--- @field comment string|nil

--- @class HlRule
--- @field [1] string   highlight group name
--- @field [2] integer  0-indexed row
--- @field [3] integer  byte start column
--- @field [4] integer  byte end column (-1 for end of line)

local render_describe, calculate_win_size, present_describe_float  -- forward declarations

--- Open a floating window showing the describe details returned by the server for a node.
--- @param details TableDetails|nil
--- @param node    ExplorerNode
local function open_describe_float(details, node)
  if not details or details == vim.NIL then
    vim.notify("belvedere: nothing to describe for this node", vim.log.levels.WARN)
    return
  end
  present_describe_float(render_describe(details, node))
end

--- Return display lines, highlight rules, and window title for a describe float (pure).
--- @param details TableDetails
--- @param node    ExplorerNode
--- @return string[], HlRule[], string  lines, hl_rules, win_title
render_describe = function(details, node)
  local lines    = {}
  local hl_rules = {}

  local function add_hl(group, line_idx, col_s, col_e)
    table.insert(hl_rules, { group, line_idx, col_s, col_e })
  end

  local function is_nil_val(v) return v == nil or v == vim.NIL end

  local function rpad(s, n)
    return s .. string.rep(" ", math.max(0, n - vim.fn.strdisplaywidth(s)))
  end

  local tname     = details.table or node.name
  local schema    = not is_nil_val(details.schema) and details.schema or nil
  local win_title = (schema and schema .. "." or "") .. tname
  local hdr_title = node_icon(node) .. win_title

  table.insert(lines, "  " .. hdr_title)
  add_hl("BelvedereHeaderRow", 0, 2, 2 + #hdr_title)

  if not is_nil_val(details.comment) and details.comment ~= "" then
    local comment_line = "  " .. details.comment
    table.insert(lines, comment_line)
    add_hl("BelvedereExplorerDim", #lines - 1, 0, #comment_line)
  end

  table.insert(lines, "")

  local cols = details.columns
  if cols and #cols > 0 then
    local w_name, w_type, w_default = 4, 4, 7  -- "Name", "Type", "Default"
    for _, col in ipairs(cols) do
      w_name    = math.max(w_name,    vim.fn.strdisplaywidth(col.name))
      w_type    = math.max(w_type,    vim.fn.strdisplaywidth(col.type))
      local ds  = not is_nil_val(col.default) and tostring(col.default) or "—"
      w_default = math.max(w_default, vim.fn.strdisplaywidth(ds))
    end

    local idx_hdr  = "  Excl.  Comp."   -- 14 display chars
    local idx_w    = vim.fn.strdisplaywidth(idx_hdr)
    local grp_lbl  = "Index"
    local prefix_w = 2 + w_name + 2 + w_type + 12 + w_default
    local grp_off  = math.floor((idx_w - #grp_lbl) / 2)
    local grp_line = string.rep(" ", prefix_w + grp_off) .. grp_lbl
    table.insert(lines, grp_line)
    add_hl("BelvedereHeaderRow", #lines - 1, prefix_w + grp_off, prefix_w + grp_off + #grp_lbl)

    local hdr = "  " .. rpad("Name", w_name)
             .. "  " .. rpad("Type", w_type)
             .. "  Null  PK  "
             .. rpad("Default", w_default)
             .. idx_hdr
    table.insert(lines, hdr)
    add_hl("BelvedereHeaderRow", #lines - 1, 0, #hdr)

    local sep = "  " .. string.rep("─", vim.fn.strdisplaywidth(hdr) - 2)
    table.insert(lines, sep)
    add_hl("BelvedereBorder", #lines - 1, 0, #sep)

    for _, col in ipairs(cols) do
      local null_s    = col.nullable == true and "✓" or col.nullable == false and "✗" or " "
      local pk_s      = col.pk and "✓" or " "
      local default_s = not is_nil_val(col.default) and tostring(col.default) or "—"
      local excl_s    = col.exclusive_index and "✓" or " "
      local comp_s    = col.composite_index and "✓" or " "

      local row_idx = #lines
      local parts   = {}
      local pos     = 0
      local function seg(s, grp)
        if grp then add_hl(grp, row_idx, pos, pos + #s) end
        parts[#parts + 1] = s
        pos = pos + #s
      end

      seg("  ")
      seg(rpad(col.name, w_name), col.pk and "BelvedereExplorerSchema" or nil)
      seg("  ")
      seg(rpad(col.type, w_type),  "BelvedereExplorerTable")
      seg("   ")
      seg(null_s,  null_s ~= " " and "BelvedereExplorerDim" or nil)
      seg("    ")
      seg(pk_s,    col.pk         and "BelvedereExplorerSchema" or nil)
      seg("   ")
      seg(rpad(default_s, w_default))
      seg("    ")
      seg(excl_s,  excl_s == "✓" and "BelvedereExplorerIndex" or nil)
      seg("      ")
      seg(comp_s,  comp_s == "✓"  and "BelvedereExplorerIndex" or nil)

      table.insert(lines, table.concat(parts))
    end
  end

  return lines, hl_rules, win_title
end

--- Compute float dimensions for `lines` (display-width aware).
--- @param lines string[]
--- @return integer, integer  width, height
calculate_win_size = function(lines)
  local max_w = 0
  for _, l in ipairs(lines) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end
  return math.max(max_w + 2, 30), math.min(#lines, math.floor(vim.o.lines * 0.7))
end

--- Open a centred editor float displaying `lines` with `hl_rules` applied.
--- @param lines     string[]
--- @param hl_rules  HlRule[]
--- @param win_title string
present_describe_float = function(lines, hl_rules, win_title)
  local width, height = calculate_win_size(lines)

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
  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)
  vim.api.nvim_set_option_value("cursorline", true, { win = win })

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function() pcall(vim.api.nvim_win_close, win, true) end,
      { buffer = buf, silent = true, nowait = true })
  end
end

--- Handle the hover key: request explore.describe for the node under the cursor.
local function on_describe()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local node = node_at_line(line)
  if not node then return end
  node.describing = true
  spinner:start()
  render()
  client.request("explore.describe", { connection_id = state.conn_id, path = node.path }, function(err, result)
    node.describing = false
    spinner:stop()
    if err then
      vim.schedule(function()
        vim.notify("belvedere: " .. err, vim.log.levels.ERROR)
        render()
      end)
      return
    end
    vim.schedule(function()
      render()
      local details = result.details
      if details and details.type == "indices" then
        local p = node.path
        local parts = vim.list_slice(p, 1, #p - 1)
        local ctx = table.concat(parts, ".")
        local title = ctx ~= "" and (" Indices · " .. ctx .. " ") or " Indices "
        require("belvedere.ui.indices").open(details, title)
      elseif details and details.type == "index" then
        require("belvedere.ui.indices").open_single(details)
      elseif details and details.type == "columns" then
        local p = node.path
        local parts = vim.list_slice(p, 1, #p - 1)
        local ctx = table.concat(parts, ".")
        local title = ctx ~= "" and (" Columns · " .. ctx .. " ") or " Columns "
        require("belvedere.ui.column").open(details, title)
      elseif details and details.type == "column" then
        require("belvedere.ui.column").open_single(details)
      else
        open_describe_float(details, node)
      end
    end)
  end)
end

--- Fetch the root node list from the server and repopulate state.tree.
--- @param reset_cache boolean|nil  pass true to discard the server-side cache
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

local PREVIEWABLE_TYPES = { table = true, ["base table"] = true, view = true, collection = true }

--- Handle the "p" keymap: request a row preview for the node under the cursor.
local function on_preview_rows()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local node = node_at_line(line)
  if not node or not PREVIEWABLE_TYPES[node.type] then return end
  results.set_conn_name(state.conn_key, state.conn_driver_label)
  results.show_message("Loading…")
  client.request("explore.preview", { connection_id = state.conn_id, path = node.path },
    function(err, result)
      vim.schedule(function()
        if err then
          results.show_error(err)
          return
        end
        if type(result.columns) ~= "table" then
          results.show_error("Preview not supported for this node type")
          return
        end
        local rows = type(result.rows) == "table" and result.rows or {}
        results.show_results(result.columns, rows, #rows, result.rows_total, result.duration_ms)
      end)
    end)
end

--- Create the explorer Buffer (with keymaps) if it doesn't exist or has been wiped.
local function get_or_create_buffer()
  if state.buffer and state.buffer:is_valid() then return end
  state.buffer = Buffer:new(BUFNAME, "belvedere_explorer", false, "nofile")
  state.buffer:set_keymap("n", "<CR>", on_enter,
    { nowait = true, silent = true, desc = "Expand / collapse node" })
  state.buffer:set_keymap("n", config.options.keymaps.hover_key, on_describe,
    { nowait = true, silent = true, desc = "Describe item" })
  state.buffer:set_keymap("n", "r", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local node = node_at_line(line)
    if node and not node.expandable then
      local parent_path = vim.list_slice(node.path, 1, #node.path - 1)
      node = #parent_path > 0 and node_at_path(parent_path) or nil
    end
    if node then
      node.children = nil
      load_children(node, true)
    else
      state.tree = {}
      load_root(true)
    end
  end, { nowait = true, silent = true, desc = "Refresh node" })
  state.buffer:set_keymap("n", "R", function()
    state.tree = {}
    load_root(true)
  end, { nowait = true, silent = true, desc = "Refresh explorer" })
  state.buffer:set_keymap("n", "p", on_preview_rows,
    { nowait = true, silent = true, desc = "Preview rows" })
  state.buffer:set_keymap("n", "q", function()
    local win = vim.fn.bufwinid(state.buffer.buf_id)
    if win ~= -1 then vim.api.nvim_win_close(win, true) end
  end, { nowait = true, silent = true, desc = "Close explorer" })
end

--- Open (or focus) the explorer sidebar for the given connection.
--- @param conn_id      any
--- @param conn_name    string
--- @param driver       string
--- @param conn_key     string
--- @param driver_label string
function M.open(conn_id, conn_name, driver, conn_key, driver_label)
  get_or_create_buffer()

  -- Reset the tree when switching to a different connection.
  if conn_id ~= state.conn_id then
    state.tree             = {}
    state.conn_id          = conn_id
    state.conn_key         = conn_key
    state.conn_driver_label = driver_label
    state.conn_label       = conn_name .. " (" .. driver .. ")"
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

--- Clear the explorer tree and stop the spinner (called on backend teardown).
function M.reset()
  state.tree         = {}
  state.root_loading = false
  spinner:reset()
end

return M
