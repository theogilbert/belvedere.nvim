local ts_queries = require("grannos.ts_queries")

--- Create a scratch sql buffer containing `sql`, put the cursor at the first
--- occurrence of `needle`, and return ts_queries.symbol_at_cursor's result.
--- @param sql    string
--- @param needle string  substring whose first character positions the cursor
--- @return string[]|nil
local function symbol_at(sql, needle)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { sql })
  vim.bo[buf].filetype = "sql"
  vim.api.nvim_win_set_buf(0, buf)
  local col = assert(sql:find(needle, 1, true)) - 1
  vim.api.nvim_win_set_cursor(0, { 1, col })
  return ts_queries.symbol_at_cursor(buf)
end

describe("ts_queries.symbol_at_cursor", function()
  it("resolves a column qualified by an alias", function()
    assert.same({ "users", "columns", "id" }, symbol_at("SELECT u.id FROM users u;", "id FROM"))
  end)

  it("resolves a column qualified by the table's own name", function()
    assert.same({ "users", "columns", "name" }, symbol_at("SELECT users.name FROM users;", "name FROM"))
  end)

  it("resolves a bare column when exactly one table is in scope", function()
    assert.same({ "orders", "columns", "id" }, symbol_at("SELECT id FROM orders;", "id FROM"))
  end)

  it("does not resolve a bare column when multiple tables are in scope", function()
    assert.is_nil(symbol_at("SELECT id FROM a JOIN b ON a.x = b.x;", "id FROM"))
  end)

  it("resolves a schema-qualified table name", function()
    assert.same({ "public", "users" }, symbol_at("SELECT * FROM public.users;", "users;"))
  end)

  it("resolves a table's own alias identifier", function()
    assert.same({ "users" }, symbol_at("SELECT * FROM users usr;", "usr;"))
  end)

  it("does not resolve a column qualified by a derived table", function()
    assert.is_nil(symbol_at("SELECT x.id FROM (SELECT id FROM users) x;", "x.id"))
  end)

  it("resolves the UPDATE target table via its alias", function()
    assert.same({ "users", "columns", "id" },
      symbol_at("UPDATE users AS u SET name = 'x' WHERE u.id = 1;", "id = 1"))
  end)

  it("resolves the DELETE target table via its alias", function()
    assert.same({ "users", "columns", "id" },
      symbol_at("DELETE FROM users u WHERE u.id = 1;", "id = 1"))
  end)

  it("resolves a self-join column via its alias", function()
    assert.same({ "users", "columns", "mgr_id" },
      symbol_at("SELECT a.id FROM users a JOIN users b ON a.mgr_id = b.id;", "mgr_id"))
  end)

  it("returns nil when the cursor is not on an identifier", function()
    assert.is_nil(symbol_at("SELECT id FROM orders;", "SELECT"))
  end)
end)
