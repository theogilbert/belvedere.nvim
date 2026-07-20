local M = {}

-- Node types that represent write operations across SQL and Cypher grammars.
local WRITE_NODE_TYPES = {
  insert_statement     = true, update_statement      = true,
  delete_statement     = true, merge_statement        = true,
  create_statement     = true, create_table           = true,
  create_table_as      = true, create_index           = true,
  create_view          = true, drop_statement         = true,
  drop_table           = true, drop_index             = true,
  drop_view            = true, alter_statement        = true,
  alter_table          = true, truncate_statement     = true,
  create_clause        = true, merge_clause           = true,
  delete_clause        = true, detach_delete_clause   = true,
  set_clause           = true, remove_clause          = true,
}

--- Recursively check whether `node` or any descendant is a write operation.
--- @param node userdata
--- @return boolean
local function node_has_write(node)
  if WRITE_NODE_TYPES[node:type()] then return true end
  for child in node:iter_children() do
    if node_has_write(child) then return true end
  end
  return false
end

--- @class SqlStatement
--- @field text      string   query text with trailing semicolons stripped
--- @field start_row integer  0-indexed start row
--- @field start_col integer  0-indexed start byte column
--- @field end_row   integer  0-indexed end row
--- @field end_col   integer  0-indexed end byte column

--- Return the treesitter parser for `bufnr`, or nil if one is not available.
--- @param bufnr integer
--- @return userdata|nil
local function get_parser(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  return ok and parser or nil
end

--- Return the trimmed text of `node` with trailing semicolons removed.
--- @param node userdata
--- @param bufnr integer
--- @return string
local function node_text(node, bufnr)
  local text = vim.treesitter.get_node_text(node, bufnr) or ""
  return vim.trim(text:gsub(";%s*$", ""))
end

--- Return true when any statement overlapping [start_row, end_row] contains a write node.
--- Returns false when treesitter is unavailable or no write is found.
--- @param bufnr     integer
--- @param start_row integer  0-indexed
--- @param end_row   integer  0-indexed
--- @return boolean
function M.has_write_statement(bufnr, start_row, end_row)
  local parser = get_parser(bufnr)
  if not parser then return false end
  local tree = parser:parse()[1]
  if not tree then return false end
  for node in tree:root():iter_children() do
    if node:type() == "statement" then
      local sr, _, er, _ = node:range()
      if sr <= end_row and er >= start_row then
        if node_has_write(node) then return true end
      end
    end
  end
  return false
end

--- Return the outermost statement node containing the cursor, or nil.
--- Result fields: text, start_row, start_col, end_row, end_col (all 0-indexed).
--- @param bufnr integer
--- @return SqlStatement|nil
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

-- Node types whose FROM/JOIN sources form a fresh column-resolution scope:
-- a bare or qualified column reference only resolves against the sources
-- collected from the nearest ancestor of one of these types.
local SCOPE_NODE_TYPES = {
  select_core = true, update_statement = true, delete_statement = true,
}

--- @class TableSource
--- @field alias string|nil          alias bound to this FROM/JOIN item, if any
--- @field name  string|nil          the source's own name, when it has no alias
--- @field path  string[]|nil        explore.describe path, or nil when this source
---                                   isn't a real describable table (a derived
---                                   subquery) — kept so its alias still shadows a
---                                   bare column instead of resolving to another table

--- Return the schema/table path named by `table_ref` (1 or 2 anonymous identifier
--- children: `table` or `schema.table`), or nil for an unsupported shape.
--- @param table_ref userdata
--- @param bufnr     integer
--- @return string[]|nil
local function table_ref_path(table_ref, bufnr)
  local parts = {}
  for child in table_ref:iter_children() do
    if child:named() then table.insert(parts, node_text(child, bufnr)) end
  end
  if #parts == 1 or #parts == 2 then return parts end
  return nil
end

--- Return the nearest ancestor of `node` that introduces a column-resolution
--- scope (see SCOPE_NODE_TYPES), or nil.
--- @param node userdata
--- @return userdata|nil
local function enclosing_scope(node)
  local n = node
  while n do
    if SCOPE_NODE_TYPES[n:type()] then return n end
    n = n:parent()
  end
end

--- Append the source named by `item`'s "table"/"alias" fields to `sources`.
--- `item` is a from_clause, join_clause, update_statement, or delete_statement —
--- anything exposing "table" and "alias" fields. When the table field isn't a
--- plain table_ref (a derived subquery), the source is still recorded under its
--- alias, but with `path = nil`, so it correctly shadows rather than resolves.
--- @param sources table[]
--- @param item    userdata
--- @param bufnr   integer
local function add_source(sources, item, bufnr)
  local table_ref = item:field("table")[1]
  local alias_node = item:field("alias")[1]
  local alias = alias_node and node_text(alias_node, bufnr) or nil
  if table_ref and table_ref:type() == "table_ref" then
    local path = table_ref_path(table_ref, bufnr)
    table.insert(sources, { alias = alias, name = path and path[#path], path = path })
  elseif alias then
    table.insert(sources, { alias = alias, name = nil, path = nil })
  end
end

--- Collect every FROM/JOIN source visible within `scope` (a select_core,
--- update_statement, or delete_statement).
--- @param scope userdata
--- @param bufnr integer
--- @return TableSource[]
local function collect_sources(scope, bufnr)
  local sources = {}
  if scope:type() == "select_core" then
    for from in scope:iter_children() do
      if from:type() == "from_clause" then
        add_source(sources, from, bufnr)
        for child in from:iter_children() do
          if child:type() == "join_clause" then add_source(sources, child, bufnr) end
        end
        break
      end
    end
  else
    add_source(sources, scope, bufnr)
    for child in scope:iter_children() do
      if child:type() == "from_clause" then
        add_source(sources, child, bufnr)
        for gchild in child:iter_children() do
          if gchild:type() == "join_clause" then add_source(sources, gchild, bufnr) end
        end
      end
    end
  end
  return sources
end

--- Return the source in `sources` referred to by qualifier text `name`
--- (matched against its alias, or its own name when it has none).
--- @param sources TableSource[]
--- @param name    string
--- @return TableSource|nil
local function find_source(sources, name)
  for _, s in ipairs(sources) do
    if s.alias == name or (not s.alias and s.name == name) then return s end
  end
end

--- Resolve the SQL table/column reference under the cursor to an
--- `explore.describe` path — but only when resolution is unambiguous:
---   - an identifier directly naming a table in a FROM/JOIN source
---   - an alias identifier on a FROM/JOIN source or UPDATE/DELETE target
---   - a qualified column (`alias.col`) whose qualifier matches exactly one
---     visible source
---   - a bare column, when its statement has exactly one FROM/JOIN source
--- Returns nil for everything else (multiple candidate tables, a qualifier
--- naming a derived subquery, cursor not on an identifier, no parser, etc.)
--- rather than guessing. CTEs are not tracked, so a bare table reference that
--- is actually a CTE name is passed through as-is and simply won't resolve.
--- @param bufnr integer
--- @return string[]|nil
function M.symbol_at_cursor(bufnr)
  local parser = get_parser(bufnr)
  if not parser or parser:lang() ~= "sql" then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1

  local node = tree:root():named_descendant_for_range(row, col, row, col)
  if not node or node:type() ~= "identifier" then return nil end
  local parent = node:parent()
  if not parent then return nil end

  -- Directly on a table/schema identifier of a FROM/JOIN source.
  if parent:type() == "table_ref" then
    return table_ref_path(parent, bufnr)
  end

  -- On the alias of a FROM/JOIN source or an UPDATE/DELETE target.
  local ptype = parent:type()
  if ptype == "from_clause" or ptype == "join_clause"
      or ptype == "update_statement" or ptype == "delete_statement" then
    if node == parent:field("alias")[1] then
      local table_ref = parent:field("table")[1]
      return table_ref and table_ref:type() == "table_ref" and table_ref_path(table_ref, bufnr) or nil
    end
    return nil
  end

  if ptype ~= "column_ref" then return nil end

  local scope = enclosing_scope(node)
  if not scope then return nil end
  local sources = collect_sources(scope, bufnr)

  local qualifier = parent:field("table")[1]
  if qualifier == node then
    local src = find_source(sources, node_text(node, bufnr))
    return src and src.path or nil
  end

  if qualifier then
    local src = find_source(sources, node_text(qualifier, bufnr))
    if not src or not src.path then return nil end
    local path = vim.list_extend({}, src.path)
    table.insert(path, "columns")
    table.insert(path, node_text(node, bufnr))
    return path
  end

  -- Bare column: unambiguous only when exactly one FROM/JOIN source is in scope.
  if #sources == 1 and sources[1].path then
    local path = vim.list_extend({}, sources[1].path)
    table.insert(path, "columns")
    table.insert(path, node_text(node, bufnr))
    return path
  end

  return nil
end

--- Return every top-level statement that overlaps [start_row, end_row] (0-indexed inclusive).
--- Returns nil when treesitter is unavailable or the tree cannot be parsed.
--- @param bufnr    integer
--- @param start_row integer  0-indexed
--- @param end_row   integer  0-indexed
--- @return SqlStatement[]|nil
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
