-- Manages the connections file ($XDG_CONFIG_HOME/belvedere/connections.json).
--
-- File format:
--   {
--     "<server>": {
--       "<driver>": {
--         "label": "...",
--         "groups": {
--           "":             { "<name>": { <params> }, ... },
--           "<group_name>": { "<name>": { <params> }, ... }
--         }
--       }
--     }
--   }
--
-- Connection params contain only driver-specific fields plus requires_password/password.
-- driver, group and server are encoded in the internal key, not stored in params.
local M = {}

local config = require("belvedere.config")

-- Internal key: server\0driver\0group\0name  (NUL as separator, never in user strings).
function M.conn_key(server, driver, group, name)
  return (server or "") .. "\0" .. (driver or "") .. "\0" .. (group or "") .. "\0" .. name
end

-- Split a key into (server, driver, group, name).
function M.conn_parts(key)
  local parts = {}
  local s = 1
  for _ = 1, 3 do
    local e = key:find("\0", s, true)
    if not e then break end
    table.insert(parts, key:sub(s, e - 1))
    s = e + 1
  end
  table.insert(parts, key:sub(s))
  while #parts < 4 do table.insert(parts, "") end
  return parts[1], parts[2], parts[3], parts[4]
end

-- User-visible connection name (last segment of the key).
function M.conn_display_name(key)
  local _, _, _, name = M.conn_parts(key)
  return name ~= "" and name or key
end

-- vim.json.decode maps JSON null to vim.NIL, a truthy userdata sentinel.
local function jval(v, default)
  if v == nil or v == vim.NIL then return default end
  return v
end

local function prompt_password(params, callback)
  if not params.requires_password then callback(params) return end
  vim.ui.input({ prompt = "Password: ", secret = true }, function(val)
    if val == nil then callback(nil) return end
    callback(vim.tbl_extend("force", params, { password = val }))
  end)
end
M.prompt_password = prompt_password

local function file_path() return config.options.connections_file end

local function read_data()
  local path = file_path()
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or #lines == 0 then return {} end
  local ok2, parsed = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok2 or type(parsed) ~= "table" then return {} end
  return parsed
end

local function write_data(data)
  local path = file_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(data) }, path)
  vim.uv.fs_chmod(path, tonumber("600", 8))
end

-- Return the full file data.
function M.load_all()
  return read_data()
end

-- Return the driver map for a server: { driver -> { label, groups -> { group -> { name -> params } } } }.
function M.load(server)
  return (read_data()[server] or {})
end

-- Return the params for a specific 4-part key, or nil.
function M.get(key)
  local server, driver, group, name = M.conn_parts(key)
  local d = ((read_data()[server] or {})[driver] or {})
  return ((d.groups or {})[group] or {})[name]
end

-- Ensure the server → driver → group path exists in data and write the connection.
local function upsert(data, server, driver, driver_label, group, name, params)
  data[server] = data[server] or {}
  if not data[server][driver] then
    data[server][driver] = { label = driver_label, groups = {} }
  else
    if driver_label then data[server][driver].label = driver_label end
    data[server][driver].groups = data[server][driver].groups or {}
  end
  local d = data[server][driver]
  d.groups[group] = d.groups[group] or {}
  d.groups[group][name] = params
end

function M.delete(key)
  local server, driver, group, name = M.conn_parts(key)
  local data = read_data()
  local d    = (data[server] or {})[driver]
  local g    = d and (d.groups or {})[group]
  if not g or not g[name] then
    vim.notify(("belvedere: connection %q not found"):format(name), vim.log.levels.WARN)
    return
  end
  g[name] = nil
  write_data(data)
  vim.notify(("belvedere: deleted connection %q"):format(name), vim.log.levels.INFO)
end

-- Create an empty named group for a driver.  Returns false if it already exists.
function M.create_group(server, driver, driver_label, group_name)
  local data = read_data()
  data[server] = data[server] or {}
  if not data[server][driver] then
    data[server][driver] = { label = driver_label, groups = {} }
  end
  local d = data[server][driver]
  d.groups = d.groups or {}
  if d.groups[group_name] ~= nil then
    vim.notify(("belvedere: group %q already exists"):format(group_name), vim.log.levels.WARN)
    return false
  end
  d.groups[group_name] = {}
  write_data(data)
  return true
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

local function coerce_integer_fields(fields, values)
  for _, p in ipairs(fields) do
    if p.type == "integer" and values[p.key] then
      values[p.key] = tonumber(values[p.key]) or values[p.key]
    end
  end
end

local function prompt_sequence(fields, done)
  local results = {}
  local function step(i, err_prefix)
    if i > #fields then done(results) return end
    local f       = fields[i]
    local choices = type(f.choices) == "table" and f.choices or nil
    local label   = jval(f.label, "")
    local prompt  = err_prefix and (err_prefix .. label) or label
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
        if val == "" and jval(f.required, false) then
          vim.schedule(function() step(i, "[required] ") end)
          return
        end
        results[f.key] = (val ~= "" and val) or default or ""
        vim.schedule(function() step(i + 1) end)
      end)
    end
  end
  step(1)
end

-- Present a group picker for (server, driver).
-- Calls callback("") for no group, callback(name) for a named group, callback(nil) on cancel.
local function pick_group(server, driver, callback)
  local driver_data = (M.load(server)[driver] or {})
  local existing    = {}
  for gname in pairs(driver_data.groups or {}) do
    if gname ~= "" then table.insert(existing, gname) end
  end
  table.sort(existing)

  local items = { { type = "none", label = "[No group]" } }
  for _, gname in ipairs(existing) do
    table.insert(items, { type = "group", label = gname })
  end
  table.insert(items, { type = "new", label = "[+ New group]" })

  vim.ui.select(items, {
    prompt      = "Group:",
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice then callback(nil) return end
    if choice.type == "none" then
      callback("")
    elseif choice.type == "group" then
      callback(choice.label)
    else
      vim.ui.input({ prompt = "Group name: " }, function(gname)
        if not gname or gname == "" then callback(nil) return end
        callback(gname)
      end)
    end
  end)
end

function M.pick(caps, active_set, callback)
  local server      = caps.server or ""
  local server_data = M.load(server)

  local items = {}
  for driver_id, driver_data in pairs(server_data) do
    for group, group_conns in pairs(driver_data.groups or {}) do
      for name, params in pairs(group_conns) do
        local key = M.conn_key(server, driver_id, group, name)
        table.insert(items, { key = key, params = params, label = driver_data.label or driver_id })
      end
    end
  end
  table.sort(items, function(a, b) return M.conn_display_name(a.key) < M.conn_display_name(b.key) end)
  table.insert(items, { key = "[+ New connection]" })

  vim.ui.select(items, {
    prompt      = "belvedere — select connection:",
    format_item = function(item)
      if not item.params then return item.key end
      local dn  = M.conn_display_name(item.key)
      local out = item.label and (dn .. " (" .. item.label .. ")") or dn
      if active_set[item.key] then out = out .. "  [connected]" end
      return out
    end,
  }, function(choice)
    if not choice then callback(nil) return end
    if not choice.params then
      M.create(caps, callback)
    else
      prompt_password(choice.params, function(params)
        if not params then callback(nil) return end
        callback(choice.key, params)
      end)
    end
  end)
end

function M.create(caps, callback)
  caps = caps or { server = "", drivers = {} }
  local server = caps.server or ""

  vim.ui.select(caps.drivers, {
    prompt      = "Driver:",
    format_item = function(d) return d.label or d.driver end,
  }, function(d)
    if not d then callback(nil) return end
    local driver = d.driver

    vim.schedule(function()
      vim.ui.input({ prompt = "Connection name: " }, function(name)
        if not name or name == "" then
          if name ~= nil then vim.notify("belvedere: connection name is required", vim.log.levels.WARN) end
          callback(nil) return
        end

        vim.schedule(function()
          pick_group(server, driver, function(group)
            if group == nil then callback(nil) return end

            local existing = ((M.load(server)[driver] or {}).groups or {})[group] or {}
            if existing[name] then
              vim.notify(("belvedere: %q already exists in this group"):format(name), vim.log.levels.ERROR)
              callback(nil)
              return
            end

            vim.schedule(function()
              local fields, pw_param = driver_fields(caps, driver)

              prompt_sequence(fields, function(values)
                if not values then callback(nil) return end
                coerce_integer_fields(fields, values)

                local params = vim.tbl_extend("force", values, { requires_password = false })
                local key    = M.conn_key(server, driver, group, name)

                local function finish(pw, remember)
                  if remember then
                    params.password          = pw
                    params.requires_password = false
                  else
                    params.requires_password = pw ~= nil and pw ~= ""
                  end
                  local data2 = read_data()
                  upsert(data2, server, driver, d.label or driver, group, name, params)
                  write_data(data2)
                  vim.notify(("belvedere: saved %q"):format(name), vim.log.levels.INFO)
                  local out = (pw ~= nil and pw ~= "")
                    and vim.tbl_extend("force", params, { password = pw }) or params
                  callback(key, out)
                end

                if pw_param then
                  vim.ui.input({ prompt = pw_param.label .. ": ", secret = true }, function(pw)
                    if pw == nil then callback(nil) return end
                    if pw == "" then finish(pw, false) return end
                    vim.schedule(function()
                      vim.ui.select({ "No", "Yes" }, { prompt = "Remember password?" }, function(ch)
                        if ch == nil then callback(nil) return end
                        finish(pw, ch == "Yes")
                      end)
                    end)
                  end)
                else
                  finish(nil, false)
                end
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end

function M.edit(key, caps, callback)
  caps = caps or { server = "", drivers = {} }
  local server, driver, group, name = M.conn_parts(key)
  local current = M.get(key)
  if not current then
    vim.notify(("belvedere: connection %q not found"):format(name), vim.log.levels.ERROR)
    callback(nil)
    return
  end

  vim.ui.input({ prompt = "Connection name: ", default = name }, function(new_name)
    if not new_name or new_name == "" then
      if new_name ~= nil then vim.notify("belvedere: connection name is required", vim.log.levels.WARN) end
      callback(nil) return
    end
    vim.schedule(function()
    vim.ui.input({ prompt = "Group (empty = no group): ", default = group }, function(new_group)
      if new_group == nil then callback(nil) return end
      local new_key = M.conn_key(server, driver, new_group, new_name)

      if new_key ~= key and M.get(new_key) then
        vim.notify(("belvedere: %q already exists in this group"):format(new_name), vim.log.levels.ERROR)
        callback(nil)
        return
      end

      vim.schedule(function()
        local fields, pw_param = driver_fields(caps, driver)
        local fields_pre = {}
        for _, p in ipairs(fields) do
          local f = vim.tbl_extend("force", {}, p)
          local cur = current[p.key]
          if cur ~= nil and cur ~= vim.NIL then f.default = tostring(cur) end
          table.insert(fields_pre, f)
        end

        prompt_sequence(fields_pre, function(values)
          if not values then callback(nil) return end
          coerce_integer_fields(fields_pre, values)

          local driver_label = (M.load(server)[driver] or {}).label or driver
          for _, d in ipairs(caps.drivers or {}) do
            if d.driver == driver then driver_label = d.label; break end
          end

          local params = vim.tbl_extend("force", values, {
            requires_password = current.requires_password or false,
          })

          local function finish(pw, remember)
            if pw ~= nil and pw ~= "" then
              if remember then
                params.password = pw; params.requires_password = false
              else
                params.requires_password = true
              end
            else
              if current.password then
                params.password = current.password; params.requires_password = false
              else
                params.requires_password = current.requires_password
              end
              pw = current.password
            end
            local data2 = read_data()
            if new_key ~= key then
              local og = (((data2[server] or {})[driver] or {}).groups or {})[group]
              if og then og[name] = nil end
            end
            upsert(data2, server, driver, driver_label, new_group, new_name, params)
            write_data(data2)
            vim.notify(("belvedere: saved %q"):format(new_name), vim.log.levels.INFO)
            local final = (pw ~= nil and pw ~= "")
              and vim.tbl_extend("force", params, { password = pw }) or params
            callback(new_key, final)
          end

          if pw_param then
            vim.ui.input({ prompt = pw_param.label .. " (empty = keep current): ", secret = true }, function(pw)
              if pw == nil then callback(nil) return end
              if pw == "" then finish(nil, false) return end
              vim.schedule(function()
                vim.ui.select({ "No", "Yes" }, { prompt = "Remember password?" }, function(ch)
                  if ch == nil then callback(nil) return end
                  finish(pw, ch == "Yes")
                end)
              end)
            end)
          else
            finish(nil, false)
          end
        end)
      end)
    end)
    end)  -- vim.schedule
  end)
end

function M.clone(source_key, new_name, caps, callback)
  caps = caps or { server = "", drivers = {} }
  local server, driver = M.conn_parts(source_key)
  local current = M.get(source_key)
  if not current then
    vim.notify(("belvedere: connection %q not found"):format(M.conn_display_name(source_key)), vim.log.levels.ERROR)
    callback(nil)
    return
  end

  vim.schedule(function()
    pick_group(server, driver, function(group)
      if group == nil then callback(nil) return end

      local new_key  = M.conn_key(server, driver, group, new_name)
      local existing = ((M.load(server)[driver] or {}).groups or {})[group] or {}
      if existing[new_name] then
        vim.notify(("belvedere: %q already exists in this group"):format(new_name), vim.log.levels.ERROR)
        callback(nil)
        return
      end

      vim.schedule(function()
        local fields, pw_param = driver_fields(caps, driver)
        local fields_pre = {}
        for _, p in ipairs(fields) do
          local f = vim.tbl_extend("force", {}, p)
          local cur = current[p.key]
          if cur ~= nil and cur ~= vim.NIL then f.default = tostring(cur) end
          table.insert(fields_pre, f)
        end

        prompt_sequence(fields_pre, function(values)
          if not values then callback(nil) return end
          coerce_integer_fields(fields_pre, values)

          local driver_label = (M.load(server)[driver] or {}).label or driver
          for _, d in ipairs(caps.drivers or {}) do
            if d.driver == driver then driver_label = d.label; break end
          end

          local params = vim.tbl_extend("force", values, {
            requires_password = current.requires_password or false,
          })

          local function finish(pw, remember)
            if pw ~= nil and pw ~= "" then
              if remember then
                params.password = pw; params.requires_password = false
              else
                params.requires_password = true
              end
            else
              if current.password then
                params.password = current.password; params.requires_password = false
              else
                params.requires_password = current.requires_password
              end
              pw = current.password
            end
            local data2 = read_data()
            upsert(data2, server, driver, driver_label, group, new_name, params)
            write_data(data2)
            vim.notify(("belvedere: saved %q"):format(new_name), vim.log.levels.INFO)
            local final = (pw ~= nil and pw ~= "")
              and vim.tbl_extend("force", params, { password = pw }) or params
            callback(new_key, final)
          end

          if pw_param then
            vim.ui.input({ prompt = pw_param.label .. " (empty = keep current): ", secret = true }, function(pw)
              if pw == nil then callback(nil) return end
              if pw == "" then finish(nil, false) return end
              vim.schedule(function()
                vim.ui.select({ "No", "Yes" }, { prompt = "Remember password?" }, function(ch)
                  if ch == nil then callback(nil) return end
                  finish(pw, ch == "Yes")
                end)
              end)
            end)
          else
            finish(nil, false)
          end
        end)
      end)
    end)
  end)
end

return M
