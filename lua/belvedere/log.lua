-- In-session query log.
-- Stores metadata in memory; serializes full row data to per-PID temp files.
local M = {}

local state = {
  logs    = {},  -- [conn_key] = { entry, ... }, ordered oldest→newest
  next_id = 1,
}

local log_dir  -- lazily initialized on first write

local function ensure_dir()
  if log_dir then return log_dir end
  log_dir = vim.fn.stdpath("cache") .. "/belvedere/" .. vim.fn.getpid() .. "/log"
  vim.fn.mkdir(log_dir, "p")
  return log_dir
end

local function rows_path(id)
  return ensure_dir() .. "/" .. id .. ".json"
end

--- Record a new query as "running". Returns the log_id for later update.
--- source_line is 0-indexed (matches nvim convention used in executor/gutter).
function M.add(conn_key, bufnr, source_line, sql)
  local id = state.next_id
  state.next_id = state.next_id + 1
  if not state.logs[conn_key] then state.logs[conn_key] = {} end
  table.insert(state.logs[conn_key], {
    id          = id,
    timestamp   = os.time(),
    bufnr       = bufnr,
    source_line = source_line,
    sql         = sql,
    status      = "running",
  })
  return id
end

--- Update the entry matching `id` with the query result.
--- result must have one of: .err (string), .rows_affected + .verb + .duration_ms,
--- or .columns + .rows + .rows_returned + .rows_total + .duration_ms.
function M.update(conn_key, id, result)
  local list = state.logs[conn_key]
  if not list then return end
  for _, e in ipairs(list) do
    if e.id == id then
      if result.err then
        e.status    = "error"
        e.error_msg = result.err
      elseif result.rows_affected ~= nil then
        e.status        = "rows_affected"
        e.rows_affected = result.rows_affected
        e.verb          = result.verb
        e.duration_ms   = result.duration_ms
      else
        e.status        = "success"
        e.columns       = result.columns
        e.rows_returned = result.rows_returned
        e.rows_total    = result.rows_total
        e.duration_ms   = result.duration_ms
        local rows = result.rows
        if rows and #rows > 0 then
          local path = rows_path(id)
          local f = io.open(path, "w")
          if f then
            f:write(vim.json.encode(rows))
            f:close()
            e.rows_file = path
          end
        end
      end
      break
    end
  end
end

--- Return log entries for conn_key, newest first.
function M.entries(conn_key)
  local list = state.logs[conn_key]
  if not list then return {} end
  local out = {}
  for i = #list, 1, -1 do table.insert(out, list[i]) end
  return out
end

--- Load rows for a success entry from its temp file. Returns {} on failure.
function M.load_rows(entry)
  if not entry.rows_file then return {} end
  local f = io.open(entry.rows_file, "r")
  if not f then return {} end
  local raw = f:read("*a")
  f:close()
  local ok, rows = pcall(vim.json.decode, raw)
  return ok and rows or {}
end

--- Delete all temp files and clear the in-memory log.
function M.clear()
  if log_dir then
    vim.fn.delete(vim.fn.stdpath("cache") .. "/belvedere/" .. vim.fn.getpid(), "rf")
    log_dir = nil
  end
  state.logs = {}
end

vim.api.nvim_create_autocmd("VimLeavePre", { once = true, callback = M.clear })

return M
