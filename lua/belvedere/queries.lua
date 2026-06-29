-- Pure data module for saved queries.  No UI.
--
-- Storage: one file per query under $XDG_DATA_HOME/belvedere/queries/
--
-- Directory layout mirrors the scope hierarchy:
--   <base>/driver/<server>/<driver>/<name>.<ext>
--   <base>/group/<server>/<driver>/<group>/<name>.<ext>   (group="" → "_")
--   <base>/connection/<server>/<driver>/<group>/<conn>/<name>.<ext>
--
-- File mtime is used as created_at; no separate metadata file is needed.
local M = {}

local config      = require("belvedere.config")
local connections = require("belvedere.connections")

--- Return the queries base directory from config.
--- @return string
local function base() return config.options.queries_dir end

-- "_" is the sentinel directory name for the empty-group slot.
local NOGROUP = "_"

--- Build the relative scope key for a connection at the given hierarchy level.
--- @param level    "driver"|"group"|"connection"
--- @param conn_key string
--- @return string
function M.scope_key(level, conn_key)
  local server, driver, group, name = connections.conn_parts(conn_key)
  local g = group ~= "" and group or NOGROUP
  if level == "driver" then
    return table.concat({ "driver", server, driver }, "/")
  elseif level == "group" then
    return table.concat({ "group", server, driver, g }, "/")
  else
    return table.concat({ "connection", server, driver, g, name }, "/")
  end
end

--- Return a human-readable label for `scope_key` (e.g. "driver: postgres").
--- @param scope_key string
--- @return string
function M.scope_label(scope_key)
  local parts = vim.split(scope_key, "/", { plain = true })
  local level = parts[1]
  if level == "driver" then
    return "driver: " .. (parts[3] or "")
  elseif level == "group" then
    local g = parts[4]
    return "group: " .. ((g and g ~= NOGROUP) and g or "[no group]")
  else
    return "conn: " .. (parts[5] or "")
  end
end

--- Return the filesystem directory for `scope_key`.
--- @param scope_key string
--- @return string
local function scope_dir(scope_key) return base() .. "/" .. scope_key end

--- Return the path of the existing file for (scope_key, name), or nil if not found.
--- @param scope_key string
--- @param name      string
--- @return string|nil
local function find_file(scope_key, name)
  local dir = scope_dir(scope_key)
  if vim.fn.isdirectory(dir) == 0 then return nil end
  for _, fname in ipairs(vim.fn.readdir(dir)) do
    local path = dir .. "/" .. fname
    if vim.fn.isdirectory(path) == 0 then
      local stem = fname:match("^(.+)%.[^%.]+$") or fname
      if stem == name then return path end
    end
  end
end

--- Save a query to disk.
--- `ext` is the file extension without dot (e.g. "sql", "cypher").
--- Returns false if a file with that name already exists in the scope.
--- @param scope_key string
--- @param name      string
--- @param content   string
--- @param ext       string
--- @return boolean
function M.save(scope_key, name, content, ext)
  if find_file(scope_key, name) then return false end
  local dir      = scope_dir(scope_key)
  local filename = ext ~= "" and (name .. "." .. ext) or name
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), dir .. "/" .. filename)
  return true
end

--- Return all queries for a single scope: { name → { content, created_at, ext, path } }.
--- @param scope_key string
--- @return table<string, {content: string, created_at: integer, ext: string, path: string}>
function M.list(scope_key)
  local dir    = scope_dir(scope_key)
  if vim.fn.isdirectory(dir) == 0 then return {} end
  local result = {}
  for _, fname in ipairs(vim.fn.readdir(dir)) do
    local path = dir .. "/" .. fname
    if vim.fn.isdirectory(path) == 0 then
      local stem = fname:match("^(.+)%.[^%.]+$") or fname
      local ext  = fname:match("%.([^%.]+)$") or ""
      result[stem] = {
        content    = table.concat(vim.fn.readfile(path), "\n"),
        created_at = vim.fn.getftime(path),
        ext        = ext,
        path       = path,
      }
    end
  end
  return result
end

--- Return all queries visible to `conn_key`, most-specific scope first (connection > group > driver).
--- Duplicate names are deduplicated; the most-specific definition wins.
--- @param conn_key string
--- @return {scope_key: string, name: string, content: string, created_at: integer, ext: string, path: string}[]
function M.list_for_conn(conn_key)
  local seen, result = {}, {}
  for _, level in ipairs({ "connection", "group", "driver" }) do
    local sk = M.scope_key(level, conn_key)
    for name, q in pairs(M.list(sk)) do
      if not seen[name] then
        seen[name] = true
        table.insert(result, { scope_key = sk, name = name, content = q.content, created_at = q.created_at, ext = q.ext, path = q.path })
      end
    end
  end
  return result
end

--- Delete the file for (scope_key, name) if it exists.
--- @param scope_key string
--- @param name      string
function M.delete(scope_key, name)
  local path = find_file(scope_key, name)
  if path then os.remove(path) end
end

return M
