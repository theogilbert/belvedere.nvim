-- Two-pane float for browsing all columns of a table (ColumnsDescription),
-- and a single-column detail float (ColumnDescription).
-- The right pane of the two-pane browser reuses the same renderer as the
-- single-column float. Window management is handled by detail_pane.
local M = {}

local pane = require("belvedere.ui.detail_pane")
local ICON = "󰠵 "

local function is_nil(v) return pane.is_nil(v) end

local function estimate_lines(col)
  local n = 2  -- header + blank
  if not is_nil(col.default) and col.default ~= "" then n = n + 4 end
  if not is_nil(col.comment) and col.comment ~= "" then n = n + 4 end
  local sample = type(col.sample) == "table" and col.sample or {}
  if #sample > 0 then n = n + 3 + #sample end
  local excl = type(col.exclusive_indices) == "table" and col.exclusive_indices or {}
  if #excl > 0 then n = n + 3 + #excl end
  local comp = type(col.composite_indices) == "table" and col.composite_indices or {}
  if #comp > 0 then n = n + 3 + #comp end
  return n
end

local function render(buf, col)
  local lines = {}
  local hls   = {}

  -- One-liner: data_type · [nullable/not null] · [primary key]
  local data_type = (not is_nil(col.data_type) and col.data_type ~= "") and col.data_type or "?"
  local tagged = { { data_type, "BelvedereExplorerTable" } }
  if col.nullable == true then
    tagged[#tagged + 1] = { "nullable", "BelvedereExplorerDim" }
  elseif col.nullable == false then
    tagged[#tagged + 1] = { "not null", "BelvedereExplorerDim" }
  end
  if col.pk then tagged[#tagged + 1] = { "primary key", "BelvedereExplorerSchema" } end

  local row0 = #lines
  local line, specs = pane.tag_line(tagged)
  lines[#lines + 1] = line
  for _, s in ipairs(specs) do hls[#hls + 1] = { s[1], row0, s[2], s[3] } end
  lines[#lines + 1] = ""

  if not is_nil(col.default) and col.default ~= "" then
    pane.section(lines, hls, "Default")
    lines[#lines + 1] = "  " .. tostring(col.default)
    lines[#lines + 1] = ""
  end

  if not is_nil(col.comment) and col.comment ~= "" then
    pane.section(lines, hls, "Comment")
    lines[#lines + 1] = "  " .. tostring(col.comment)
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
  pane.open_two_pane({
    items      = columns,
    left_title = title or " Columns ",
    get_label  = function(col) return col.name end,
    get_title  = function(col) return ICON .. col.name end,
    render     = render,
    estimate   = estimate_lines,
  })
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
