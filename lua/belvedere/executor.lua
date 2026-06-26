-- Splits a SQL string into statements and runs them against a connection,
-- dispatching each result (or batch section) to the results window.
local M = {}

local client  = require("belvedere.client")
local config  = require("belvedere.config")
local results = require("belvedere.ui.results")
local gutter  = require("belvedere.ui.gutter")
local log     = require("belvedere.log")

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

-- Returns the position of the next ";" that is outside of SQL comments,
-- or nil if none exists.
local function next_real_semi(sql, from)
  local pos = from
  local n = #sql
  while pos <= n do
    local c = sql:sub(pos, pos)
    if sql:sub(pos, pos + 1) == "--" then
      local eol = sql:find("\n", pos + 2, true)
      pos = eol and eol + 1 or n + 1
    elseif sql:sub(pos, pos + 1) == "/*" then
      local close = sql:find("*/", pos + 2, true)
      pos = close and close + 2 or n + 1
    elseif c == ";" then
      return pos
    else
      pos = pos + 1
    end
  end
  return nil
end

-- Returns { { sql, line }, ... } where line is the 0-indexed offset of each
-- statement's first non-whitespace character within the original sql string.
local function split_queries(sql)
  -- TODO use treesitter parsers for that.
  local stmts = {}
  local line_offset = 0
  local pos = 1
  while pos <= #sql do
    local semicolon_pos = next_real_semi(sql, pos)
    local chunk = semicolon_pos and sql:sub(pos, semicolon_pos - 1) or sql:sub(pos)
    local before_trim = chunk:match("^(%s*)") or ""
    local stmt_line = line_offset
    for _ in before_trim:gmatch("\n") do stmt_line = stmt_line + 1 end
    local trimmed = vim.trim(chunk)
    if trimmed ~= "" and not is_only_comments(trimmed) then
      table.insert(stmts, { sql = trimmed, line = stmt_line })
    end
    for _ in chunk:gmatch("\n") do line_offset = line_offset + 1 end
    if not semicolon_pos then break end
    pos = semicolon_pos + 1
  end
  return stmts
end

local function is_mongo(driver)
  return driver == "mongodb" or driver == "mongo"
end

local function dispatch_result(result, sql)
  if result.rows_affected ~= nil then
    results.show_rows_affected(result.rows_affected, detect_operation(sql), result.duration_ms)
  else
    local rows = result.rows or {}
    results.show_results(result.columns or {}, rows, #rows, result.rows_total, result.duration_ms)
  end
end

local function dispatch_batch_result(idx, total, result, sql)
  if result.rows_affected ~= nil then
    results.append_batch_rows_affected(idx, total, result.rows_affected, detect_operation(sql), result.duration_ms)
  else
    local rows = result.rows or {}
    results.append_batch_result(idx, total, result.columns or {}, rows, #rows, result.rows_total, result.duration_ms)
  end
end

local function execute(conn, sql, on_done, on_progress)
  return client.request(
    "execute",
    { connection_id = conn.conn_id, query = sql, params = {} },
    on_done,
    on_progress)
end

-- Run statements one after another, each appended to the batch view.
-- Each statement gets its own gutter mark and log entry created as it starts.
local function run_batch(queries, conn, idx, bufnr, first_line, had_error)
  local q           = queries[idx]
  local source_line = (bufnr and first_line ~= nil) and (first_line + q.line) or nil
  local log_id      = log.add(conn.key, bufnr, source_line, q.sql)
  local gh          = (bufnr and first_line ~= nil)
      and gutter.show_running(bufnr, first_line + q.line) or nil
  local req_id = execute(conn, q.sql, function(err, result)
    vim.schedule(function()
      gutter.unregister_request(gh)
      if err then
        had_error = true
        results.append_batch_error(idx, #queries, err)
        gutter.show_error(gh)
        log.update(conn.key, log_id, { err = err })
      else
        dispatch_batch_result(idx, #queries, result, q.sql)
        gutter.show_success(gh)
        if result.rows_affected ~= nil then
          log.update(conn.key, log_id, {
            rows_affected = result.rows_affected,
            verb          = detect_operation(q.sql),
            duration_ms   = result.duration_ms,
          })
        else
          local rows = result.rows or {}
          log.update(conn.key, log_id, {
            columns       = result.columns or {},
            rows          = rows,
            rows_returned = #rows,
            rows_total    = result.rows_total,
            duration_ms   = result.duration_ms,
          })
        end
      end
      if idx < #queries then
        run_batch(queries, conn, idx + 1, bufnr, first_line, had_error)
      end
    end)
  end)
  gutter.register_request(gh, req_id)
end

local function run_single(conn, sql, gh, conn_key, log_id)
  results.show_message("Executing…")
  local req_id = execute(conn, sql,
    function(err, result)
      vim.schedule(function()
        gutter.unregister_request(gh)
        if err then
          results.show_error(err)
          gutter.show_error(gh)
          log.update(conn_key, log_id, { err = err })
        else
          dispatch_result(result, sql)
          gutter.show_success(gh)
          if result.rows_affected ~= nil then
            log.update(conn_key, log_id, {
              rows_affected = result.rows_affected,
              verb          = detect_operation(sql),
              duration_ms   = result.duration_ms,
            })
          else
            local rows = result.rows or {}
            log.update(conn_key, log_id, {
              columns       = result.columns or {},
              rows          = rows,
              rows_returned = #rows,
              rows_total    = result.rows_total,
              duration_ms   = result.duration_ms,
            })
          end
        end
      end)
    end,
    function(progress)
      vim.schedule(function()
        results.show_message(progress.message or progress.status or "…")
      end)
    end)
  gutter.register_request(gh, req_id)
end

--- Execute `query` against `conn`.  Multiple ;-separated statements are run as
--- a labelled batch, unless the driver is document-oriented (MongoDB).
--- @param conn table   { conn_id, driver }
--- @param query string
--- @param bufnr integer|nil  source buffer (for gutter marks)
--- @param first_line integer|nil  0-indexed first line of the query in bufnr
function M.run(conn, query, bufnr, first_line)
  results.set_conn_name(conn.key, conn.driver_label, bufnr)

  local queries
  if not is_mongo(conn.driver) and next_real_semi(query, 1) then
    queries = split_queries(query)
  end

  if queries and #queries > 1 then
    results.begin_batch(#queries)
    run_batch(queries, conn, 1, bufnr, first_line, false)
  else
    local sql    = (queries and queries[1] and queries[1].sql) or query
    local log_id = log.add(conn.key, bufnr, first_line, sql)
    local gh     = (bufnr and first_line ~= nil) and gutter.show_running(bufnr, first_line) or nil
    run_single(conn, sql, gh, conn.key, log_id)
  end
end

M._split_queries    = split_queries
M._is_only_comments = is_only_comments

return M
