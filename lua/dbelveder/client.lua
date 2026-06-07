-- Manages the Python backend process and speaks the msgpack/length-prefix protocol.
--
-- Wire format (both directions):
--   [4 bytes big-endian uint32 = payload length] [msgpack payload]
--
-- Request  fields: {id, method, params}
-- Response fields: {id, result, error}
local M = {}

local uv = vim.uv or vim.loop

local state = {
  handle   = nil,
  stdin    = nil,
  stdout   = nil,
  next_id  = 1,
  pending  = {},  -- id → callback(err, result)
  buf      = "",  -- accumulated raw bytes from stdout
}

-- ── encoding / decoding ──────────────────────────────────────────────────────

local function encode_u32be(n)
  return string.pack(">I4", n)
end

local function decode_u32be(s)
  return string.unpack(">I4", s)
end

local function send_msg(msg)
  local payload = vim.mpack.encode(msg)
  local frame   = encode_u32be(#payload) .. payload
  uv.write(state.stdin, frame)
end

-- ── incoming data parsing ────────────────────────────────────────────────────

local function process_buf()
  while #state.buf >= 4 do
    local len = decode_u32be(state.buf)
    if #state.buf < 4 + len then break end
    local payload = state.buf:sub(5, 4 + len)
    state.buf     = state.buf:sub(5 + len)
    local ok, msg = pcall(vim.mpack.decode, payload)
    if ok then
      M._dispatch(msg)
    end
  end
end

local function on_stdout(err, chunk)
  if err or not chunk then return end
  state.buf = state.buf .. chunk
  process_buf()
end

-- ── response dispatch ─────────────────────────────────────────────────────────

function M._dispatch(msg)
  local id = msg.id
  if id == nil then return end
  local cb = state.pending[id]
  if not cb then return end
  state.pending[id] = nil
  local err = msg.error
  if err and err ~= vim.NIL then
    cb(err, nil)
  else
    local result = msg.result
    if result == vim.NIL then result = nil end
    cb(nil, result)
  end
end

-- ── public API ────────────────────────────────────────────────────────────────

-- Send a request; callback is called as callback(err, result).
function M.request(method, params, callback)
  if not state.handle then
    callback("Backend not running", nil)
    return
  end
  local id      = state.next_id
  state.next_id = id + 1
  state.pending[id] = callback
  send_msg({ id = id, method = method, params = params or {} })
end

-- Start the Python backend process.
function M.start(cmd)
  if state.handle then return end
  local stdin  = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)

  -- cmd is a string like "dbelveder" or "python -m dbelveder"
  local args = vim.split(cmd, "%s+")
  local exe  = table.remove(args, 1)

  local handle = uv.spawn(exe, {
    args  = args,
    stdio = { stdin, stdout, nil },
  }, function(code, _signal)
    state.handle = nil
    state.stdin  = nil
    state.stdout = nil
    if code ~= 0 then
      vim.schedule(function()
        vim.notify(("dbelveder: backend exited with code %d"):format(code), vim.log.levels.ERROR)
      end)
    end
  end)

  if not handle then
    error(("dbelveder: failed to start %q — is it installed?"):format(exe))
  end

  state.handle = handle
  state.stdin  = stdin
  state.stdout = stdout
  state.buf    = ""
  uv.read_start(stdout, on_stdout)
end

function M.stop()
  if state.handle then
    uv.process_kill(state.handle, "sigterm")
  end
end

function M.is_running()
  return state.handle ~= nil
end

return M
