-- Manages the connections file ($XDG_CONFIG_HOME/dbelveder/connections.json).
--
-- File format:
--   { "connections": { "<name>": { "driver": "...", ... }, ... } }
local M = {}

local config = require("dbelveder.config")

-- Driver-specific fields shown in the new-connection wizard.
local DRIVER_FIELDS = {
  sqlite = {
    { key = "database", prompt = "Database file path: " },
  },
  postgres = {
    { key = "host",     prompt = "Host: ",     default = "localhost" },
    { key = "port",     prompt = "Port: ",     default = "5432" },
    { key = "database", prompt = "Database: "                        },
    { key = "user",     prompt = "User: "                            },
    { key = "password", prompt = "Password: "                        },
  },
  sqlserver = {
    { key = "host",     prompt = "Host: ",     default = "localhost" },
    { key = "port",     prompt = "Port: ",     default = "1433"      },
    { key = "database", prompt = "Database: "                        },
    { key = "user",     prompt = "User: "                            },
    { key = "password", prompt = "Password: "                        },
  },
  mongodb = {
    { key = "host",     prompt = "Host: ",     default = "localhost" },
    { key = "port",     prompt = "Port: ",     default = "27017"     },
    { key = "database", prompt = "Database (optional): "             },
    { key = "user",     prompt = "User (optional): "                 },
    { key = "password", prompt = "Password (optional): "             },
  },
}

local DRIVERS = { "sqlite", "postgres", "sqlserver", "mongodb" }

-- ── file I/O ──────────────────────────────────────────────────────────────────

local function file_path()
  return config.options.connections_file
end

function M.load()
  local path = file_path()
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or #lines == 0 then return {} end
  local ok2, parsed = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok2 or type(parsed) ~= "table" then return {} end
  return parsed.connections or {}
end

function M.save(conns)
  local path = file_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode({ connections = conns }) }, path)
end

function M.get(name)
  return M.load()[name]
end

function M.delete(name)
  local conns = M.load()
  if not conns[name] then
    vim.notify(("dbelveder: connection %q not found"):format(name), vim.log.levels.WARN)
    return
  end
  conns[name] = nil
  M.save(conns)
  vim.notify(("dbelveder: deleted connection %q"):format(name), vim.log.levels.INFO)
end

-- ── wizard helpers ────────────────────────────────────────────────────────────

-- Prompts for a sequence of fields, calling done(results) when all are filled.
-- Calls done(nil) if the user cancels any step.
local function prompt_sequence(fields, done)
  local results = {}
  local function step(i)
    if i > #fields then
      done(results)
      return
    end
    local f = fields[i]
    vim.ui.input({ prompt = f.prompt, default = f.default or "" }, function(val)
      if val == nil then done(nil) return end
      -- keep default for empty input only when a default is defined
      results[f.key] = (val ~= "" and val) or f.default or ""
      step(i + 1)
    end)
  end
  step(1)
end

-- ── public UI ─────────────────────────────────────────────────────────────────

-- Show a picker with existing connections plus a "New" option.
-- callback(name, params) on selection, callback(nil) on cancel.
function M.pick(callback)
  local conns = M.load()
  local names = vim.tbl_keys(conns)
  table.sort(names)
  local items = vim.list_extend({ "[+ New connection]" }, names)

  vim.ui.select(items, { prompt = "dbelveder — select connection:" }, function(choice)
    if not choice then callback(nil) return end
    if choice == "[+ New connection]" then
      M.create(callback)
    else
      callback(choice, conns[choice])
    end
  end)
end

-- Run the new-connection wizard, save the result, then call callback(name, params).
-- Calls callback(nil) if the user cancels.
function M.create(callback)
  vim.ui.input({ prompt = "Connection name: " }, function(name)
    if not name or name == "" then callback(nil) return end

    vim.ui.select(DRIVERS, { prompt = "Driver:" }, function(driver)
      if not driver then callback(nil) return end

      local fields = DRIVER_FIELDS[driver] or {}
      prompt_sequence(fields, function(values)
        if not values then callback(nil) return end

        -- coerce numeric port
        if values.port then values.port = tonumber(values.port) or values.port end

        local params = vim.tbl_extend("force", { driver = driver }, values)

        local conns = M.load()
        conns[name] = params
        M.save(conns)
        vim.notify(("dbelveder: saved %q"):format(name), vim.log.levels.INFO)
        callback(name, params)
      end)
    end)
  end)
end

return M
