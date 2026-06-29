-- A small animated braille spinner driven by a libuv timer.
--
-- Refcounted: every :start() must be matched by a :stop(); the timer only runs
-- while at least one start is outstanding.  This supports both a single spinner
-- shared by several concurrent loads (explorer) and one spinner per item
-- (connections panel).
local M = {}

M.FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local INTERVAL_MS = 80

local Spinner = {}
Spinner.__index = Spinner

--- Create and return a new Spinner instance.
--- @param on_tick fun()  called on the main loop each time the frame advances
--- @return table
function M.new(on_tick)
  return setmetatable({
    _frame   = 1,
    _refs    = 0,
    _timer   = nil,
    _on_tick = on_tick,
  }, Spinner)
end

--- Return the current frame glyph, e.g. for embedding in rendered lines.
--- @return string
function Spinner:glyph()
  return M.FRAMES[self._frame]
end

--- Stop and close the libuv timer, if one is running.
--- @param self table
local function dispose(self)
  if self._timer then
    self._timer:stop()
    self._timer:close()
    self._timer = nil
  end
end

--- Increment the refcount and start the timer when this is the first start.
function Spinner:start()
  self._refs = self._refs + 1
  if self._timer then return end
  self._timer = vim.uv.new_timer()
  self._timer:start(0, INTERVAL_MS, vim.schedule_wrap(function()
    if self._refs == 0 then return end  -- stray callback after dispose
    self._frame = (self._frame % #M.FRAMES) + 1
    self._on_tick()
  end))
end

--- Decrement the refcount; stop the timer once the last start is released.
function Spinner:stop()
  self._refs = math.max(0, self._refs - 1)
  if self._refs == 0 then dispose(self) end
end

--- Force the animation to stop regardless of outstanding starts (teardown).
function Spinner:reset()
  self._refs = 0
  dispose(self)
end

return M
