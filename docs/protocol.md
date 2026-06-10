# dbelveder protocol

Communication between **dbelveder.nvim** (client) and **dbelveder-py** (server) uses newline-delimited JSON over stdio. The client spawns the server as a child process and communicates through its stdin/stdout pipes.

Multiple connections can be open simultaneously. Each `connect` call returns a `connection_id` that must be passed to all subsequent methods operating on that connection.

## Wire format

Each message is a single JSON object serialized on one line, terminated by `\n`. There is no envelope, framing header, or length prefix — a line boundary is a message boundary.

```
{"id":1,"method":"connect","params":{"driver":"sqlite","database":"/tmp/test.db"}}\n
{"id":1,"result":{"connection_id":"abc123"},"error":null}\n
```

## Message structure

### Request (client → server)

| Field    | Type            | Description                          |
|----------|-----------------|--------------------------------------|
| `id`     | integer         | Caller-chosen ID, echoed in response |
| `method` | string          | Method name (see below)              |
| `params` | object          | Method-specific parameters           |

### Response (server → client)

| Field    | Type            | Description                                  |
|----------|-----------------|----------------------------------------------|
| `id`     | integer or null | Matches the request `id`                     |
| `result` | any or null     | Return value on success; null on error       |
| `error`  | string or null  | Error message on failure; null on success    |

Requests are handled concurrently. Responses may arrive out of order — clients must correlate them by `id`.

---

## Progress notifications

Long-running methods may send one or more progress messages before the final response. A progress message carries a `progress` object and shares the same `id` as the originating request. The pending request stays open until the final `result`/`error` message arrives.

### Progress message (server → client)

| Field      | Type    | Description                             |
|------------|---------|-----------------------------------------|
| `id`       | integer | Matches the originating request `id`    |
| `progress` | object  | Status update (see below)               |

### Progress object

| Field     | Type   | Description                                                             |
|-----------|--------|-------------------------------------------------------------------------|
| `status`  | string | Machine-readable key (e.g. `"reconnecting"`, `"executing"`)            |
| `message` | string | Human-readable description                                              |

### Example

```
client → {"id":2,"method":"execute","params":{"connection_id":"abc123","sql":"SELECT ..."}}
server → {"id":2,"progress":{"status":"reconnecting","message":"Connection lost, reconnecting…"}}
server → {"id":2,"progress":{"status":"executing","message":"Executing query…"}}
server → {"id":2,"result":{"columns":[…],"rows":[…]},"error":null}
```

Methods that currently support progress: `execute`.

---

## Methods

### `capabilities`

Returns the server's name and the full list of databases it supports, including the connection parameters each database accepts. Clients should call this once after starting the server and use the result to drive connection wizards instead of hard-coding driver lists.

**params** — none (`{}`)

**result**

| Field          | Type                        | Description                        |
|----------------|-----------------------------|------------------------------------|
| `server`       | string                      | Human-readable server name (e.g. `"dbelveder"`) |
| `databases` | array of [Database](#database) | Supported drivers/databases |

**example**

```json
{"id":1,"method":"capabilities","params":{}}
```
```json
{
  "id": 1,
  "result": {
    "server": "dbelveder",
    "databases": [
      {
        "driver": "sqlite",
        "params": [
          {"key": "database", "type": "string", "label": "Database file path", "required": true}
        ]
      },
      {
        "driver": "sqlserver",
        "params": [
          {"key": "host",              "type": "string",  "label": "Host",               "default": "localhost"},
          {"key": "port",              "type": "integer", "label": "Port",               "default": 1433},
          {"key": "database",          "type": "string",  "label": "Database"},
          {"key": "user",              "type": "string",  "label": "User"},
          {"key": "applicationIntent", "type": "enum",    "label": "Application Intent", "choices": ["READ_WRITE", "READ_ONLY"]},
          {"key": "password",          "type": "string",  "label": "Password",           "secret": true}
        ]
      }
    ]
  },
  "error": null
}
```

---

### `connect`

Opens a new database connection. Multiple connections can be open at the same time.

**params**

| Field    | Type   | Description                      |
|----------|--------|----------------------------------|
| `driver` | string | See [Drivers](#drivers)          |
| …        | …      | Driver-specific fields (see below) |

**result**

| Field           | Type            | Description                              |
|-----------------|-----------------|------------------------------------------|
| `connection_id` | string or integer | Opaque handle to pass to other methods |

```json
{"connection_id": "abc123"}
```

---

### `disconnect`

Closes the specified connection.

**params**

| Field           | Type            | Description                        |
|-----------------|-----------------|------------------------------------|
| `connection_id` | string or integer | Connection to close               |

**result**

```json
{"ok": true}
```

---

### `execute`

Runs a SQL statement and returns the result set.

**params**

| Field           | Type             | Description                        |
|-----------------|------------------|------------------------------------|
| `connection_id` | string or integer| Connection to execute on           |
| `sql`           | string           | SQL statement to execute           |
| `params`        | array (optional) | Positional bind parameters         |

**result — SELECT**

| Field     | Type              | Description                       |
|-----------|-------------------|-----------------------------------|
| `columns` | array of strings  | Column names, in order            |
| `rows`    | array of arrays   | Each row is an array of values    |

**result — INSERT / UPDATE / DELETE (and other DML)**

| Field           | Type    | Description                             |
|-----------------|---------|-----------------------------------------|
| `rows_affected` | integer | Number of rows inserted/updated/deleted |

**examples**

```json
{"id":2,"method":"execute","params":{"connection_id":"abc123","sql":"SELECT id, name FROM users WHERE active = ?","params":[1]}}
{"id":2,"result":{"columns":["id","name"],"rows":[[1,"Alice"],[2,"Bob"]]},"error":null}
```

```json
{"id":3,"method":"execute","params":{"connection_id":"abc123","sql":"DELETE FROM users WHERE active = 0"}}
{"id":3,"result":{"rows_affected":4},"error":null}
```

---

### `explore.list`

Returns the children of a node in the database object tree. The tree is navigated by a `path` — an ordered list of node names from the root.

**params**

| Field           | Type             | Description                                    |
|-----------------|------------------|------------------------------------------------|
| `connection_id` | string or integer| Connection to explore                          |
| `path`          | array of strings | Path to the node whose children are requested  |
| `reset_cache`   | boolean (optional, default `false`) | Clear all cached explore data for this connection before fetching |

**result**

| Field   | Type              | Description             |
|---------|-------------------|-------------------------|
| `items` | array of [ExploreItem](#exploreitem) | Child nodes |

**example**

```json
{"id":3,"method":"explore.list","params":{"connection_id":"abc123","path":[]}}
```
```json
{"id":3,"result":{"items":[{"name":"public","type":"schema","expandable":true}]},"error":null}
```

---

### `explore.describe`

Returns detailed metadata about a specific node.

**params**

| Field           | Type             | Description            |
|-----------------|------------------|------------------------|
| `connection_id` | string or integer| Connection to query    |
| `path`          | array of strings | Path to the node       |
| `reset_cache`   | boolean (optional, default `false`) | Clear all cached explore data for this connection before fetching |

**result**

| Field     | Type   | Description                    |
|-----------|--------|--------------------------------|
| `details` | object | Driver-specific metadata object (see [Tree hierarchies](#tree-hierarchies)) |

---

## Database

Each entry in the `capabilities.databases` array:

| Field    | Type                              | Description                                     |
|----------|-----------------------------------|-------------------------------------------------|
| `driver` | string                            | Driver identifier; passed as `driver` in `connect.params` |
| `params` | array of [DatabaseParam](#databaseparam) | Connection parameters, in display order |

## DatabaseParam

| Field      | Type    | Required | Description                                                        |
|------------|---------|----------|--------------------------------------------------------------------|
| `key`      | string  | yes      | Parameter key sent in `connect.params`                             |
| `type`     | string  | yes      | `"string"`, `"integer"`, or `"enum"`                               |
| `label`    | string  | yes      | Human-readable label for UI display                                |
| `required` | boolean | no       | Whether a non-empty value is required (default `false`)            |
| `default`  | string or integer | no | Default value pre-filled in the UI                       |
| `choices`  | array of strings | for `"enum"` | Allowed values                                    |
| `secret`   | boolean | no       | Mask input in the UI (e.g. for passwords); never persisted to disk |

---

## ExploreItem

Each item returned by `explore.list` has this shape:

| Field        | Type    | Description                                      |
|--------------|---------|--------------------------------------------------|
| `name`       | string  | Display name of the node                         |
| `type`       | string  | Node kind (e.g. `"schema"`, `"table"`, `"index"`) |
| `expandable` | boolean | Whether the node has children                    |

---

## Drivers

The `driver` field in `connect.params` selects the backend. Connection parameters accepted by each driver are announced at runtime via [`capabilities`](#capabilities) — the tables below document tree structure only.

### `sqlite`

**Tree hierarchy**

| Path                         | Items returned                              |
|------------------------------|---------------------------------------------|
| `[]`                         | Tables and views (`type`: `"table"`, `"view"`) |
| `[table]`                    | Groups: `columns`, `indices`, `foreign_keys` |
| `[table, "columns"]`         | Column names and types                      |
| `[table, "indices"]`         | Index names                                 |
| `[table, "foreign_keys"]`    | Foreign key references                      |

`explore.describe(["<table>"])` returns:

```json
{
  "details": {
    "table": "users",
    "columns": [
      {"name": "id",   "type": "INTEGER", "notnull": true,  "pk": true},
      {"name": "name", "type": "TEXT",    "notnull": false, "pk": false}
    ]
  }
}
```

---

### `sqlserver` / `mssql`

Requires: `pip install mssql-python`

**Tree hierarchy**

| Path                                        | Items returned                              |
|---------------------------------------------|---------------------------------------------|
| `[]`                                        | Schemas (`type`: `"schema"`)                |
| `[schema]`                                  | Tables and views                            |
| `[schema, table]`                           | Groups: `columns`, `indices`, `constraints` |
| `[schema, table, "columns"]`                | Column names and types                      |
| `[schema, table, "indices"]`                | Index names                                 |
| `[schema, table, "constraints"]`            | Constraint names                            |

