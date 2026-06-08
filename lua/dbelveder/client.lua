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
}

-- ── incoming data ─────────────────────────────────────────────────────────────

local function on_stdout(_, lines, _)
  for _, line in ipairs(lines) do
    if line ~= "" then
      local ok, msg = pcall(vim.json.decode, line)
      if ok then
        M._dispatch(msg)
      end
    end
  end
end

-- ── response dispatch ─────────────────────────────────────────────────────────

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

-- ── public API ────────────────────────────────────────────────────────────────

-- Send a request; callback(err, result) is called on completion.
-- on_progress(progress) is called for each intermediate progress message (optional).
function M.request(method, params, callback, on_progress)
  if not state.job_id then
    callback("Backend not running", nil)
    return
  end
  local id      = state.next_id
  state.next_id = id + 1
  state.pending[id] = { cb = callback, progress = on_progress }
  local line = vim.json.encode({ id = id, method = method, params = params or {} }) .. "\n"
  vim.fn.chansend(state.job_id, line)
end

-- Start the Python backend process.
function M.start(cmd)
  if state.job_id then return end
  local job_id = vim.fn.jobstart(cmd, {
    on_stdout = on_stdout,
    on_exit   = function(_, code, _)
      state.job_id = nil
      if code ~= 0 then
        vim.notify(("dbelveder: backend exited with code %d"):format(code), vim.log.levels.ERROR)
      end
    end,
    stdin  = "pipe",
    stdout = "pipe",
  })
  if job_id <= 0 then
    error(("dbelveder: failed to start %q — is it installed?"):format(cmd))
  end
  state.job_id = job_id
end

function M.stop()
  if state.job_id then
    vim.fn.jobstop(state.job_id)
  end
end

function M.is_running()
  return state.job_id ~= nil
end

return M
