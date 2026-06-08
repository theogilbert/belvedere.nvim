# dbelveder.nvim

A Neovim database client. Connects to SQLite, PostgreSQL, SQL Server, and MongoDB through an external Python backend ([dbelveder-py](../dbelveder-py)), communicating over newline-delimited JSON on stdio.

## Requirements

- Neovim 0.9+
- Python 3.12+ with [dbelveder-py](../dbelveder-py) installed

## Installation

Install **dbelveder-py** first:

```sh
pip install dbelveder-py
# or, for specific databases:
pip install 'dbelveder-py[postgres]'
pip install 'dbelveder-py[sqlserver]'
pip install 'dbelveder-py[mongodb]'
pip install 'dbelveder-py[all]'
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

**packer.nvim**
```lua
use {
  "you/dbelveder.nvim",
  config = function()
    require("dbelveder").setup()
  end,
}
```

## Setup

`setup()` is required but takes no mandatory options:

```lua
require("dbelveder").setup({
  -- Command used to launch the Python backend.
  -- Default: "dbelveder" (assumes it is on $PATH).
  python_cmd = "dbelveder",

  -- Override the path to the connections file.
  -- Default: $XDG_CONFIG_HOME/dbelveder/connections.json
  --          (~/.config/dbelveder/connections.json on most systems)
  -- connections_file = vim.fn.expand("~/.config/dbelveder/connections.json"),

  -- Results window appearance.
  results = {
    split    = "below",  -- "below" | "right"
    height   = 15,
    max_rows = 500,
  },
})
```

## Connections

Connections are stored in `~/.config/dbelveder/connections.json` (XDG-compliant, not inside the nvim config). The file is created automatically when you save your first connection.

```json
{
  "connections": {
    "local-sqlite": {
      "driver": "sqlite",
      "database": "/home/user/data.db"
    },
    "prod": {
      "driver": "postgres",
      "host": "db.example.com",
      "port": 5432,
      "database": "myapp",
      "user": "readonly",
      "password": "secret"
    }
  }
}
```

You can edit the file directly, or use the built-in commands.

## Commands

| Command | Description |
|---|---|
| `:DbConnect` | Open a picker to select or create a connection |
| `:DbConnect <name>` | Connect directly by name (tab-completion available) |
| `:DbNewConnection` | Jump straight to the new-connection wizard |
| `:DbDeleteConnection <name>` | Remove a saved connection (tab-completion available) |
| `:DbDisconnect` | Close the current connection |
| `:[range]DbExecute` | Execute a SQL statement (range or current line) |
| `:DbExplore` | Open the database explorer sidebar |
| `:DbStop` | Kill the Python backend process |

### Creating a connection

Run `:DbConnect` (or `:DbNewConnection`) and follow the prompts:

1. Enter a name for the connection
2. Select the driver from a list
3. Fill in the driver-specific fields (host, port, database, user, password)

The connection is saved to the JSON file immediately and can be reused across sessions.

### Connecting

- `:DbConnect` — opens a picker showing all saved connections plus a **[+ New connection]** entry
- `:DbConnect prod` — connects directly without the picker; supports tab-completion

### Executing queries

Write SQL in any buffer, then execute it:

- `:DbExecute` — executes the current line
- `:'<,'>DbExecute` — executes the visual selection
- `:%DbExecute` — executes the whole buffer

Results appear in a split window. Columns are aligned and a row count is shown at the bottom.

### Explorer

`:DbExplore` opens a sidebar showing the database object tree.

| Key | Action |
|---|---|
| `<CR>` | Expand / collapse a node |
| `<CR>` on a leaf | Show metadata for that object |
| `R` | Refresh the tree from the server |

## Lua API

```lua
local db = require("dbelveder")

-- Configure (call once at startup).
db.setup(opts)

-- Open the connection picker.
db.connect()

-- Connect directly by name (looks up the connections file).
db.connect_by_name("prod")

-- Disconnect from the current connection.
db.disconnect()

-- Execute a SQL string.
db.execute("SELECT 1")

-- Execute lines line1..line2 from the current buffer (1-based).
db.execute_range(line1, line2)

-- Execute the last visual selection (charwise-aware).
-- Notifies at INFO level if no selection exists.
db.execute_selection()

-- Open the explorer sidebar.
db.open_explorer()

-- Kill the backend process.
db.stop()
```

```lua
local conns = require("dbelveder.connections")

-- Load all saved connections: returns { name = params, ... }
conns.load()

-- Get a single connection by name.
conns.get("prod")

-- Save a connection programmatically.
local all = conns.load()
all["ci"] = { driver = "postgres", host = "ci-db", database = "test", user = "ci", password = "" }
conns.save(all)

-- Delete a connection.
conns.delete("old-db")

-- Open the picker (used internally by :DbConnect).
conns.pick(function(name, params) ... end)

-- Run the new-connection wizard (used internally by :DbNewConnection).
conns.create(function(name, params) ... end)
```

## Supported databases

| Driver value | Database | Extra Python package |
|---|---|---|
| `"sqlite"` | SQLite | _(none, stdlib)_ |
| `"postgres"` / `"postgresql"` | PostgreSQL | `psycopg[binary]>=3` |
| `"sqlserver"` / `"mssql"` | SQL Server | `mssql-python>=1.8` |
| `"mongodb"` / `"mongo"` | MongoDB | `pymongo>=4` |

## Tree hierarchies

**SQLite**
```
(root)
└── <table|view>
    ├── columns
    │   └── <column>  [type]
    └── indices
        └── <index>
```

**PostgreSQL / SQL Server**
```
(root)
└── <schema>
    └── <table|view>
        ├── columns
        │   └── <column>  [type]
        ├── indices
        └── constraints
```

**MongoDB**
```
(root)
└── <database>
    └── <collection>
        └── <field>  [python-type]
```
