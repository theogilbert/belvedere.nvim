-- Generic buffer abstraction.
-- Ported from nvim-dap-df/lua/nvim-dap-df-pane/buffer.lua.
local hl = require("belvedere.hl")

local Buffer = {}
Buffer.__index = Buffer

--- @param name string
--- @param filetype string
--- @param modifiable boolean
--- @param buftype string
--- @param bufhidden string|nil  defaults to "hide"
function Buffer:new(name, filetype, modifiable, buftype, bufhidden)
  local self = setmetatable({}, Buffer)
  self.keymaps    = {}
  self.modifiable = modifiable
  self.buf_id     = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_set_option_value("buftype",    buftype,           { buf = self.buf_id })
  vim.api.nvim_set_option_value("filetype",   filetype,          { buf = self.buf_id })
  vim.api.nvim_set_option_value("bufhidden",  bufhidden or "hide", { buf = self.buf_id })
  vim.api.nvim_set_option_value("swapfile",   false,             { buf = self.buf_id })
  vim.api.nvim_set_option_value("modifiable", modifiable,        { buf = self.buf_id })
  vim.api.nvim_buf_set_name(self.buf_id, name)
  self:set_keymap("n", "g?", function() self:show_help() end,
    { silent = true, desc = "Show keymaps" })
  return self
end

--- Replace the buffer content.
--- @param lines string[]|string
function Buffer:set_content(lines)
  if type(lines) == "string" then lines = vim.split(lines, "\n") end
  for i, line in ipairs(lines) do lines[i] = line:gsub("\n", "") end
  vim.bo[self.buf_id].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf_id, 0, -1, false, lines)
  vim.bo[self.buf_id].modifiable = self.modifiable
end

--- Apply highlight rules, clearing any previous ones.
--- Each rule: { higroup, start = {line, col}, finish = {line, col} }
function Buffer:apply_highlight(rules)
  vim.api.nvim_buf_clear_namespace(self.buf_id, hl.NS_ID, 0, -1)
  for _, rule in ipairs(rules) do
    vim.hl.range(self.buf_id, hl.NS_ID, rule.higroup, rule.start, rule.finish)
  end
end

function Buffer:is_valid()
  return vim.api.nvim_buf_is_valid(self.buf_id)
end

function Buffer:close()
  if self:is_valid() then
    vim.api.nvim_buf_delete(self.buf_id, { force = true })
  end
end

--- Open a floating window listing all keymaps that have a desc.
function Buffer:show_help()
  local lines = {}
  for _, km in ipairs(self.keymaps) do
    local lhs  = km[2]
    local desc = (km[3] or {}).desc or ""
    if desc ~= "" then
      table.insert(lines, string.format("  %-6s  %s", lhs, desc))
    end
  end
  if #lines == 0 then return end

  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, #l) end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden  = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "cursor",
    row       = 1,
    col       = 0,
    width     = width,
    height    = #lines,
    style     = "minimal",
    border    = "rounded",
    title     = " keymaps ",
    title_pos = "center",
  })

  for _, key in ipairs({ "q", "<Esc>", "g?" }) do
    vim.keymap.set("n", key, function() pcall(vim.api.nvim_win_close, win, true) end,
      { buffer = buf, silent = true })
  end
end

function Buffer:set_keymap(mode, key, callback, opts)
  opts         = opts or {}
  opts.buffer  = self.buf_id
  vim.keymap.set(mode, key, callback, opts)
  table.insert(self.keymaps, { mode, key, opts })
end

return Buffer
