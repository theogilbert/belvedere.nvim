-- Splits a SQL string into statements and runs them against a connection,
-- dispatching each result (or batch section) to the results window.
local M = {}

local client  = require("dbelveder.client")
local results = require("dbelveder.ui.results")

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

local function split_queries(sql)
  local stmts = {}
  for stmt in sql:gmatch("[^;]+") do
    local trimmed = vim.trim(stmt)
    if trimmed ~= "" and not is_only_comments(trimmed) then
      table.insert(stmts, trimmed)
    end
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
    results.show_results(result.columns or {}, result.rows or {})
  end
end

local function dispatch_batch_result(idx, total, result, sql)
  if result.rows_affected ~= nil then
    results.append_batch_rows_affected(idx, total, result.rows_affected, detect_operation(sql))
  else
    results.append_batch_result(idx, total, result.columns or {}, result.rows or {})
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
local function run_batch(queries, conn, idx)
  execute(conn, queries[idx], function(err, result)
    vim.schedule(function()
      if err then
        results.append_batch_error(idx, #queries, err)
      else
        dispatch_batch_result(idx, #queries, result, queries[idx])
      end
      if idx < #queries then
        run_batch(queries, conn, idx + 1)
      end
    end)
  end)
end

local function run_single(conn, sql)
  results.show_message("Executing…")
  execute(conn, sql,
    function(err, result)
      vim.schedule(function()
        if err then
          results.show_error(err)
        else
          dispatch_result(result, sql)
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
--- @param conn table  { conn_id, driver }
--- @param query string
function M.run(conn, query)
  results.set_conn_name(conn.name, conn.driver_label)
  local queries = (not is_mongo(conn.driver) and query:find(";"))
      and split_queries(query) or { query }

  if #queries > 1 then
    results.begin_batch(#queries)
    run_batch(queries, conn, 1)
  else
    run_single(conn, queries[1])
  end
end

return M
