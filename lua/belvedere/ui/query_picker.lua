local M = {}

local queries = require("belvedere.queries")

local SEP     = "\t"
local KEY_SEP = "\1"   -- SOH: won't appear in scope keys or query names

local function make_entry(e)
  local first_line = (e.content:match("^[^\n]*") or ""):gsub("\t", "  ")
  if #first_line > 100 then first_line = first_line:sub(1, 100) .. "…" end
  local label  = "[" .. queries.scope_label(e.scope_key) .. "]"
  local hidden = e.scope_key .. KEY_SEP .. e.name
  return label .. " " .. e.name .. SEP .. first_line .. SEP .. (e.path or "") .. SEP .. hidden
end

local function decode_entry(s)
  local parts  = vim.split(s, SEP, { plain = true })
  local hidden = parts[#parts]
  local sep    = hidden:find(KEY_SEP, 1, true)
  if not sep then return nil, nil end
  return hidden:sub(1, sep - 1), hidden:sub(sep + 1)
end

local function find_buf_by_name(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
  return -1
end

local function open_query_buffer(scope_key, name, data_by_key, conn_key)
  local e = data_by_key[scope_key .. KEY_SEP .. name]
  if not e then return end

  local bufname = "belvedere://queries/" .. scope_key .. "/" .. name
  local bufnr   = find_buf_by_name(bufname)

  if bufnr == -1 then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, bufname)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(e.content, "\n", { plain = true }))
    vim.bo[bufnr].modifiable = false
    local ft = e.ext ~= "" and (vim.filetype.match({ filename = "q." .. e.ext }) or e.ext) or "sql"
    vim.bo[bufnr].filetype   = ft
    vim.bo[bufnr].bufhidden  = "hide"
    pcall(vim.treesitter.start, bufnr)
  end

  if conn_key then require("belvedere").set_buf_conn(bufnr, conn_key) end

  -- Reuse an existing window already showing this buffer.
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins > 0 then vim.api.nvim_set_current_win(wins[1]); return end

  -- Otherwise find a normal editing window.
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "" then
      vim.api.nvim_set_current_win(w)
      vim.api.nvim_set_current_buf(bufnr)
      return
    end
  end
  vim.cmd("leftabove vsplit")
  vim.api.nvim_set_current_buf(bufnr)
end

local function show_picker(entries_data, conn_key)
  if #entries_data == 0 then
    vim.notify("belvedere: no saved queries", vim.log.levels.INFO)
    return
  end

  local data_by_key   = {}
  local entry_strings = {}

  for _, e in ipairs(entries_data) do
    data_by_key[e.scope_key .. KEY_SEP .. e.name] = e
    table.insert(entry_strings, make_entry(e))
  end

  local preview_cmd = vim.fn.executable("bat") == 1
    and "bat --style=plain --color=always {3}"
    or  "cat {3}"

  local ok, fzf = pcall(require, "fzf-lua")
  if ok then
    fzf.fzf_exec(entry_strings, {
      prompt    = "Saved queries> ",
      previewer = false,
      fzf_opts  = {
        ["--delimiter"] = "\t",
        ["--with-nth"]  = "1",
        ["--nth"]       = "1,2",
        ["--preview"]   = preview_cmd,
        ["--header"]    = "CTRL-D: delete",
      },
      actions = {
        ["default"] = function(selected)
          if not selected or not selected[1] then return end
          local sk, name = decode_entry(selected[1])
          if not sk then return end
          vim.schedule(function() open_query_buffer(sk, name, data_by_key, conn_key) end)
        end,
        ["ctrl-d"] = function(selected)
          if not selected or not selected[1] then return end
          local sk, name = decode_entry(selected[1])
          if not sk then return end
          vim.schedule(function()
            vim.ui.select({ "No", "Yes" }, {
              prompt = ('Delete query %q?'):format(name),
            }, function(choice)
              if choice == "Yes" then
                queries.delete(sk, name)
                vim.notify(('belvedere: deleted "%s"'):format(name), vim.log.levels.INFO)
              end
            end)
          end)
        end,
      },
    })
    return
  end

  -- Fallback: vim.ui.select (no preview).
  local labels = vim.tbl_map(function(e)
    return "[" .. queries.scope_label(e.scope_key) .. "] " .. e.name
  end, entries_data)

  vim.ui.select(labels, { prompt = "Saved queries:" }, function(_, idx)
    if not idx then return end
    local e = entries_data[idx]
    vim.schedule(function() open_query_buffer(e.scope_key, e.name, data_by_key, conn_key) end)
  end)
end

-- Open the picker for all queries visible to a connection (conn + group + driver).
function M.open(conn_key)
  show_picker(queries.list_for_conn(conn_key), conn_key)
end

-- Open the picker for a group entry: shows group-level and driver-level queries.
-- conn_key is nil here; the opened buffer won't be auto-associated.
function M.open_for_group(server, driver_id, group)
  local g          = group ~= "" and group or "_"
  local group_sk   = "group/"  .. server .. "/" .. driver_id .. "/" .. g
  local driver_sk  = "driver/" .. server .. "/" .. driver_id

  local seen, entries_data = {}, {}
  for _, sk in ipairs({ group_sk, driver_sk }) do
    for name, q in pairs(queries.list(sk)) do
      if not seen[name] then
        seen[name] = true
        table.insert(entries_data, { scope_key = sk, name = name, content = q.content, created_at = q.created_at, ext = q.ext, path = q.path })
      end
    end
  end
  show_picker(entries_data, nil)
end

return M
