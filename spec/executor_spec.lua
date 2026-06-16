local executor      = require("belvedere.executor")
local split         = executor._split_queries
local is_comments   = executor._is_only_comments

-- Helper: extract just the sql strings from split() results.
local function sqls(stmts)
  local t = {}
  for _, s in ipairs(stmts) do t[#t + 1] = s.sql end
  return t
end

-- Helper: extract just the line offsets from split() results.
local function lines(stmts)
  local t = {}
  for _, s in ipairs(stmts) do t[#t + 1] = s.line end
  return t
end

describe("split_queries – statement extraction", function()
  it("empty string returns no statements", function()
    assert.equals(0, #split(""))
  end)

  it("whitespace-only string returns no statements", function()
    assert.equals(0, #split("  \n  \t  "))
  end)

  it("single statement without semicolon", function()
    local r = split("SELECT 1")
    assert.equals(1, #r)
    assert.equals("SELECT 1", r[1].sql)
  end)

  it("single statement with trailing semicolon", function()
    local r = split("SELECT 1;")
    assert.equals(1, #r)
    assert.equals("SELECT 1", r[1].sql)
  end)

  it("trailing semicolon does not produce a spurious empty statement", function()
    assert.equals(1, #split("SELECT 1;"))
  end)

  it("two statements separated by semicolon and newline", function()
    assert.same({ "SELECT 1", "SELECT 2" }, sqls(split("SELECT 1;\nSELECT 2;")))
  end)

  it("three statements", function()
    assert.same(
      { "SELECT 1", "SELECT 2", "SELECT 3" },
      sqls(split("SELECT 1;\nSELECT 2;\nSELECT 3;"))
    )
  end)

  it("two statements on the same line", function()
    local r = split("SELECT 1; SELECT 2;")
    assert.equals(2, #r)
    assert.equals("SELECT 1", r[1].sql)
    assert.equals("SELECT 2", r[2].sql)
  end)

  it("double semicolon skips the empty statement between them", function()
    local r = split("SELECT 1;;\nSELECT 2;")
    assert.equals(2, #r)
    assert.equals("SELECT 1", r[1].sql)
    assert.equals("SELECT 2", r[2].sql)
  end)

  it("trims leading and trailing whitespace from each statement", function()
    local r = split("  SELECT 1  ;  SELECT 2  ;")
    assert.equals("SELECT 1", r[1].sql)
    assert.equals("SELECT 2", r[2].sql)
  end)

  it("preserves internal whitespace of a multi-line statement", function()
    local r = split("SELECT\n  a,\n  b\nFROM t;")
    assert.equals(1, #r)
    assert.equals("SELECT\n  a,\n  b\nFROM t", r[1].sql)
  end)
end)

describe("split_queries – line offset tracking", function()
  it("first statement is always at line 0", function()
    assert.equals(0, split("SELECT 1;")[1].line)
  end)

  it("second statement on the next line is at line 1", function()
    assert.same({ 0, 1 }, lines(split("SELECT 1;\nSELECT 2;")))
  end)

  it("three consecutive statements map to lines 0, 1, 2", function()
    assert.same({ 0, 1, 2 }, lines(split("SELECT 1;\nSELECT 2;\nSELECT 3;")))
  end)

  it("blank line between statements shifts the second statement's line", function()
    assert.same({ 0, 2 }, lines(split("SELECT 1;\n\nSELECT 2;")))
  end)

  it("multiple blank lines between statements are each counted", function()
    assert.same({ 0, 4 }, lines(split("SELECT 1;\n\n\n\nSELECT 2;")))
  end)

  it("two statements on the same line both map to line 0", function()
    assert.same({ 0, 0 }, lines(split("SELECT 1; SELECT 2;")))
  end)

  it("multi-line first statement shifts the second statement's line", function()
    -- "SELECT\n  1"  occupies lines 0–1; "SELECT 2" starts at line 2.
    assert.same({ 0, 2 }, lines(split("SELECT\n  1;\nSELECT 2;")))
  end)

  it("leading newlines before a statement are counted in its line offset", function()
    -- sql starts with a blank line, so the only statement is at line 1.
    assert.same({ 1 }, lines(split("\nSELECT 1;")))
  end)
end)

describe("split_queries – comment handling", function()
  it("a comment-only chunk separated by semicolon is skipped", function()
    local r = split("-- comment;\nSELECT 1;")
    assert.equals(1, #r)
    assert.equals("SELECT 1", r[1].sql)
  end)

  it("skipped comment-only chunk still advances the line counter", function()
    -- "-- comment" ends at line 0; SELECT 1 starts at line 1.
    local r = split("-- comment;\nSELECT 1;")
    assert.equals(1, r[1].line)
  end)

  it("block comment-only chunk is skipped", function()
    local r = split("/* setup */;\nSELECT 1;")
    assert.equals(1, #r)
    assert.equals("SELECT 1", r[1].sql)
  end)

  it("comment attached to a statement in the same chunk is preserved", function()
    -- No semicolon after the comment, so comment + SELECT share one chunk.
    local r = split("-- comment\nSELECT 1;")
    assert.equals(1, #r)
    assert.equals("-- comment\nSELECT 1", r[1].sql)
  end)

  it("all-comment input returns no statements", function()
    assert.equals(0, #split("-- one\n-- two\n-- three"))
  end)
end)

describe("is_only_comments", function()
  it("single-line comment", function()
    assert.is_true(is_comments("-- this is a comment"))
  end)

  it("block comment", function()
    assert.is_true(is_comments("/* block comment */"))
  end)

  it("multiple single-line comments", function()
    assert.is_true(is_comments("-- first\n-- second"))
  end)

  it("block comment spanning multiple lines", function()
    assert.is_true(is_comments("/*\n  block\n  comment\n*/"))
  end)

  it("empty string", function()
    assert.is_true(is_comments(""))
  end)

  it("whitespace only", function()
    assert.is_true(is_comments("   \n\t  "))
  end)

  it("plain SQL is not a comment", function()
    assert.is_false(is_comments("SELECT 1"))
  end)

  it("comment followed by SQL is not comment-only", function()
    assert.is_false(is_comments("-- comment\nSELECT 1"))
  end)

  it("SQL preceded by a block comment is not comment-only", function()
    assert.is_false(is_comments("/* comment */ SELECT 1"))
  end)

  it("mixed line and block comments with no SQL", function()
    assert.is_true(is_comments("-- line\n/* block */"))
  end)
end)
