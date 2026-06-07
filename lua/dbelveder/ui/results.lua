-- Renders query results in a dedicated split buffer.
local M = {}

local config = require("dbelveder.config")

local BUFNAME = "dbelveder://results"

local function get_or_create_buf()
  local existing = vim.fn.bufnr(BUFNAME)
  if existing ~= -1 then return existing end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, BUFNAME)
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].swapfile   = false
  vim.bo[buf].filetype   = "dbelveder_results"
  return buf
end

local function open_win(buf)
  local opts = config.options.results
  local existing = vim.fn.bufwinid(buf)
  if existing ~= -1 then
    vim.api.nvim_set_current_win(existing)
    return existing
  end
  local cmd = opts.split == "right" and "vsplit" or "split"
  vim.cmd(cmd)
  vim.api.nvim_win_set_buf(0, buf)
  if opts.split ~= "right" then
    vim.api.nvim_win_set_height(0, opts.height)
  end
  return vim.api.nvim_get_current_win()
end

-- Right-pad a string to width w.
local function pad(s, w)
  s = tostring(s or "")
  return s .. string.rep(" ", math.max(0, w - #s))
end

local function render_table(buf, columns, rows)
  local widths = {}
  for i, c in ipairs(columns) do
    widths[i] = #tostring(c)
  end
  for _, row in ipairs(rows) do
    for i, v in ipairs(row) do
      widths[i] = math.max(widths[i] or 0, #tostring(v or ""))
    end
  end

  local lines = {}
  -- header
  local header_parts = {}
  for i, c in ipairs(columns) do header_parts[i] = pad(c, widths[i]) end
  lines[#lines + 1] = table.concat(header_parts, "  ")
  -- separator
  local sep_parts = {}
  for i, w in ipairs(widths) do sep_parts[i] = string.rep("-", w) end
  lines[#lines + 1] = table.concat(sep_parts, "  ")
  -- rows
  local max_rows = config.options.results.max_rows
  for idx, row in ipairs(rows) do
    if idx > max_rows then
      lines[#lines + 1] = ("... (%d rows truncated)"):format(#rows - max_rows)
      break
    end
    local parts = {}
    for i, v in ipairs(row) do parts[i] = pad(v, widths[i]) end
    lines[#lines + 1] = table.concat(parts, "  ")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("%d row(s)"):format(math.min(#rows, max_rows))

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M.show_results(columns, rows)
  local buf = get_or_create_buf()
  open_win(buf)
  render_table(buf, columns, rows)
end

function M.show_error(msg)
  local buf = get_or_create_buf()
  open_win(buf)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Error: " .. msg })
  vim.bo[buf].modifiable = false
end

function M.show_message(msg)
  local buf = get_or_create_buf()
  open_win(buf)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { msg })
  vim.bo[buf].modifiable = false
end

return M
