# dbelveder.nvim

A Neovim database client. Connects to SQLite and SQL Server through an external Python backend ([dbelveder-py](../dbelveder-py)), communicating over newline-delimited JSON on stdio.

## Requirements

- Neovim 0.9+
- Python 3.12+ with [dbelveder-py](../dbelveder-py) installed

## Installation

Install **dbelveder-py** first:

```sh
pip install dbelveder-py
# or with driver-specific dependencies:
pip install 'dbelveder-py[sqlserver]'
```

Then install the plugin with your plugin manager:

**lazy.nvim**
```lua
{
  "you/dbelveder.nvim",
  config = function()
    require("dbelveder").setup()
  end,
}
```

## Setup

`setup()` is required. All options have defaults:

```lua
require("dbelveder").setup({
  -- Command used to launch the Python backend.
  -- Default: "dbelveder" (assumes it is on $PATH).
  python_cmd = "dbelveder",

  -- Override the path to the connections file.
  -- Default: $XDG_CONFIG_HOME/dbelveder/connections.json
  --          (~/.config/dbelveder/connections.json on most systems)
  -- connections_file = vim.fn.expand("~/.config/dbelveder/connections.json"),

  keymaps = {
    -- Key in the connections panel to show the error details float.
    hover_key = "K",
  },

  -- Results window appearance.
  results = {
    split    = "below",  -- "below" | "right"
    height   = 15,
    max_rows = 500,
  },
})
```

## Workflow

### 1. Manage connections

Open the connections panel with `:DbConnections`. Connections are grouped by driver and persist across sessions in `~/.config/dbelveder/connections.json`.

| Key | Action |
|-----|--------|
| `<CR>` | Expand/collapse a driver group, or connect to the database under the cursor |
| `n` | Create a new connection (guided wizard) |
| `e` | Edit the connection under the cursor |
| `c` | Clone the connection under the cursor |
| `d` | Disconnect from the database under the cursor |
| `r` | Remove the saved connection under the cursor |
| `x` | Open the explorer for the connected database under the cursor |
| `K` | Show the connection error message in a float (press `K` again to enter it) |
| `R` | Refresh the panel |
| `q` | Close the panel |

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

**Multiple queries:** if the SQL contains `;`, each statement is sent as a separate request and results are shown as labelled sections (`── Query 1 / 3 ──`, etc.). This does not apply to MongoDB-style drivers.

### 4. Explore the schema

Press `e` on a connected database in the connections panel, or run `:DbExplore`.

| Key | Action |
|-----|--------|
| `<CR>` | Expand / collapse a node; describe a leaf |
| `R` | Refresh the tree, bypassing the server-side schema cache |

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
| `:DbStop` | Kill the Python backend process |
| `:DbRestart` | Restart the Python backend process (clears all state) |

---

## Connections file

Connections are stored in `~/.config/dbelveder/connections.json` (XDG-compliant). The file is created automatically on first save. Passwords are not stored — you are prompted at connect time.

```json
{
  "connections": {
    "local-sqlite": {
      "driver": "sqlite",
      "database": "/home/user/data.db"
    },
    "prod-mssql": {
      "driver": "sqlserver",
      "host": "db.example.com",
      "port": 1433,
      "database": "myapp",
      "user": "readonly"
    }
  }
}
```

---

## Lua API

```lua
local db = require("dbelveder")

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
local conns = require("dbelveder.connections")

-- Load all saved connections: returns { name = params, ... }
conns.load()

-- Get a single connection by name.
conns.get("prod-mssql")

-- Delete a connection.
conns.delete("old-db")

-- Open the new-connection wizard (caps from ensure_backend_with_caps).
conns.create(caps, function(name, params) ... end)
```
