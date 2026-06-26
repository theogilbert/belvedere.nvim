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
    local result = msg.result
    if result == vim.NIL then result = nil end
    entry.cb(nil, result)
  end
end


-- Send a request; callback(err, result) is called on completion.
-- on_progress(progress) is called for each intermediate progress message (optional).
-- Returns the request id.
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

function M.cancel(request_id, callback)
  M.request("cancel", { request_id = request_id }, callback or function() end)
end

-- Start the Python backend process.
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

-- Fetch capabilities once and cache.  Subsequent calls return immediately.
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

-- Returns the cached capabilities synchronously, or nil if not yet fetched.
function M.capabilities()
  return caps_cache
end

function M.reset_capabilities()
  caps_cache   = nil
  caps_pending = {}
end

function M.stop()
  if state.job_id then
    vim.fn.jobstop(state.job_id)
  end
  M.reset_capabilities()
end

function M.is_running()
  return state.job_id ~= nil
end

return M
