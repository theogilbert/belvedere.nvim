-- Query log: persisted for the current calendar day, shared across sessions.
-- Entries are stored as JSON files under:
--   stdpath("data")/belvedere/logs/{YYYY-MM-DD}/{conn_hash}/{id}.json
-- Rows are stored inline in the entry file.
-- Older day-directories are pruned automatically (5 s after startup).
local M = {}

local today = os.date("%Y-%m-%d")
local pid   = tostring(vim.fn.getpid())
local seq   = 0

local state = {
  logs   = {},  -- [conn_key] = { entry, ... }  oldest→newest
  loaded = {},  -- [conn_key] = true once disk has been merged
}

-- ── Paths ─────────────────────────────────────────────────────────────────────

--- Return the root log directory under stdpath("data").
--- @return string
local function log_root()
  return vim.fn.stdpath("data") .. "/belvedere/logs"
end

--- Return today's log directory.
--- @return string
local function day_dir()
  return log_root() .. "/" .. today
end

--- Return the per-connection subdirectory for `conn_key` (uses a SHA-256 prefix for safety).
--- @param conn_key string
--- @return string
local function conn_subdir(conn_key)
  -- conn_key may contain NUL and other filesystem-unsafe bytes; use a short hash.
  return day_dir() .. "/" .. vim.fn.sha256(conn_key):sub(1, 16)
end

--- Return the path for a single log entry JSON file.
--- @param conn_key string
--- @param id       string
--- @return string
local function entry_path(conn_key, id)
  return conn_subdir(conn_key) .. "/" .. id .. ".json"
end

--- Generate a new unique entry id: "{today}_{pid}_{seq}".
--- @return string
local function new_id()
  seq = seq + 1
  return today .. "_" .. pid .. "_" .. string.format("%04d", seq)
end

-- ── Disk helpers ──────────────────────────────────────────────────────────────

--- Serialise `e` (minus the session-local bufnr field) to its JSON file.
--- @param e table  log entry
local function write_entry(e)
  local out = {}
  for k, v in pairs(e) do
    if k ~= "bufnr" then out[k] = v end  -- bufnr is session-local
  end
  local f = io.open(entry_path(e.conn_key, e.id), "w")
  if f then
    f:write(vim.json.encode(out))
    f:close()
  end
end

--- Merge today's on-disk entries into state.logs[conn_key].
--- Only runs once per conn_key per session.
--- @param conn_key string
local function ensure_loaded(conn_key)
  if state.loaded[conn_key] then return end
  state.loaded[conn_key] = true

  local dir = conn_subdir(conn_key)
  if vim.fn.isdirectory(dir) == 0 then return end

  local disk = {}
  for _, path in ipairs(vim.fn.glob(dir .. "/*.json", false, true)) do
    local f = io.open(path, "r")
    if f then
      local raw = f:read("*a")
      f:close()
      local ok, e = pcall(vim.json.decode, raw)
      if ok and type(e) == "table" then
        -- Attempt to resolve source_file → live bufnr in this session.
        if e.source_file and e.source_file ~= "" then
          local bn = vim.fn.bufnr(e.source_file)
          if bn > 0 then e.bufnr = bn end
        end
        table.insert(disk, e)
      end
    end
  end

  -- Skip entries already added in-session (same id already in memory).
  local mem     = state.logs[conn_key] or {}
  local mem_ids = {}
  for _, e in ipairs(mem) do mem_ids[e.id] = true end

  local merged = {}
  for _, e in ipairs(disk) do
    if not mem_ids[e.id] then table.insert(merged, e) end
  end
  for _, e in ipairs(mem) do table.insert(merged, e) end

  table.sort(merged, function(a, b)
    if a.timestamp ~= b.timestamp then return a.timestamp < b.timestamp end
    return tostring(a.id) < tostring(b.id)
  end)
  state.logs[conn_key] = merged
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Record a new query as "running" and persist it to disk.
--- `source_line` is 0-indexed.
--- @param conn_key   string
--- @param bufnr      integer|nil
--- @param source_line integer|nil  0-indexed line in the source buffer
--- @param sql        string
--- @return string  the new entry id
function M.add(conn_key, bufnr, source_line, sql)
  local id          = new_id()
  local source_file = bufnr and vim.api.nvim_buf_get_name(bufnr) or nil
  if source_file == "" then source_file = nil end
  local entry = {
    id          = id,
    conn_key    = conn_key,
    timestamp   = os.time(),
    bufnr       = bufnr,
    source_file = source_file,
    source_line = source_line,
    sql         = sql,
    status      = "running",
  }
  if not state.logs[conn_key] then state.logs[conn_key] = {} end
  table.insert(state.logs[conn_key], entry)
  vim.fn.mkdir(conn_subdir(conn_key), "p")
  write_entry(entry)
  return id
end

--- Update the entry matching `id` with the query result and re-persist it.
--- @param conn_key string
--- @param id       string
--- @param result   table  { err?, rows_affected?, verb?, columns?, rows?, rows_returned?, rows_total?, duration_ms? }
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
        e.rows          = result.rows
        e.rows_returned = result.rows_returned
        e.rows_total    = result.rows_total
        e.duration_ms   = result.duration_ms
      end
      write_entry(e)
      break
    end
  end
end

--- Return log entries for `conn_key` newest-first, merging from disk on first call.
--- @param conn_key string
--- @return table[]
function M.entries(conn_key)
  ensure_loaded(conn_key)
  local list = state.logs[conn_key]
  if not list then return {} end
  local out = {}
  for i = #list, 1, -1 do table.insert(out, list[i]) end
  return out
end

--- Return the rows stored inline in `entry` (no separate file read needed).
--- @param entry table
--- @return table[]
function M.load_rows(entry)
  return entry.rows or {}
end

-- ── Pruning ───────────────────────────────────────────────────────────────────

--- Delete all log day-directories except today's.
local function prune_old_days()
  local root = log_root()
  if vim.fn.isdirectory(root) == 0 then return end
  for _, d in ipairs(vim.fn.glob(root .. "/*", false, true)) do
    if vim.fn.isdirectory(d) == 1 and vim.fn.fnamemodify(d, ":t") ~= today then
      vim.fn.delete(d, "rf")
    end
  end
end

vim.defer_fn(prune_old_days, 5000)

return M
