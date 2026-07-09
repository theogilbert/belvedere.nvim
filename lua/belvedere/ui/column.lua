-- Two-pane float for browsing all columns of a table (ColumnsDescription),
-- and a single-column detail float (ColumnDescription).
-- The right pane of the two-pane browser reuses the same renderer as the
-- single-column float. Window management is handled by detail_pane.
local M = {}

local pane = require("belvedere.ui.detail_pane")
local ICON = "󰠵 "

--- @param v any
--- @return boolean
local function is_nil(v) return pane.is_nil(v) end

--- Return the estimated rendered line count for a single column detail view.
--- @param col table  ColumnDescription
--- @return integer
local function estimate_lines(col)
  local n = 2  -- header + blank
  if not is_nil(col.comment) and col.comment ~= "" then
    n = n + #vim.split(tostring(col.comment), "\n", { plain = true })
  end
  if not is_nil(col.default) and col.default ~= "" then n = n + 4 end
  local excl = type(col.exclusive_indices) == "table" and col.exclusive_indices or {}
  if #excl > 0 then n = n + 3 + #excl end
  local comp = type(col.composite_indices) == "table" and col.composite_indices or {}
  if #comp > 0 then n = n + 3 + #comp end
  local sample = type(col.sample) == "table" and col.sample or {}
  if #sample > 0 then n = n + 3 + #sample end
  return n
end

--- Build the tagged type-summary segments for a column: data_type · nullable/not null · primary key.
--- @param col table  ColumnDescription
--- @return table  tagged list consumed by detail_pane.tag_line
local function type_tags(col)
  local data_type = (not is_nil(col.data_type) and col.data_type ~= "") and col.data_type or "?"
  local tagged = { { data_type, "BelvedereExplorerTable" } }
  if col.nullable == true then
    tagged[#tagged + 1] = { "nullable", "BelvedereExplorerDim" }
  elseif col.nullable == false then
    tagged[#tagged + 1] = { "not null", "BelvedereExplorerDim" }
  end
  if col.pk then tagged[#tagged + 1] = { "primary key", "BelvedereExplorerSchema" } end
  return tagged
end

--- Populate `buf` with the detail view for a single column.
--- @param buf integer
--- @param col table  ColumnDescription
local function render(buf, col)
  local lines = {}
  local hls   = {}

  local row0 = #lines
  local line, specs = pane.tag_line(type_tags(col))
  lines[#lines + 1] = line
  for _, s in ipairs(specs) do hls[#hls + 1] = { s[1], row0, s[2], s[3] } end

  if not is_nil(col.comment) and col.comment ~= "" then
    for _, cline in ipairs(vim.split(tostring(col.comment), "\n", { plain = true })) do
      local comment_row  = #lines
      local comment_line = "  " .. cline
      lines[#lines + 1] = comment_line
      hls[#hls + 1] = { "BelvedereExplorerDim", comment_row, 0, #comment_line }
    end
  end

  lines[#lines + 1] = ""

  if not is_nil(col.default) and col.default ~= "" then
    pane.section(lines, hls, "Default")
    lines[#lines + 1] = "  " .. tostring(col.default)
    lines[#lines + 1] = ""
  end

  local excl = type(col.exclusive_indices) == "table" and col.exclusive_indices or {}
  if #excl > 0 then
    pane.section(lines, hls, "Exclusive indices")
    for _, idx in ipairs(excl) do
      local name = type(idx) == "table" and idx.index or tostring(idx)
      local irow = #lines
      lines[#lines + 1] = "  " .. name
      hls[#hls + 1] = { "BelvedereExplorerIndex", irow, 2, 2 + #name }
    end
    lines[#lines + 1] = ""
  end

  local comp = type(col.composite_indices) == "table" and col.composite_indices or {}
  if #comp > 0 then
    pane.section(lines, hls, "Composite indices")
    for _, idx in ipairs(comp) do
      local name = type(idx) == "table" and idx.index or tostring(idx)
      local irow = #lines
      lines[#lines + 1] = "  " .. name
      hls[#hls + 1] = { "BelvedereExplorerIndex", irow, 2, 2 + #name }
    end
    lines[#lines + 1] = ""
  end

  local sample = type(col.sample) == "table" and col.sample or {}
  if #sample > 0 then
    pane.section(lines, hls, "Sample values")
    for _, v in ipairs(sample) do
      lines[#lines + 1] = "  " .. tostring(v)
    end
    lines[#lines + 1] = ""
  end

  pane.apply(buf, lines, hls)
end

--- Open the two-pane columns browser.
--- @param details table  ColumnsDescription as decoded from the server response
--- @param title   string Left pane window title (caller derives from the request path)
function M.open(details, title)
  local columns = type(details.columns) == "table" and details.columns or {}
  if #columns == 0 then
    vim.notify("belvedere: no columns found", vim.log.levels.WARN)
    return
  end
  pane.open_searchable_two_pane({
    items      = columns,
    left_title = title or " Columns ",
    get_label  = function(col) return col.name end,
    get_title  = function(col) return ICON .. col.name end,
    render     = render,
    estimate   = estimate_lines,
  })
end

--- Build condensed hover lines for a column: name, type/constraints, comment.
--- A shorter view than `render()`, which also lists defaults, indices, and samples.
--- @param col table  ColumnDescription
--- @return string[] lines
--- @return DetailHlRule[] hls
function M.hover_lines(col)
  local lines, hls = {}, {}

  local name_row = #lines
  lines[#lines + 1] = col.name
  hls[#hls + 1] = { "BelvedereHeaderRow", name_row, 0, #col.name }

  local tag_row = #lines
  local line, specs = pane.tag_line(type_tags(col))
  lines[#lines + 1] = line
  for _, s in ipairs(specs) do hls[#hls + 1] = { s[1], tag_row, s[2], s[3] } end

  if not is_nil(col.comment) and col.comment ~= "" then
    for _, cline in ipairs(vim.split(tostring(col.comment), "\n", { plain = true })) do
      local comment_row  = #lines
      local comment_line = "  " .. cline
      lines[#lines + 1] = comment_line
      hls[#hls + 1] = { "BelvedereExplorerDim", comment_row, 0, #comment_line }
    end
  end

  return lines, hls
end

--- Open a single-column detail float.
--- @param col table  ColumnDescription as decoded from the server response
function M.open_single(col)
  pane.open_single({
    item     = col,
    title    = ICON .. col.name,
    render   = render,
    estimate = estimate_lines,
  })
end

return M
