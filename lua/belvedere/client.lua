-- Manages the Python backend process and speaks newline-delimited JSON.
--
-- Wire format (both directions): one JSON object per line.
--
-- Request  fields: {id, method, params}
-- Response fields: {id, result, error}
local M = {}

local state = {
  job_id   = nil,
  next_id  = 1,
  pending  = {},  -- id → callback(err, result)
  line_buf = "",  -- accumulates partial lines across on_stdout calls
}

local caps_cache   = nil  -- cached capabilities result
local caps_pending = {}   -- callbacks waiting for the first fetch


-- Neovim jobstart line convention: data[1] continues the previous partial
-- line; data[#data] is always the (possibly empty) start of the next line.
--- @param _ any
--- @param data string[]
--- @param __ any
local function on_stdout(_, data, _)
  state.line_buf = state.line_buf .. data[1]
  for i = 2, #data do
    local line = state.line_buf
    state.line_buf = data[i]
    if line ~= "" then
      local ok, msg = pcall(vim.json.decode, line)
      if ok then
        M._dispatch(msg)
      end
    end
  end
end


--- Recursively replace vim.NIL sentinels with nil in a decoded JSON value.
--- @param v any
--- @return any
local function strip_nil(v)
  if v == vim.NIL then return nil end
  if type(v) ~= "table" then return v end
  for k, val in pairs(v) do
    v[k] = strip_nil(val)
  end
  return v
end

--- Route an incoming server message to its waiting callback.
--- Progress messages invoke on_progress without resolving the pending entry.
--- @param msg table  decoded JSON message from the server
function M._dispatch(msg)
  local id = msg.id
  if id == nil then return end
  local entry = state.pending[id]
  if not entry then return end
  if msg.progress then
    if entry.progress then entry.progress(msg.progress) end
    return
  end
  state.pending[id] = nil
  local err = msg.error
  if err and err ~= vim.NIL then
    entry.cb(err, nil)
  else
    entry.cb(nil, strip_nil(msg.result))
  end
end


--- Send a JSON-RPC request to the backend.
--- @param method      string
--- @param params      table|nil
--- @param callback    fun(err: string|nil, result: any)  called on completion
--- @param on_progress fun(progress: table)|nil           called for each intermediate progress message
--- @return integer|nil  request id, or nil when the backend is not running
function M.request(method, params, callback, on_progress)
  if not state.job_id then
    callback("Backend not running", nil)
    return nil
  end
  local id      = state.next_id
  state.next_id = id + 1
  state.pending[id] = { cb = callback, progress = on_progress }
  local p = (params == nil or vim.tbl_isempty(params)) and vim.empty_dict() or params
  local line = vim.json.encode({ id = id, method = method, params = p }) .. "\n"
  vim.fn.chansend(state.job_id, line)
  return id
end

--- Send a cancellation request for `request_id`.
--- @param request_id integer
--- @param callback   fun(err: string|nil, result: any)|nil
function M.cancel(request_id, callback)
  M.request("cancel", { request_id = request_id }, callback or function() end)
end

--- Start the backend process identified by `cmd`.
--- Errors if the process cannot be spawned (e.g. command not found).
--- @param cmd string  shell command to launch the backend
function M.start(cmd)
  if state.job_id then return end
  local job_id = vim.fn.jobstart(cmd, {
    on_stdout = on_stdout,
    on_exit   = function(_, code, _)
      state.job_id   = nil
      state.line_buf = ""
      local pending  = state.pending
      state.pending  = {}
      M.reset_capabilities()
      for _, entry in pairs(pending) do
        entry.cb("backend exited", nil)
      end
      if code ~= 0 then
        vim.notify(("belvedere: backend exited with code %d"):format(code), vim.log.levels.ERROR)
      end
    end,
    stdin  = "pipe",
    stdout = "pipe",
  })
  if job_id <= 0 then
    error(("belvedere: failed to start %q — is it installed?"):format(cmd))
  end
  state.job_id = job_id
end

--- Fetch capabilities once and cache the result; subsequent calls return immediately.
--- @param callback fun(caps: table)
function M.ensure_capabilities(callback)
  if caps_cache then callback(caps_cache) return end
  table.insert(caps_pending, callback)
  if #caps_pending > 1 then return end  -- request already in-flight
  M.request("capabilities", {}, function(err, result)
    caps_cache = (not err and result) or { server = "", drivers = {} }
    local waiting = caps_pending
    caps_pending = {}
    for _, cb in ipairs(waiting) do cb(caps_cache) end
  end)
end

--- Return the cached capabilities synchronously, or nil if not yet fetched.
--- @return table|nil
function M.capabilities()
  return caps_cache
end

--- Clear the capabilities cache and any pending callbacks.
function M.reset_capabilities()
  caps_cache   = nil
  caps_pending = {}
end

--- Stop the backend process and reset capabilities.
function M.stop()
  if state.job_id then
    vim.fn.jobstop(state.job_id)
  end
  M.reset_capabilities()
end

--- Return true when the backend process is currently running.
--- @return boolean
function M.is_running()
  return state.job_id ~= nil
end

return M
