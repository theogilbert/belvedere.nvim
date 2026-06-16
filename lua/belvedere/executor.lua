-- Splits a SQL string into statements and runs them against a connection,
-- dispatching each result (or batch section) to the results window.
local M = {}

local client  = require("belvedere.client")
local config  = require("belvedere.config")
local results = require("belvedere.ui.results")
local gutter  = require("belvedere.ui.gutter")

-- Past-tense verb shown for DML statements, keyed by leading keyword.
local DML_VERBS = {
  insert = "inserted",
  update = "updated",
  delete = "deleted",
  merge  = "merged",
}

local function detect_operation(sql)
  local word = (vim.trim(sql):match("^(%a+)") or ""):lower()
  return DML_VERBS[word] or "affected"
end

local function is_only_comments(sql)
  local stripped = sql:gsub("/%*.-%*/", ""):gsub("%-%-[^\n]*", "")
  return vim.trim(stripped) == ""
end

-- Returns { { sql, line }, ... } where line is the 0-indexed offset of each
-- statement's first non-whitespace character within the original sql string.
local function split_queries(sql)
  local stmts = {}
  local line_offset = 0
  local pos = 1
  while pos <= #sql do
    local semi_pos = sql:find(";", pos, true)
    local chunk = semi_pos and sql:sub(pos, semi_pos - 1) or sql:sub(pos)
    local before_trim = chunk:match("^(%s*)") or ""
    local stmt_line = line_offset
    for _ in before_trim:gmatch("\n") do stmt_line = stmt_line + 1 end
    local trimmed = vim.trim(chunk)
    if trimmed ~= "" and not is_only_comments(trimmed) then
      table.insert(stmts, { sql = trimmed, line = stmt_line })
    end
    for _ in chunk:gmatch("\n") do line_offset = line_offset + 1 end
    if not semi_pos then break end
    pos = semi_pos + 1
  end
  return stmts
end

local function is_mongo(driver)
  return driver == "mongodb" or driver == "mongo"
end

local function dispatch_result(result, sql)
  if result.rows_affected ~= nil then
    results.show_rows_affected(result.rows_affected, detect_operation(sql))
  else
    local rows = result.rows or {}
    results.show_results(result.columns or {}, rows, #rows, result.rows_total)
  end
end

local function dispatch_batch_result(idx, total, result, sql)
  if result.rows_affected ~= nil then
    results.append_batch_rows_affected(idx, total, result.rows_affected, detect_operation(sql))
  else
    local rows = result.rows or {}
    results.append_batch_result(idx, total, result.columns or {}, rows, #rows, result.rows_total)
  end
end

local function execute(conn, sql, on_done, on_progress)
  client.request(
    "execute",
    { connection_id = conn.conn_id, query = sql, params = {} },
    on_done,
    on_progress)
end

-- Run statements one after another, each appended to the batch view.
-- Each statement gets its own gutter mark created as it starts.
local function run_batch(queries, conn, idx, bufnr, first_line, had_error)
  local q = queries[idx]
  local gh = (bufnr and first_line ~= nil)
      and gutter.show_running(bufnr, first_line + q.line) or nil
  execute(conn, q.sql, function(err, result)
    vim.schedule(function()
      if err then
        had_error = true
        results.append_batch_error(idx, #queries, err)
        gutter.show_error(gh)
      else
        dispatch_batch_result(idx, #queries, result, q.sql)
        gutter.show_success(gh)
      end
      if idx < #queries then
        run_batch(queries, conn, idx + 1, bufnr, first_line, had_error)
      end
    end)
  end)
end

local function run_single(conn, sql, gh)
  results.show_message("Executing…")
  execute(conn, sql,
    function(err, result)
      vim.schedule(function()
        if err then
          results.show_error(err)
          gutter.show_error(gh)
        else
          dispatch_result(result, sql)
          gutter.show_success(gh)
        end
      end)
    end,
    function(progress)
      vim.schedule(function()
        results.show_message(progress.message or progress.status or "…")
      end)
    end)
end

--- Execute `query` against `conn`.  Multiple ;-separated statements are run as
--- a labelled batch, unless the driver is document-oriented (MongoDB).
--- @param conn table   { conn_id, driver }
--- @param query string
--- @param bufnr integer|nil  source buffer (for gutter marks)
--- @param first_line integer|nil  0-indexed first line of the query in bufnr
function M.run(conn, query, bufnr, first_line)
  results.set_conn_name(conn.name, conn.driver_label)

  local queries
  if not is_mongo(conn.driver) and query:find(";") then
    queries = split_queries(query)
  end

  if queries and #queries > 1 then
    results.begin_batch(#queries)
    run_batch(queries, conn, 1, bufnr, first_line, false)
  else
    local sql = (queries and queries[1] and queries[1].sql) or query
    local gh = (bufnr and first_line ~= nil) and gutter.show_running(bufnr, first_line) or nil
    run_single(conn, sql, gh)
  end
end

M._split_queries    = split_queries
M._is_only_comments = is_only_comments

return M
