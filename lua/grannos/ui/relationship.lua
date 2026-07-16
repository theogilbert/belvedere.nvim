-- Single-item detail float for a foreign key relationship (RelationshipDescription),
-- opened by hovering an edge in the schema diagram.
local M = {}

local pane = require("grannos.ui.detail_pane")
local ICON = "󰌷 "
local ARROW = "  →  "
local EDGE_LINE = string.rep("━", 40)

--- @param v any
--- @return boolean
local function is_nil(v) return pane.is_nil(v) end

--- Return the estimated rendered line count for a single relationship detail view.
--- @param rel   table       RelationshipDescription
--- @param color string|nil  highlight group of the edge this relationship was hovered
---                          from in the diagram, if any (adds the edge-color line)
--- @return integer
local function estimate_lines(rel, color)
  local n = 2  -- arrow line + blank
  if color then n = n + 2 end  -- edge-color line + blank
  if not is_nil(rel.constraint_name) and rel.constraint_name ~= "" then n = n + 4 end
  return n
end

--- Populate `buf` with the detail view for a single relationship. When `color`
--- is given (the highlight group of the edge this relationship was hovered
--- from in the diagram), draws a line in that color so the float can be
--- visually matched back to the edge it came from.
--- @param buf   integer
--- @param rel   table       RelationshipDescription
--- @param color string|nil
local function render(buf, rel, color)
  local lines = {}
  local hls   = {}

  local local_table = (not is_nil(rel.schema)     and rel.schema     .. "." or "") .. rel.table     .. "."
  local ref_table    = (not is_nil(rel.ref_schema) and rel.ref_schema .. "." or "") .. rel.ref_table .. "."

  local row_idx = #lines
  local parts, pos = {}, 0
  local function seg(s, grp)
    if grp then hls[#hls + 1] = { grp, row_idx, pos, pos + #s } end
    parts[#parts + 1] = s
    pos = pos + #s
  end

  seg("  ")
  seg(local_table,   "GrannosExplorerTable")
  seg(rel.column,     "GrannosExplorerColumn")
  seg(ARROW)
  seg(ref_table,      "GrannosExplorerTable")
  seg(rel.ref_column, "GrannosExplorerColumn")
  lines[#lines + 1] = table.concat(parts)

  if color then
    local edge_row  = #lines
    local edge_line = "  " .. EDGE_LINE
    lines[#lines + 1] = edge_line
    hls[#hls + 1] = { color, edge_row, 2, #edge_line }
  end

  lines[#lines + 1] = ""

  if not is_nil(rel.constraint_name) and rel.constraint_name ~= "" then
    pane.section(lines, hls, "Constraint")
    lines[#lines + 1] = "  " .. rel.constraint_name
    lines[#lines + 1] = ""
  end

  pane.apply(buf, lines, hls)
end

--- Open a single-relationship detail float.
--- @param rel   table       RelationshipDescription as decoded from the server response
--- @param color string|nil  highlight group of the edge this relationship was hovered
---                          from in the diagram, if any
function M.open_single(rel, color)
  pane.open_single({
    item     = rel,
    title    = ICON .. rel.column .. ARROW .. rel.ref_table .. "." .. rel.ref_column,
    render   = function(buf, item) render(buf, item, color) end,
    estimate = function(item) return estimate_lines(item, color) end,
  })
end

--- Build the one-line label for `rel` shown in the relationships browser list.
--- @param rel table  RelationshipDescription
--- @return string
local function label(rel)
  local local_table = (not is_nil(rel.schema)     and rel.schema     .. "." or "") .. rel.table
  local ref_table    = (not is_nil(rel.ref_schema) and rel.ref_schema .. "." or "") .. rel.ref_table
  return local_table .. "." .. rel.column .. ARROW .. ref_table .. "." .. rel.ref_column
end

--- Open a two-pane browser over several relationships at once, e.g. when a
--- diagram cursor position resolves to more than one distinct foreign key
--- (a branch point where multiple relationships share a trunk column). Each
--- relationship keeps its own edge color, since they can belong to different
--- tables.
--- @param rels   table[]           RelationshipDescription list as decoded from the server response
--- @param colors (string|nil)[]|nil  highlight group per entry in `rels`, same order
function M.open(rels, colors)
  if #rels == 0 then
    vim.notify("grannos: no relationships found", vim.log.levels.WARN)
    return
  end
  local items = {}
  for i, rel in ipairs(rels) do
    items[i] = { rel = rel, color = colors and colors[i] }
  end
  pane.open_searchable_two_pane({
    items      = items,
    left_title = " Relationships ",
    get_label  = function(item) return label(item.rel) end,
    get_title  = function(item) return ICON .. item.rel.column .. ARROW .. item.rel.ref_table .. "." .. item.rel.ref_column end,
    render     = function(buf, item) render(buf, item.rel, item.color) end,
    estimate   = function(item) return estimate_lines(item.rel, item.color) end,
  })
end

return M
