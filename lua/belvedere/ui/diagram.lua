-- ASCII schema diagram viewer, opened in a new tab.
local M = {}

local client = require("belvedere.client")

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
  vim.api.nvim_win_set_buf(0, buf)

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
    end)
  end)
end

return M
