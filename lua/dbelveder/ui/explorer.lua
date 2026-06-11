-- Tree-style DB explorer in a sidebar buffer.
-- Navigation: <CR> expands/collapses, <CR> on a leaf describes the item.
local M = {}

local Buffer  = require("dbelveder.buffer")
local client  = require("dbelveder.client")
local window  = require("dbelveder.ui.window")
local Spinner = require("dbelveder.ui.spinner")

local BUFNAME = "dbelveder://explorer"

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
        vim.notify("dbelveder explorer: " .. err, vim.log.levels.ERROR)
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
  if not node then return end
  if not node.expandable then
    client.request("explore.describe", { connection_id = state.conn_id, path = node.path }, function(err, result)
      if err then
        vim.schedule(function()
          vim.notify("dbelveder: " .. err, vim.log.levels.ERROR)
        end)
        return
      end
      vim.schedule(function()
        vim.notify(vim.inspect(result.details), vim.log.levels.INFO)
      end)
    end)
    return
  end
  if node.expanded then
    node.expanded = false
    render()
  else
    load_children(node)
  end
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
        vim.notify("dbelveder explorer: " .. err, vim.log.levels.ERROR)
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
  state.buffer = Buffer:new(BUFNAME, "dbelveder_explorer", false, "nofile")
  state.buffer:set_keymap("n", "<CR>", on_enter,
    { nowait = true, silent = true, desc = "Expand / collapse / describe" })
  state.buffer:set_keymap("n", "R", function()
    state.tree = {}
    load_root(true)
  end, { nowait = true, silent = true, desc = "Refresh explorer" })
end

function M.open(conn_id)
  get_or_create_buffer()

  -- Reset the tree when switching to a different connection.
  if conn_id ~= state.conn_id then
    state.tree    = {}
    state.conn_id = conn_id
  end

  local win = vim.fn.bufwinid(state.buffer.buf_id)
  if win == -1 then
    win = window.open_sidebar(state.buffer.buf_id, "left")
  end
  vim.api.nvim_set_current_win(win)

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
