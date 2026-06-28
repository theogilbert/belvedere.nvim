local M = {}

local function get_parser(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  return ok and parser or nil
end

local function node_text(node, bufnr)
  local text = vim.treesitter.get_node_text(node, bufnr) or ""
  return vim.trim(text:gsub(";%s*$", ""))
end

-- Returns { text, start_row } for the outermost statement containing the cursor, or nil.
function M.statement_at_cursor(bufnr)
  local parser = get_parser(bufnr)
  if not parser then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1  -- 0-indexed

  local node = tree:root():named_descendant_for_range(row, col, row, col)
  if not node then return nil end

  -- Walk up, keeping track of the highest 'statement' ancestor found.
  local stmt = nil
  local n = node
  while n do
    if n:type() == "statement" then stmt = n end
    n = n:parent()
  end
  if not stmt then return nil end

  local text = node_text(stmt, bufnr)
  if text == "" then return nil end

  local sr, sc, er, ec = stmt:range()
  return { text = text, start_row = sr, start_col = sc, end_row = er, end_col = ec }
end

-- Returns a list of { text, start_row } for every top-level statement whose range
-- overlaps [start_row, end_row] (both 0-indexed, inclusive), or nil on failure.
function M.statements_in_range(bufnr, start_row, end_row)
  local parser = get_parser(bufnr)
  if not parser then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end

  local stmts = {}
  for node in tree:root():iter_children() do
    if node:type() == "statement" then
      local sr, sc, er, ec = node:range()
      if sr <= end_row and er >= start_row then
        local text = node_text(node, bufnr)
        if text ~= "" then
          table.insert(stmts, { text = text, start_row = sr, start_col = sc, end_row = er, end_col = ec })
        end
      end
    end
  end

  return #stmts > 0 and stmts or nil
end

return M
