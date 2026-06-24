# belvedere.nvim

A Neovim database client. Communicates with an external server backend over newline-delimited JSON on stdio — see the [protocol spec](docs/protocol.md).

## Requirements

- Neovim 0.9+
- A server backend implementing the [belvedere protocol](docs/protocol.md)

[belvedere-py](https://github.com/theogilbert/dbelveder-py) is a reference server implementation.

## Installation

Install a server backend, then install the plugin with your plugin manager:

**lazy.nvim**
```lua
{
  "you/belvedere.nvim",
  config = function()
    require("belvedere").setup()
  end,
}
```

### Example configuration

```lua
-- plugins.lua
require("belvedere").setup({
  server_cmd = "belvedere --log -v"
})

-- keymaps.lua
local db = require("belvedere")
local dbelveder = require("belvedere")
vim.keymap.set("n", "<leader>bc", dbelveder.connect, { desc = "Data[b]ase - [c]onnect" })
vim.keymap.set("n", "<leader>bC", dbelveder.open_connections, { desc = "Data[b]ase - [c]onnections" })
vim.keymap.set("n", "<leader>ba", dbelveder.associate,        { desc = "Data[b]ase - [a]ssociate connection" })
vim.keymap.set({"n", "v"}, "<leader>be", dbelveder.execute,        { desc = "Data[b]ase - [e]xecute" })
vim.keymap.set("n", "<leader>bx", dbelveder.open_explorer, { desc = "Data[b]ase - open e[x]plorer" })
vim.keymap.set({"n", "v"}, "<leader>bs", dbelveder.save_query, { desc = "Data[b]ase - [s]ave query" })
vim.keymap.set("n", "<leader>bh", function()
  db.open_current_driver_help({ position = "bottom" })
end, { desc = "Data[b]ase [h]elp" })
```

## Setup

`setup()` is required. All options have defaults:

```lua
require("belvedere").setup({
  -- Command used to launch the server backend.
  -- Default: "belvedere" (assumes it is on $PATH).
  server_cmd = "belvedere",

  -- Override the path to the connections file.
  -- Default: $XDG_CONFIG_HOME/belvedere/connections.json
  --          (~/.config/belvedere/connections.json on most systems)
  -- connections_file = vim.fn.expand("~/.config/belvedere/connections.json"),

  keymaps = {
    -- Key in the connections panel to show the error details float.
    hover_key = "K",
  },

  -- Results window appearance.
  results = {
    split     = "below",  -- "below" | "right"
    height    = 15,
    page_size = 500,
  },
})
```

## Workflow

### 1. Manage connections

Open the connections panel with `:DbConnections`. Connections are grouped by driver and persist across sessions in `~/.config/belvedere/connections.json`.

| Key | Action |
|-----|--------|
| `<CR>` | Expand/collapse a driver group, or connect to the database under the cursor |
| `b` | Jump to the buffer associated with the connection under the cursor |
| `n` | Create a new connection (guided wizard) |
| `G` | Create a new group |
| `e` | Edit the connection under the cursor |
| `c` | Clone the connection under the cursor |
| `D` | Delete the saved connection under the cursor |
| `d` | Disconnect from the database under the cursor |
| `x` | Open the explorer for the connected database under the cursor |
| `K` | Show connection details or error in a float (press `K` again to enter it) |
| `?` | Show driver help |
| `R` | Refresh the panel |
| `q` | Close the panel |
| `g?` | Show keymap reference |

Status indicators next to each connection name:

| Symbol | Meaning |
|--------|---------|
| `✓` | Connected (green) |
| `✗` | Last connection attempt failed (red) — press `K` for details |
| `⠋…` | Connecting (animated spinner) |

### 2. Associate a buffer

Once a connection is open, associate it with the buffer you want to query:

```
:DbAssociate
```

A picker lists all currently open connections. Select one — the buffer is now linked and a "Connected to name (driver)" label appears at the bottom of the window.

### 3. Execute queries

Write SQL in the associated buffer and run:

| Command | What it executes |
|---------|-----------------|
| `:DbExecute` | Current line |
| `:'<,'>DbExecute` | Visual selection |
| `:%DbExecute` | Whole buffer |

The plugin sets no keymaps on your buffers — add your own as needed, e.g.:

```lua
vim.keymap.set("n", "<leader>e", ":DbExecute<CR>")
vim.keymap.set("x", "<leader>e", ":'<,'>DbExecute<CR>")
```


Results appear in a split window with aligned columns and a row count. For DML queries (`INSERT`, `UPDATE`, `DELETE`) the affected row count is shown instead of a table.

| Key | Action |
|-----|--------|
| `H` / `L` | Scroll left / right one column |
| `c` | Select which columns to display |
| `[` / `]` | Previous / next page |
| `q` | Close the results window |
| `g?` | Show keymap reference |

**Multiple queries:** if the SQL contains `;`, each statement is sent as a separate request and results are shown as labelled sections (`── Query 1 / 3 ──`, etc.). This does not apply to MongoDB-style drivers.

### 4. Explore the schema

Press `e` on a connected database in the connections panel, or run `:DbExplore`.

| Key | Action |
|-----|--------|
| `<CR>` | Expand / collapse a node |
| `K` | Describe the item under the cursor |
| `R` | Refresh the tree, bypassing the server-side schema cache |
| `g?` | Show keymap reference |

The window title bar shows the connection name and driver. A spinner is shown while a node's children are loading.

---

## Commands

| Command | Description |
|---------|-------------|
| `:DbConnections` | Toggle the connections panel |
| `:DbAssociate` | Associate the current buffer with an open connection |
| `:DbConnect [name]` | Connect to a saved connection by name (or open a picker) |
| `:DbNewConnection` | Open the new-connection wizard |
| `:DbDeleteConnection <name>` | Remove a saved connection |
| `:DbDisconnect [name]` | Disconnect a named connection, or the current buffer's connection |
| `:[range]DbExecute` | Execute SQL (range, selection, or current line) |
| `:DbExplore` | Open the schema explorer |
| `:DbStop` | Kill the backend process |
| `:DbRestart` | Restart the backend process (clears all state) |

---

## Connections file

Connections are stored in `~/.config/belvedere/connections.json` (XDG-compliant). The file is created automatically on first save. Passwords are not stored — you are prompted at connect time.

```json
{
  "belvedere": {
    "sqlite": {
      "label": "SQLite",
      "groups": {
        "": {
          "local-sqlite": { "database": "/home/user/data.db" }
        }
      }
    },
    "sqlserver": {
      "label": "SQL Server",
      "groups": {
        "": {
          "prod-mssql": { "host": "db.example.com", "port": 1433, "database": "myapp", "user": "readonly" }
        }
      }
    }
  }
}
```

---

## Lua API

```lua
local db = require("belvedere")

-- Configure (call once at startup).
db.setup(opts)

-- Open the connections panel.
db.open_connections()

-- Connect via picker, or directly by name.
db.connect()
db.connect("prod-mssql")

-- Associate the current buffer with an open connection (shows a picker).
db.associate()

-- Disconnect from a named connection.
db.disconnect("prod-mssql")

-- Execute: mode-aware (visual selection or current line). For Lua keymaps.
db.execute()

-- Execute lines line1..line2 from the current buffer (1-based).
db.execute_range(line1, line2)

-- Open the explorer for a specific connection by name.
db.open_explorer_for("prod-mssql")

-- Kill the backend process and clear all state.
db.stop()

-- Restart the backend process (stop + start, clears all state).
db.restart()
```

```lua
local conns = require("belvedere.connections")

-- Load the full connections file: returns { server -> { driver -> { label, groups -> { group -> { name -> params } } } } }
conns.load_all()

-- Load connections for a specific server name.
conns.load("belvedere")

-- Delete a connection by its internal key.
conns.delete(key)

-- Open the new-connection wizard (caps from ensure_backend_with_caps).
conns.create(caps, function(key, params) ... end)
```
