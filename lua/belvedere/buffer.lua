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

--- Return true when the underlying buffer handle is still valid.
--- @return boolean
function Buffer:is_valid()
  return vim.api.nvim_buf_is_valid(self.buf_id)
end

--- Delete the underlying buffer (force=true), if valid.
function Buffer:close()
  if self:is_valid() then
    vim.api.nvim_buf_delete(self.buf_id, { force = true })
  end
end

--- Open a floating window listing all keymaps that have a desc.
--- Keymaps with a `group` field in their opts are rendered under section headers.
function Buffer:show_help()
  local keymaps = {}
  for _, km in ipairs(self.keymaps) do
    local opts = km[3] or {}
    local desc = opts.desc or ""
    if desc ~= "" then
      table.insert(keymaps, { lhs = km[2], desc = desc, group = opts.group or "" })
    end
  end
  if #keymaps == 0 then return end

  local has_groups = false
  for _, km in ipairs(keymaps) do
    if km.group ~= "" then has_groups = true; break end
  end

  local key_w = 0
  for _, km in ipairs(keymaps) do
    key_w = math.max(key_w, vim.fn.strdisplaywidth(km.lhs))
  end

  local lines, header_lnums = {}, {}

  if has_groups then
    local group_order, buckets, seen = {}, {}, {}
    for _, km in ipairs(keymaps) do
      local g = km.group ~= "" and km.group or "\0ungrouped"
      if not seen[g] then seen[g] = true; table.insert(group_order, g) end
      if not buckets[g] then buckets[g] = {} end
      table.insert(buckets[g], km)
    end

    for i, g in ipairs(group_order) do
      if i > 1 then table.insert(lines, "") end
      if g ~= "\0ungrouped" then
        table.insert(lines, g)
        header_lnums[#lines] = true
      end
      for _, km in ipairs(buckets[g]) do
        local pad = string.rep(" ", key_w - vim.fn.strdisplaywidth(km.lhs))
        table.insert(lines, ("  %s%s  %s"):format(km.lhs, pad, km.desc))
      end
    end
  else
    for _, km in ipairs(keymaps) do
      local pad = string.rep(" ", key_w - vim.fn.strdisplaywidth(km.lhs))
      table.insert(lines, ("  %s%s  %s"):format(km.lhs, pad, km.desc))
    end
  end

  local width = 1
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden  = "wipe"

  for lnum in pairs(header_lnums) do
    vim.hl.range(buf, hl.NS_ID, "BelvedereHeaderRow", { lnum - 1, 0 }, { lnum - 1, -1 })
  end

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
  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)

  for _, key in ipairs({ "q", "<Esc>", "g?" }) do
    vim.keymap.set("n", key, function() pcall(vim.api.nvim_win_close, win, true) end,
      { buffer = buf, silent = true })
  end
end

--- Register a buffer-local keymap and record it so it appears in the `g?` help float.
--- `opts.group` (string) groups the key under a named section header in the help float.
--- @param mode     string
--- @param key      string
--- @param callback fun()
--- @param opts     table|nil
function Buffer:set_keymap(mode, key, callback, opts)
  opts        = opts or {}
  local group = opts.group
  opts.group  = nil
  opts.buffer = self.buf_id
  vim.keymap.set(mode, key, callback, opts)
  table.insert(self.keymaps, { mode, key, vim.tbl_extend("force", opts, { group = group }) })
end

return Buffer
