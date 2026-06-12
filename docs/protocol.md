# dbelveder protocol

Communication between **dbelveder.nvim** (client) and **dbelveder-py** (server) uses newline-delimited JSON over stdio. The client spawns the server as a child process and communicates through its stdin/stdout pipes.

Multiple connections can be open simultaneously. Each `connect` call returns a `connection_id` that must be passed to all subsequent methods operating on that connection.

## Wire format

Each message is a single JSON object serialized on one line, terminated by `\n`. There is no envelope, framing header, or length prefix — a line boundary is a message boundary.

```
{"id":1,"method":"connect","params":{"driver":"sqlite","database":"/tmp/test.db"}}\n
{"id":1,"result":{"connection_id":"0"},"error":null}\n
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
client → {"id":2,"method":"execute","params":{"connection_id":"0","sql":"SELECT ..."}}
server → {"id":2,"progress":{"status":"reconnecting","message":"Connection lost, reconnecting…"}}
server → {"id":2,"progress":{"status":"executing","message":"Retrying query…"}}
server → {"id":2,"result":{"columns":[…],"rows":[…]},"error":null}
```

Methods that currently support progress: `execute`.

---

## Methods

### `capabilities`

Returns the server's name and the full list of drivers it supports, including the connection parameters each driver accepts. Clients should call this once after starting the server and use the result to drive connection wizards instead of hard-coding driver lists.

Only drivers whose Python package is installed appear in the response.

**params** — none (`{}`)

**result**

| Field     | Type                       | Description                                     |
|-----------|----------------------------|-------------------------------------------------|
| `server`  | string                     | Human-readable server name (e.g. `"dbelveder"`) |
| `drivers` | array of [Driver](#driver) | Supported drivers                               |

**example**

```json
{"id":1,"method":"capabilities","params":{}}
```
```json
{
  "id": 1,
  "result": {
    "server": "dbelveder",
    "drivers": [
      {
        "driver": "sqlite",
        "label": "SQLite",
        "params": [
          {"key": "database", "type": "string", "label": "Database file path", "required": true}
        ]
      },
      {
        "driver": "sqlserver",
        "label": "SQL Server",
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

| Field          | Type             | Description                                                           |
|----------------|------------------|-----------------------------------------------------------------------|
| `driver`       | string           | See [Drivers](#drivers)                                               |
| `idle_timeout` | number (optional)| Seconds of inactivity before the server auto-closes the connection (default: `600`) |
| …              | …                | Driver-specific fields (see below)                                    |

**result**

| Field           | Type   | Description                              |
|-----------------|--------|------------------------------------------|
| `connection_id` | string | Opaque handle to pass to other methods   |

```json
{"connection_id": "0"}
```

---

### `disconnect`

Closes the specified connection.

**params**

| Field           | Type   | Description                        |
|-----------------|--------|------------------------------------|
| `connection_id` | string | Connection to close                |

**result**

```json
{"ok": true}
```

---

### `execute`

Runs a query and returns the result set.

The query language and bind parameter syntax depend on the driver — see [Drivers](#drivers).

**params**

| Field           | Type             | Description                        |
|-----------------|------------------|------------------------------------|
| `connection_id` | string           | Connection to execute on           |
| `sql`           | string           | Query to execute                   |
| `params`        | array (optional) | Positional bind parameters         |

**result — SELECT / RETURN**

| Field     | Type              | Description                       |
|-----------|-------------------|-----------------------------------|
| `columns` | array of strings  | Column names, in order            |
| `rows`    | array of arrays   | Each row is an array of values    |

**result — INSERT / UPDATE / DELETE / write statements**

| Field           | Type    | Description                             |
|-----------------|---------|-----------------------------------------|
| `rows_affected` | integer | Number of rows/nodes/relationships affected |

**examples**

```json
{"id":2,"method":"execute","params":{"connection_id":"0","sql":"SELECT id, name FROM users WHERE active = ?","params":[1]}}
{"id":2,"result":{"columns":["id","name"],"rows":[[1,"Alice"],[2,"Bob"]]},"error":null}
```

```json
{"id":3,"method":"execute","params":{"connection_id":"0","sql":"DELETE FROM users WHERE active = 0"}}
{"id":3,"result":{"rows_affected":4},"error":null}
```

---

### `explore.list`

Returns the children of a node in the database object tree. The tree is navigated by a `path` — an ordered list of node names from the root.

**params**

| Field           | Type             | Description                                    |
|-----------------|------------------|------------------------------------------------|
| `connection_id` | string           | Connection to explore                          |
| `path`          | array of strings | Path to the node whose children are requested  |
| `reset_cache`   | boolean (optional, default `false`) | Clear all cached explore data for this connection before fetching |

**result**

| Field   | Type              | Description             |
|---------|-------------------|-------------------------|
| `items` | array of [ExploreItem](#exploreitem) | Child nodes |

**example**

```json
{"id":3,"method":"explore.list","params":{"connection_id":"0","path":[]}}
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
| `connection_id` | string           | Connection to query    |
| `path`          | array of strings | Path to the node       |
| `reset_cache`   | boolean (optional, default `false`) | Clear all cached explore data for this connection before fetching |

**result**

| Field     | Type                | Description                    |
|-----------|---------------------|--------------------------------|
| `details` | object or null      | Driver-specific metadata object (see [Tree hierarchies](#tree-hierarchies)), or null if the path does not resolve to a describable node |

---

## Driver

Each entry in the `capabilities.drivers` array:

| Field    | Type                              | Description                                     |
|----------|-----------------------------------|-------------------------------------------------|
| `driver` | string                            | Driver identifier; passed as `driver` in `connect.params` |
| `label`  | string                            | Human-readable display name (e.g. `"SQLite"`, `"SQL Server"`) |
| `params` | array of [DriverParam](#driverparam) | Connection parameters, in display order |

## DriverParam

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
| `type`       | string  | Node kind (e.g. `"schema"`, `"table"`, `"group"`, `"index"`) |
| `expandable` | boolean | Whether the node has children                    |

The `"group"` type is used for intermediate organisational nodes that bundle sub-categories (e.g. `columns`, `indices`, `constraints`). These nodes are not database objects themselves.

---

## ColumnInfo

Column metadata object returned inside `explore.describe` results:

| Field      | Type             | Description                                       |
|------------|------------------|---------------------------------------------------|
| `name`     | string           | Column name                                       |
| `type`     | string           | Data type as reported by the database             |
| `nullable` | boolean or null  | Whether the column allows NULL; null if unknown   |
| `pk`       | boolean          | Whether the column is part of the primary key     |
| `default`  | string or null   | Default expression, or null if not set            |

---

## TableDescription

Returned as `details` by `explore.describe` for table/view nodes:

| Field     | Type                    | Description                                              |
|-----------|-------------------------|----------------------------------------------------------|
| `table`   | string                  | Table name                                               |
| `schema`  | string or null          | Schema name, or null for databases without schema support |
| `columns` | array of [ColumnInfo](#columninfo) | Ordered column metadata                     |

---

## Drivers

The `driver` field in `connect.params` selects the backend. Connection parameters accepted by each driver are announced at runtime via [`capabilities`](#capabilities) — the tables below document query language, bind syntax, and tree structure.

### `sqlite`

**Query language:** SQL — bind parameters use `?` placeholders.

**Tree hierarchy**

| Path                         | Items returned                              |
|------------------------------|---------------------------------------------|
| `[]`                         | Tables and views (`type`: `"table"`, `"view"`) |
| `[table]`                    | Groups: `columns`, `indices`, `foreign_keys` (`type`: `"group"`) |
| `[table, "columns"]`         | Column names and types                      |
| `[table, "indices"]`         | Index names (`type`: `"index"`)             |
| `[table, "foreign_keys"]`    | Foreign key references (`type`: `"foreign_key"`) |

`explore.describe(["<table>"])` returns a [TableDescription](#tabledescription):

```json
{
  "details": {
    "table": "users",
    "schema": null,
    "columns": [
      {"name": "id",   "type": "INTEGER", "nullable": false, "pk": true,  "default": null},
      {"name": "name", "type": "TEXT",    "nullable": true,  "pk": false, "default": null}
    ]
  }
}
```

---

### `sqlserver` / `mssql`

Requires: `pip install mssql-python`

**Query language:** T-SQL — bind parameters use `?` placeholders.

**Tree hierarchy**

| Path                                        | Items returned                              |
|---------------------------------------------|---------------------------------------------|
| `[]`                                        | Schemas (`type`: `"schema"`)                |
| `[schema]`                                  | Tables and views                            |
| `[schema, table]`                           | Groups: `columns`, `indices`, `constraints` (`type`: `"group"`) |
| `[schema, table, "columns"]`                | Column names and types                      |
| `[schema, table, "indices"]`                | Index names and types                       |
| `[schema, table, "constraints"]`            | Constraint names and types                  |

`explore.describe(["<schema>", "<table>"])` returns a [TableDescription](#tabledescription):

```json
{
  "details": {
    "table": "users",
    "schema": "dbo",
    "columns": [
      {"name": "id",   "type": "int",     "nullable": false, "pk": false, "default": null},
      {"name": "name", "type": "varchar", "nullable": true,  "pk": false, "default": null}
    ]
  }
}
```

---

### `neo4j`

Requires: `pip install neo4j`

**Query language:** Cypher — positional bind values are referenced as `$0`, `$1`, … in the query.

**execute result note:** For write queries that do not `RETURN` rows, `rows_affected` is the sum of nodes created/deleted, relationships created/deleted, and properties set.

**Tree hierarchy**

| Path                              | Items returned                                             |
|-----------------------------------|------------------------------------------------------------|
| `[]`                              | Groups: `entities`, `relationships`, `indexes` (`type`: `"group"`) |
| `["entities"]`                    | Node labels (`type`: `"label"`)                            |
| `["relationships"]`               | Relationship types (`type`: `"relationship_type"`)         |
| `["indexes"]`                     | Index names (`type`: `"index"`)                            |
| `["entities", "<label>"]`         | Property keys observed on nodes of that label (`type`: `"property"`) |
| `["relationships", "<rel_type>"]` | Property keys observed on relationships of that type (`type`: `"property"`) |

`explore.describe` returns `null` for all paths.

---

### `oracle`

Requires: `pip install oracledb` (thin mode — no Oracle Instant Client required)

**Query language:** SQL — positional bind values are referenced as `:1`, `:2`, … in the query.

**Tree hierarchy**

| Path                                        | Items returned                              |
|---------------------------------------------|---------------------------------------------|
| `[]`                                        | Non-system schemas (`type`: `"schema"`)     |
| `[schema]`                                  | Tables and views                            |
| `[schema, table]`                           | Groups: `columns`, `indexes`, `constraints` (`type`: `"group"`) |
| `[schema, table, "columns"]`                | Column names and data types                 |
| `[schema, table, "indexes"]`                | Index names and types                       |
| `[schema, table, "constraints"]`            | Enabled user-named constraint names; `type` is one of `"primary_key"`, `"unique"`, `"check"`, `"foreign_key"` |

`explore.describe(["<schema>", "<table>"])` returns a [TableDescription](#tabledescription):

```json
{
  "details": {
    "table": "USERS",
    "schema": "MYSCHEMA",
    "columns": [
      {"name": "ID",   "type": "NUMBER", "nullable": false, "pk": true,  "default": null},
      {"name": "NAME", "type": "VARCHAR2(100)", "nullable": true, "pk": false, "default": null}
    ]
  }
}
```
