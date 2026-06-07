# dbelveder protocol

Communication between **dbelveder.nvim** (client) and **dbelveder-py** (server) uses newline-delimited JSON over stdio. The client spawns the server as a child process and communicates through its stdin/stdout pipes.

## Wire format

Each message is a single JSON object serialized on one line, terminated by `\n`. There is no envelope, framing header, or length prefix — a line boundary is a message boundary.

```
{"id":1,"method":"connect","params":{"driver":"sqlite","database":"/tmp/test.db"}}\n
{"id":1,"result":{"ok":true},"error":null}\n
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

## Methods

### `connect`

Opens a database connection. Any previously open connection is closed first.

**params**

| Field    | Type   | Description                      |
|----------|--------|----------------------------------|
| `driver` | string | See [Drivers](#drivers)          |
| …        | …      | Driver-specific fields (see below) |

**result**

```json
{"ok": true}
```

---

### `disconnect`

Closes the current connection.

**params** — `{}` (none)

**result**

```json
{"ok": true}
```

---

### `execute`

Runs a SQL statement and returns the result set.

**params**

| Field    | Type            | Description                        |
|----------|-----------------|------------------------------------|
| `sql`    | string          | SQL statement to execute           |
| `params` | array (optional)| Positional bind parameters         |

**result**

| Field     | Type              | Description                       |
|-----------|-------------------|-----------------------------------|
| `columns` | array of strings  | Column names, in order            |
| `rows`    | array of arrays   | Each row is an array of values    |

**example**

```json
{"id":2,"method":"execute","params":{"sql":"SELECT id, name FROM users WHERE active = ?","params":[1]}}
```
```json
{"id":2,"result":{"columns":["id","name"],"rows":[[1,"Alice"],[2,"Bob"]]},"error":null}
```

---

### `explore.list`

Returns the children of a node in the database object tree. The tree is navigated by a `path` — an ordered list of node names from the root.

**params**

| Field  | Type            | Description                                    |
|--------|-----------------|------------------------------------------------|
| `path` | array of strings | Path to the node whose children are requested |

**result**

| Field   | Type              | Description             |
|---------|-------------------|-------------------------|
| `items` | array of [ExploreItem](#exploreitem) | Child nodes |

**example**

```json
{"id":3,"method":"explore.list","params":{"path":[]}}
```
```json
{"id":3,"result":{"items":[{"name":"public","type":"schema","expandable":true}]},"error":null}
```

---

### `explore.describe`

Returns detailed metadata about a specific node.

**params**

| Field  | Type             | Description            |
|--------|------------------|------------------------|
| `path` | array of strings | Path to the node       |

**result** — driver-specific object (see [Tree hierarchies](#tree-hierarchies)).

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

The `driver` field in the `connect` params selects the backend.

### `sqlite`

| Field      | Type   | Default | Description              |
|------------|--------|---------|--------------------------|
| `driver`   | string | —       | `"sqlite"`               |
| `database` | string | —       | File path or `":memory:"` |

**Tree hierarchy**

| Path                      | Items returned                              |
|---------------------------|---------------------------------------------|
| `[]`                      | Tables and views (`type`: `"table"`, `"view"`) |
| `[table]`                 | Groups: `columns`, `indices`                |
| `[table, "columns"]`      | Column names and types                      |
| `[table, "indices"]`      | Index names                                 |

`explore.describe(["<table>"])` returns:

```json
{
  "table": "users",
  "columns": [
    {"name": "id",   "type": "INTEGER", "notnull": true,  "pk": true},
    {"name": "name", "type": "TEXT",    "notnull": false, "pk": false}
  ]
}
```

---

### `postgres` / `postgresql`

| Field      | Type    | Default       | Description       |
|------------|---------|---------------|-------------------|
| `driver`   | string  | —             | `"postgres"`      |
| `host`     | string  | `"localhost"` |                   |
| `port`     | integer | `5432`        |                   |
| `database` | string  | `""`          |                   |
| `user`     | string  | `""`          |                   |
| `password` | string  | `""`          |                   |

Requires: `pip install 'psycopg[binary]'`

**Tree hierarchy**

| Path                          | Items returned                          |
|-------------------------------|-----------------------------------------|
| `[]`                          | Schemas (excludes `pg_catalog`, `information_schema`) |
| `[schema]`                    | Tables and views                        |
| `[schema, table]`             | Groups: `columns`, `indices`, `constraints` |
| `[schema, table, "columns"]`  | Column names and data types             |

`explore.describe(["<schema>", "<table>"])` returns:

```json
{
  "schema": "public",
  "table": "users",
  "columns": [
    {"name": "id",   "type": "integer",         "nullable": false, "default": null},
    {"name": "name", "type": "character varying","nullable": true,  "default": null}
  ]
}
```

---

### `sqlserver` / `mssql`

| Field      | Type    | Default       | Description  |
|------------|---------|---------------|--------------|
| `driver`   | string  | —             | `"sqlserver"` |
| `host`     | string  | `"localhost"` |              |
| `port`     | integer | `1433`        |              |
| `database` | string  | `""`          |              |
| `user`     | string  | `""`          |              |
| `password` | string  | `""`          |              |

Requires: `pip install mssql-python`

**Tree hierarchy** — same as PostgreSQL (`schema → table → columns/indices/constraints`), using `INFORMATION_SCHEMA` views.

---

### `mongodb` / `mongo`

| Field      | Type    | Default       | Description               |
|------------|---------|---------------|---------------------------|
| `driver`   | string  | —             | `"mongodb"`               |
| `host`     | string  | `"localhost"` |                           |
| `port`     | integer | `27017`       |                           |
| `database` | string  | `""`          | Default database (optional) |
| `user`     | string  | `""`          |                           |
| `password` | string  | `""`          |                           |

Requires: `pip install pymongo`

**Tree hierarchy**

| Path                   | Items returned                                      |
|------------------------|-----------------------------------------------------|
| `[]`                   | Databases (`type: "database"`)                      |
| `[database]`           | Collections (`type: "collection"`)                  |
| `[database, collection]` | Fields sampled from one document (`type`: Python type name) |

`explore.describe(["<db>", "<collection>"])` returns:

```json
{
  "database": "mydb",
  "collection": "users",
  "count": 42150,
  "sample_fields": ["_id", "name", "email", "created_at"]
}
```

`execute` is not supported for MongoDB and will return an error.
