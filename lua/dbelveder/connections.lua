-- Manages the connections file ($XDG_CONFIG_HOME/dbelveder/connections.json).
--
-- File format:
--   { "connections": { "<name>": { "driver": "...", ... }, ... } }
local M = {}

local config = require("dbelveder.config")

-- vim.json.decode maps JSON null to vim.NIL, a truthy userdata sentinel.
-- Use this instead of plain `v or default` wherever a value comes from JSON.
local function jval(v, default)
  if v == nil or v == vim.NIL then return default end
  return v
end

-- Prompts for a password if the connection was marked as requiring one, then
-- calls callback(params) with the password injected (never persisted).
-- Calls callback(nil) on cancel.
local function prompt_password(params, callback)
  if not params.requires_password then
    callback(params)
    return
  end
  vim.ui.input({ prompt = "Password: ", secret = true }, function(val)
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


-- Return the {fields, pw_param} for a given driver from capabilities.
local function driver_fields(caps, driver)
  for _, tech in ipairs(caps.drivers or {}) do
    if tech.driver == driver then
      local pw_param, fields = nil, {}
      for _, p in ipairs(tech.params or {}) do
        if p.secret then pw_param = p else table.insert(fields, p) end
      end
      return fields, pw_param
    end
  end
  return {}, nil
end

-- Coerce fields declared as integers from their string input values.
local function coerce_integer_fields(fields, values)
  for _, p in ipairs(fields) do
    if p.type == "integer" and values[p.key] then
      values[p.key] = tonumber(values[p.key]) or values[p.key]
    end
  end
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
    local choices = type(f.choices) == "table" and f.choices or nil
    local prompt  = jval(f.label, "")
    local default = jval(f.default)
    if choices then
      vim.ui.select(choices, { prompt = prompt }, function(val)
        if val == nil then done(nil) return end
        results[f.key] = val
        vim.schedule(function() step(i + 1) end)
      end)
    else
      vim.ui.input({ prompt = prompt, default = default ~= nil and tostring(default) or "" }, function(val)
        if val == nil then done(nil) return end
        results[f.key] = (val ~= "" and val) or default or ""
        vim.schedule(function() step(i + 1) end)
      end)
    end
  end
  step(1)
end


-- Show a picker with existing connections plus a "New" option.
-- caps is the capabilities object from the server (passed to M.create if needed).
-- callback(name, params) on selection, callback(nil) on cancel.
function M.pick(caps, callback)
  local conns = M.load()
  local names = vim.tbl_keys(conns)
  table.sort(names)
  local items = vim.list_extend(names, { "[+ New connection]" })

  vim.ui.select(items, { prompt = "dbelveder — select connection:" }, function(choice)
    if not choice then callback(nil) return end
    if choice == "[+ New connection]" then
      M.create(caps, callback)
    else
      prompt_password(conns[choice], function(params)
        if not params then callback(nil) return end
        callback(choice, params)
      end)
    end
  end)
end

-- Run the new-connection wizard using server-announced capabilities.
-- caps: { server, drivers = [{driver, params=[{key,type,label,...}]}] }
-- callback(name, params) on success, callback(nil) on cancel.
function M.create(caps, callback)
  caps = caps or { server = "", drivers = {} }

  vim.ui.input({ prompt = "Connection name: " }, function(name)
    if not name or name == "" then callback(nil) return end

    vim.schedule(function()
      local driver_names = vim.tbl_map(function(t) return t.driver end, caps.drivers)

      vim.ui.select(driver_names, { prompt = "Driver:" }, function(driver)
        if not driver then callback(nil) return end

        vim.schedule(function()
          local fields, pw_param = driver_fields(caps, driver)

          prompt_sequence(fields, function(values)
            if not values then callback(nil) return end

            coerce_integer_fields(fields, values)

            local server = caps.server ~= "" and caps.server or nil
            local params = vim.tbl_extend("force",
              { driver = driver, server = server }, values)

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

            if pw_param then
              vim.ui.input({ prompt = pw_param.label .. ": ", secret = true }, function(pw)
                if pw == nil then callback(nil) return end
                finish(pw)
              end)
            else
              finish(nil)
            end
          end)
        end)
      end)
    end)
  end)
end

-- Edit (rename + update fields) an existing connection.
-- caps: capabilities object (may be nil — field editing is skipped without it).
-- callback(new_name, params) on success, callback(nil) on cancel.
function M.edit(name, caps, callback)
  caps = caps or { server = "", drivers = {} }
  local conns = M.load()
  local current = conns[name]
  if not current then
    vim.notify(("dbelveder: connection %q not found"):format(name), vim.log.levels.ERROR)
    callback(nil)
    return
  end

  vim.ui.input({ prompt = "Connection name: ", default = name }, function(new_name)
    if not new_name or new_name == "" then callback(nil) return end

    if new_name ~= name and conns[new_name] then
      vim.notify(("dbelveder: %q already exists"):format(new_name), vim.log.levels.ERROR)
      callback(nil)
      return
    end

    -- Defer: suit calls stopinsert after on_confirm returns, which would kill
    -- any new input opened synchronously here.
    vim.schedule(function()
    local driver = current.driver
    local fields, pw_param = driver_fields(caps, driver)

    -- Pre-fill each field with its current saved value.
    local fields_prefilled = {}
    for _, p in ipairs(fields) do
      local f = vim.tbl_extend("force", {}, p)
      local cur = current[p.key]
      if cur ~= nil and cur ~= vim.NIL then f.default = tostring(cur) end
      table.insert(fields_prefilled, f)
    end

    prompt_sequence(fields_prefilled, function(values)
      if not values then callback(nil) return end

      coerce_integer_fields(fields_prefilled, values)

      local params = vim.tbl_extend("force",
        { driver = driver, server = current.server }, values)

      local function finish(pw, requires_pw)
        params.requires_password = requires_pw
        local conns2 = M.load()
        if new_name ~= name then conns2[name] = nil end
        conns2[new_name] = params
        M.save(conns2)
        vim.notify(("dbelveder: saved %q"):format(new_name), vim.log.levels.INFO)
        local final = (requires_pw and pw ~= nil and pw ~= "")
          and vim.tbl_extend("force", params, { password = pw })
          or params
        callback(new_name, final)
      end

      if pw_param then
        vim.ui.input({ prompt = pw_param.label .. " (empty = keep current): ", secret = true }, function(pw)
          if pw == nil then callback(nil) return end
          if pw == "" then finish(nil, current.requires_password)
          else finish(pw, true) end
        end)
      else
        finish(nil, false)
      end
    end)
    end)  -- vim.schedule
  end)
end

return M
