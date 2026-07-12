-- ASCII schema diagram viewer, opened in a new tab.
local M = {}

local client = require("belvedere.client")
local config = require("belvedere.config")
local hl     = require("belvedere.hl")

local NS_ID = vim.api.nvim_create_namespace("BelvedereDiagram")

-- Box-drawing and tree-connector characters used to frame table boxes and join lines.
-- Matched as a set of UTF-8 byte sequences since Lua patterns are byte-oriented.
local BORDER_PATTERN = "[┌┐└┘─│├┬┴┼→]+"

-- Explicit stacking order for overlapping highlights (e.g. a table's box-border
-- region and the generic border dim both cover the same bytes; a column region
-- sits inside a table's interior row). Higher wins, regardless of call order —
-- deliberately not relying on nvim_buf_add_highlight's implicit "last extmark
-- inserted wins" behavior for same-priority overlaps.
local PRIORITY = { border = 100, table = 110, edge = 110, column = 120 }

--- Dim the box-drawing/connector characters in `lines` so they recede behind the
--- table and column names highlighted via `apply_regions`.
--- @param buf   integer
--- @param lines string[]
local function apply_border_highlight(buf, lines)
  for row, line in ipairs(lines) do
    for s, e in line:gmatch("()" .. BORDER_PATTERN .. "()") do
      vim.hl.range(buf, NS_ID, "BelvedereBorder",
        { row - 1, s - 1 }, { row - 1, e - 1 }, { priority = PRIORITY.border })
    end
  end
end

--- Join a DiagramRegion path into a table usable as a lookup key.
--- @param path string[]
--- @return string
local function path_key(path)
  return table.concat(path, "\0")
end

--- Assign each table in `regions` a highlight group: the root table (the one
--- originally requested) keeps the shared, vivid BelvedereExplorerTable color;
--- every other table gets a muted color cycled from hl.DIAGRAM_TABLE_PALETTE,
--- in the order its first region is encountered.
--- @param regions   table[]  DiagramRegion objects: { row, col_start, col_end, kind, path }
--- @param root_path string[] path of the table `explore.diagram` was requested for
--- @return table<string, string>  path-key → highlight group
local function assign_table_colors(regions, root_path)
  local palette = hl.DIAGRAM_TABLE_PALETTE
  local colors  = { [path_key(root_path)] = hl.DIAGRAM_ROOT_TABLE }
  local next_i  = 1
  for _, region in ipairs(regions) do
    if region.kind == "table" then
      local key = path_key(region.path)
      if not colors[key] then
        colors[key] = palette[(next_i - 1) % #palette + 1]
        next_i = next_i + 1
      end
    end
  end
  return colors
end

--- Highlight group for a DiagramRegion. Prefers the explicit `kind` field;
--- falls back to sniffing `path`'s shape for servers predating `kind`
--- (a column path ends in `.columns.<name>`; anything else names a table/view).
--- Table regions are colored per-table via `table_colors`; edge regions inherit
--- the color of the table that owns the foreign key (the first path segments
--- before `relationships`/`<column>`), so a relationship reads as belonging to
--- its owning table's box.
--- @param region       table  DiagramRegion object: { row, col_start, col_end, kind, path }
--- @param table_colors table<string, string>  path-key → highlight group, from assign_table_colors
--- @return string
local function region_hl_group(region, table_colors)
  local kind = region.kind
  if kind == nil then
    kind = (#region.path >= 2 and region.path[#region.path - 1] == "columns") and "column" or "table"
  end
  if kind == "column" then return "BelvedereExplorerColumn" end
  if kind == "table" then
    return table_colors[path_key(region.path)] or "BelvedereExplorerTable"
  end
  if kind == "edge" then
    local owner = vim.list_slice(region.path, 1, #region.path - 2)
    return table_colors[path_key(owner)] or "BelvedereExplorerConstraint"
  end
  return "BelvedereExplorerTable"
end

--- Apply highlight groups to `buf` for each region in `regions`. Uses explicit
--- priorities (see PRIORITY) rather than call order, since table-box and column
--- regions can cover overlapping bytes (e.g. a table's interior-row border
--- characters flank that row's column-name region).
--- @param buf          integer
--- @param regions      table[]  DiagramRegion objects: { row, col_start, col_end, kind, path }
--- @param table_colors table<string, string>  path-key → highlight group, from assign_table_colors
local function apply_regions(buf, regions, table_colors)
  for _, region in ipairs(regions) do
    local kind     = region.kind or "table"
    local priority = PRIORITY[kind] or PRIORITY.table
    vim.hl.range(buf, NS_ID, region_hl_group(region, table_colors),
      { region.row, region.col_start }, { region.row, region.col_end }, { priority = priority })
  end
end

--- Find the region under a 0-indexed (row, col) cursor position, if any.
--- @param regions table[]  DiagramRegion objects: { row, col_start, col_end, kind, path }
--- @param row     integer  0-indexed
--- @param col     integer  0-indexed byte offset
--- @return table|nil
local function region_at(regions, row, col)
  for _, region in ipairs(regions) do
    if region.row == row and col >= region.col_start and col < region.col_end then
      return region
    end
  end
  return nil
end

--- Request an ASCII diagram for the table at `path` and display it in a new tab.
--- @param conn_id any
--- @param path    string[]
--- @param title   string  table name, used in the buffer name
function M.open(conn_id, path, title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  Loading…" })
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "belvedere://diagram/" .. title)

  vim.cmd("tabnew")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function() pcall(vim.cmd, "tabclose") end,
      { buffer = buf, silent = true, nowait = true })
  end

  local regions = {}

  --- Handle the hover key: resolve the region under the cursor and describe it.
  local function on_hover()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local region = region_at(regions, cursor[1] - 1, cursor[2])
    if not region then return end

    client.request("explore.describe", { connection_id = conn_id, path = region.path }, function(err, result)
      vim.schedule(function()
        if err then
          vim.notify("belvedere: " .. err, vim.log.levels.ERROR)
          return
        end
        local details = result and result.details
        if not details or details == vim.NIL then
          vim.notify("belvedere: nothing to describe here", vim.log.levels.WARN)
          return
        end
        if details.type == "column" then
          require("belvedere.ui.column").open_single(details)
        elseif details.type == "columns" then
          local parts = vim.list_slice(region.path, 1, #region.path - 1)
          local ctx   = table.concat(parts, ".")
          local title = ctx ~= "" and (" Columns · " .. ctx .. " ") or " Columns "
          require("belvedere.ui.column").open(details, title)
        elseif details.type == "relationship" then
          require("belvedere.ui.relationship").open_single(details)
        else
          require("belvedere.ui.explorer").open_describe_float(
            details, { name = region.path[#region.path], type = "table" })
        end
      end)
    end)
  end
  vim.keymap.set("n", config.options.keymaps.hover_key, on_hover,
    { buffer = buf, silent = true, nowait = true })

  client.request("explore.diagram", { connection_id = conn_id, path = path }, function(err, result)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      local lines = err and { "  " .. err } or vim.split(result and result.diagram or "", "\n")
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      if not err then
        apply_border_highlight(buf, lines)
        if result and result.regions then
          regions = result.regions
          apply_regions(buf, regions, assign_table_colors(regions, path))
        end
      end
    end)
  end)
end

return M
