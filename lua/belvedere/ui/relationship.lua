-- Single-item detail float for a foreign key relationship (RelationshipDescription),
-- opened by hovering an edge in the schema diagram.
local M = {}

local pane = require("belvedere.ui.detail_pane")
local ICON = "󰌷 "
local ARROW = "  →  "

--- @param v any
--- @return boolean
local function is_nil(v) return pane.is_nil(v) end

--- Return the estimated rendered line count for a single relationship detail view.
--- @param rel table  RelationshipDescription
--- @return integer
local function estimate_lines(rel)
  local n = 2  -- arrow line + blank
  if not is_nil(rel.constraint_name) and rel.constraint_name ~= "" then n = n + 4 end
  return n
end

--- Populate `buf` with the detail view for a single relationship.
--- @param buf integer
--- @param rel table  RelationshipDescription
local function render(buf, rel)
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
  seg(local_table,   "BelvedereExplorerTable")
  seg(rel.column,     "BelvedereExplorerColumn")
  seg(ARROW)
  seg(ref_table,      "BelvedereExplorerTable")
  seg(rel.ref_column, "BelvedereExplorerColumn")
  lines[#lines + 1] = table.concat(parts)
  lines[#lines + 1] = ""

  if not is_nil(rel.constraint_name) and rel.constraint_name ~= "" then
    pane.section(lines, hls, "Constraint")
    lines[#lines + 1] = "  " .. rel.constraint_name
    lines[#lines + 1] = ""
  end

  pane.apply(buf, lines, hls)
end

--- Open a single-relationship detail float.
--- @param rel table  RelationshipDescription as decoded from the server response
function M.open_single(rel)
  pane.open_single({
    item     = rel,
    title    = ICON .. rel.column .. ARROW .. rel.ref_table .. "." .. rel.ref_column,
    render   = render,
    estimate = estimate_lines,
  })
end

return M
