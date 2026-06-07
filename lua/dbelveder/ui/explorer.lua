-- Tree-style DB explorer in a sidebar buffer.
-- Navigation: <CR> expands/collapses, <CR> on a leaf describes the item.
local M = {}

local client = require("dbelveder.client")

local BUFNAME = "dbelveder://explorer"
local NS      = vim.api.nvim_create_namespace("dbelveder_explorer")

-- Each node: {name, type, path, expandable, expanded, children, indent}
local tree = {}

local function get_or_create_buf()
  local existing = vim.fn.bufnr(BUFNAME)
  if existing ~= -1 then return existing end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, BUFNAME)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].filetype  = "dbelveder_explorer"
  return buf
end

local function render(buf)
  local lines = {}
  local function walk(nodes, indent)
    for _, node in ipairs(nodes) do
      local icon = node.expandable
          and (node.expanded and "▾ " or "▸ ")
          or  "  "
      lines[#lines + 1] = string.rep("  ", indent) .. icon .. node.name
              .. (node.type and ("  [" .. node.type .. "]") or "")
      if node.expanded and node.children then
        walk(node.children, indent + 1)
      end
    end
  end
  walk(tree, 0)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

-- Return the node at cursor line (1-based).
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
  return walk(tree)
end

local function load_children(node, buf)
  client.request("explore.list", { path = node.path }, function(err, result)
    if err then
      vim.schedule(function()
        vim.notify("dbelveder explorer: " .. err, vim.log.levels.ERROR)
      end)
      return
    end
    node.children = {}
    for _, item in ipairs(result.items or {}) do
      local child_path = vim.list_extend(vim.list_slice(node.path), { item.name })
      node.children[#node.children + 1] = {
        name       = item.name,
        type       = item.type,
        path       = child_path,
        expandable = item.expandable,
        expanded   = false,
        children   = nil,
      }
    end
    node.expanded = true
    vim.schedule(function() render(buf) end)
  end)
end

local function on_enter(buf)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local node  = node_at_line(line)
  if not node then return end
  if not node.expandable then
    client.request("explore.describe", { path = node.path }, function(err, result)
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
    render(buf)
  else
    load_children(node, buf)
  end
end

function M.open()
  local buf = get_or_create_buf()
  -- Open in a left vertical split if not visible
  if vim.fn.bufwinid(buf) == -1 then
    vim.cmd("topleft 35vsplit")
    vim.api.nvim_win_set_buf(0, buf)
  end
  -- Load root if tree is empty
  if #tree == 0 then
    client.request("explore.list", { path = {} }, function(err, result)
      if err then
        vim.schedule(function()
          vim.notify("dbelveder explorer: " .. err, vim.log.levels.ERROR)
        end)
        return
      end
      tree = {}
      for _, item in ipairs(result.items or {}) do
        tree[#tree + 1] = {
          name       = item.name,
          type       = item.type,
          path       = { item.name },
          expandable = item.expandable,
          expanded   = false,
          children   = nil,
        }
      end
      vim.schedule(function() render(buf) end)
    end)
  else
    render(buf)
  end

  vim.keymap.set("n", "<CR>", function() on_enter(buf) end,
    { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "R", function()
    tree = {}
    M.open()
  end, { buffer = buf, nowait = true, silent = true, desc = "Refresh explorer" })
end

function M.reset()
  tree = {}
end

return M
