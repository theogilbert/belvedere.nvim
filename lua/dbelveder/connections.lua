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
  sqlserver = {
    { key = "host",               prompt = "Host: ",               default = "localhost"                   },
    { key = "port",               prompt = "Port: ",               default = "1433"                        },
    { key = "database",           prompt = "Database: "                                                    },
    { key = "user",               prompt = "User: "                                                        },
    { key = "applicationIntent", prompt = "Application Intent: ", choices = { "READ_WRITE", "READ_ONLY" } },
    { key = "password",           prompt = "Password (empty = none): "                                     },
  },
}

local DRIVERS = { "sqlite", "sqlserver" }

-- Prompts for a password if the connection was marked as requiring one, then
-- calls callback(params) with the password injected (never persisted).
-- Calls callback(nil) on cancel.
local function prompt_password(params, callback)
  if not params.requires_password then
    callback(params)
    return
  end
  vim.ui.input({ prompt = "Password: " }, function(val)
    if val == nil then callback(nil) return end
    callback(vim.tbl_extend("force", params, { password = val }))
  end)
end

M.prompt_password = prompt_password


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
    if f.choices then
      vim.ui.select(f.choices, { prompt = f.prompt }, function(val)
        if val == nil then done(nil) return end
        results[f.key] = val
        vim.schedule(function() step(i + 1) end)
      end)
    else
      vim.ui.input({ prompt = f.prompt, default = f.default or "" }, function(val)
        if val == nil then done(nil) return end
        -- keep default for empty input only when a default is defined
        results[f.key] = (val ~= "" and val) or f.default or ""
        vim.schedule(function() step(i + 1) end)
      end)
    end
  end
  step(1)
end


-- Show a picker with existing connections plus a "New" option.
-- callback(name, params) on selection, callback(nil) on cancel.
function M.pick(callback)
  local conns = M.load()
  local names = vim.tbl_keys(conns)
  table.sort(names)
  local items = vim.list_extend(names, { "[+ New connection]" })

  vim.ui.select(items, { prompt = "dbelveder — select connection:" }, function(choice)
    if not choice then callback(nil) return end
    if choice == "[+ New connection]" then
      M.create(callback)
    else
      prompt_password(conns[choice], function(params)
        if not params then callback(nil) return end
        callback(choice, params)
      end)
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

      local pw_field, fields = nil, {}
      for _, f in ipairs(DRIVER_FIELDS[driver] or {}) do
        if f.key == "password" then pw_field = f else table.insert(fields, f) end
      end

      prompt_sequence(fields, function(values)
        if not values then callback(nil) return end

        -- coerce numeric port
        if values.port then values.port = tonumber(values.port) or values.port end

        local params = vim.tbl_extend("force", { driver = driver }, values)

        local function finish(pw)
          params.requires_password = pw ~= nil and pw ~= ""
          local conns = M.load()
          conns[name] = params  -- saved without password
          M.save(conns)
          vim.notify(("dbelveder: saved %q"):format(name), vim.log.levels.INFO)
          local params_with_pw = params.requires_password
            and vim.tbl_extend("force", params, { password = pw })
            or params
          callback(name, params_with_pw)
        end

        if pw_field then
          vim.ui.input({ prompt = pw_field.prompt }, function(pw)
            if pw == nil then callback(nil) return end
            finish(pw)
          end)
        else
          finish(nil)
        end
      end)
    end)
  end)
end

return M
