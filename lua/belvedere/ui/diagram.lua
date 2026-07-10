-- ASCII schema diagram viewer, opened in a new tab.
local M = {}

local client = require("belvedere.client")
local hl     = require("belvedere.hl")

local NS_ID = vim.api.nvim_create_namespace("BelvedereDiagram")

-- Box-drawing and tree-connector characters used to frame table boxes and join lines.
-- Matched as a set of UTF-8 byte sequences since Lua patterns are byte-oriented.
local BORDER_PATTERN = "[┌┐└┘─│├┬┴┼→]+"

--- Dim the box-drawing/connector characters in `lines` so they recede behind the
--- table and column names highlighted via `apply_regions`.
--- @param buf   integer
--- @param lines string[]
local function apply_border_highlight(buf, lines)
  for row, line in ipairs(lines) do
    for s, e in line:gmatch("()" .. BORDER_PATTERN .. "()") do
      vim.api.nvim_buf_add_highlight(buf, NS_ID, "BelvedereBorder", row - 1, s - 1, e - 1)
    end
  end
end

--- Highlight group for a DiagramRegion, based on the shape of its `path`.
--- A column path ends in `.columns.<name>`; anything else names a table/view.
--- @param path string[]
--- @return string
local function region_hl_group(path)
  if #path >= 2 and path[#path - 1] == "columns" then
    return "BelvedereExplorerColumn"
  end
  return "BelvedereExplorerTable"
end

--- Apply highlight groups to `buf` for each region in `regions`.
--- @param buf     integer
--- @param regions table[]  DiagramRegion objects: { row, col_start, col_end, path }
local function apply_regions(buf, regions)
  for _, region in ipairs(regions) do
    vim.api.nvim_buf_add_highlight(
      buf, NS_ID, region_hl_group(region.path), region.row, region.col_start, region.col_end)
  end
end

--- Request an ASCII diagram for the table at `path` and display it in a new tab.
--- @param conn_id any
--- @param path    string[]
--- @param title   string  table name, used in the buffer name
function M.open(conn_id, path, title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  Loading…" })
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "belvedere://diagram/" .. title)

  vim.cmd("tabnew")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function() pcall(vim.cmd, "tabclose") end,
      { buffer = buf, silent = true, nowait = true })
  end

  client.request("explore.diagram", { connection_id = conn_id, path = path }, function(err, result)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      local lines = err and { "  " .. err } or vim.split(result and result.diagram or "", "\n")
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      if not err then
        apply_border_highlight(buf, lines)
        if result and result.regions then
          apply_regions(buf, result.regions)
        end
      end
    end)
  end)
end

return M
