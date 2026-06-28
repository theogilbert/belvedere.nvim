# belvedere protocol

Communication between the **client** and the **server** uses newline-delimited JSON over stdio. The client spawns the server as a child process and communicates through its stdin/stdout pipes.

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
client → {"id":2,"method":"execute","params":{"connection_id":"0","query":"SELECT ..."}}
server → {"id":2,"progress":{"status":"reconnecting","message":"Connection lost, reconnecting…"}}
server → {"id":2,"progress":{"status":"executing","message":"Retrying query…"}}
server → {"id":2,"result":{"columns":[…],"rows":[…]},"error":null}
```

Methods that currently support progress: `execute`.

---

## Methods

### `capabilities`

Returns the server's name and the full list of drivers it supports, including the connection parameters each driver accepts. Clients should call this once after starting the server and use the result to drive connection wizards instead of hard-coding driver lists.

Only drivers whose dependencies are installed appear in the response.

**params** — none (`{}`)

**result**

| Field     | Type                       | Description                                     |
|-----------|----------------------------|-------------------------------------------------|
| `server`  | string                     | Human-readable server name (e.g. `"belvedere"`) |
| `drivers` | array of [Driver](#driver) | Supported drivers                               |

**example**

```json
{"id":1,"method":"capabilities","params":{}}
```
```json
{
  "id": 1,
  "result": {
    "server": "belvedere",
    "drivers": [
      {
        "driver": "mydriver",
        "label": "My Driver",
        "params": [
          {"key": "host",     "type": "string",  "label": "Host",     "required": true},
          {"key": "port",     "type": "integer", "label": "Port",     "default": 5432},
          {"key": "password", "type": "string",  "label": "Password", "secret": true}
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
| `query`         | string           | Query to execute                   |
| `params`        | array (optional) | Positional bind parameters         |

**result — SELECT / RETURN**

| Field         | Type              | Description                                        |
|---------------|-------------------|----------------------------------------------------|
| `columns`     | array of strings  | Column names, in order                             |
| `rows`        | array of arrays   | Each row is an array of values                     |
| `rows_total`  | integer           | Total number of rows matching the query            |
| `duration_ms` | number            | Wall-clock execution time in milliseconds          |

**result — INSERT / UPDATE / DELETE / write statements**

| Field           | Type    | Description                                 |
|-----------------|---------|---------------------------------------------|
| `rows_affected` | integer | Number of rows/nodes/relationships affected |
| `duration_ms`   | number  | Wall-clock execution time in milliseconds   |

**examples**

```json
{"id":2,"method":"execute","params":{"connection_id":"0","query":"SELECT id, name FROM users WHERE active = ?","params":[1]}}
{"id":2,"result":{"columns":["id","name"],"rows":[[1,"Alice"],[2,"Bob"]],"rows_total":2,"duration_ms":3.142},"error":null}
```

```json
{"id":3,"method":"execute","params":{"connection_id":"0","query":"DELETE FROM users WHERE active = 0"}}
{"id":3,"result":{"rows_affected":4,"duration_ms":1.05},"error":null}
```

---

### `cancel`

Cancels an in-flight request. The targeted request receives an error response with `"cancelled"` as the error message. If the request has already completed, or the `request_id` is not recognised, the call is a no-op and still returns `{"ok": true}`.

**params**

| Field        | Type    | Description                        |
|--------------|---------|------------------------------------|
| `request_id` | integer | `id` of the request to cancel      |

**result**

```json
{"ok": true}
```

**example**

```
client → {"id":4,"method":"cancel","params":{"request_id":2}}
server → {"id":4,"result":{"ok":true},"error":null}
server → {"id":2,"result":null,"error":"cancelled"}
```

The `cancel` response and the cancelled request's error response may arrive in either order.

---

### `explore.list`

Returns the children of a node in the database object tree. The tree is navigated by a `path` — an ordered list of node names from the root.

**params**

| Field           | Type             | Description                                    |
|-----------------|------------------|------------------------------------------------|
| `connection_id` | string           | Connection to explore                          |
| `path`          | array of strings | Path to the node whose children are requested  |
| `reset_cache`   | boolean (optional, default `false`) | Evict cached explore data for `path` and all nodes below it before fetching |

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
| `reset_cache`   | boolean (optional, default `false`) | Evict cached explore data for `path` and all nodes below it before fetching |

**result**

| Field     | Type                | Description                    |
|-----------|---------------------|--------------------------------|
| `details` | object or null      | Description object, or null if the path does not resolve to a describable node. Discriminate on the `type` field: `"table"` → [TableDescription](#tabledescription), `"index"` → [IndexDescription](#indexdescription), `"indices"` → [IndicesDescription](#indicesdescription), `"column"` → [ColumnDescription](#columndescription), `"columns"` → [ColumnsDescription](#columnsdescription) |

---

### `explore.preview`

Returns a sample of up to 10 rows from the node at the given path. Only supported for table, view, and collection nodes; returns null fields for unsupported node types.

**params**

| Field           | Type             | Description            |
|-----------------|------------------|------------------------|
| `connection_id` | string           | Connection to query    |
| `path`          | array of strings | Path to the node       |

**result**

| Field         | Type              | Description                                        |
|---------------|-------------------|----------------------------------------------------|
| `columns`     | array of strings or null | Column names, in order; null if not supported |
| `rows`        | array of arrays or null  | Up to 10 rows; null if not supported         |
| `rows_total`  | integer or null   | Total rows returned                                |
| `duration_ms` | number            | Wall-clock execution time in milliseconds          |

**example**

```json
{"id":6,"method":"explore.preview","params":{"connection_id":"0","path":["public","users"]}}
{"id":6,"result":{"columns":["id","name"],"rows":[[1,"Alice"],[2,"Bob"]],"rows_total":2,"duration_ms":1.5},"error":null}
```

---

### `driver.help`

Returns documentation for a specific driver as a markdown string. Clients should display this in a help buffer when the user requests driver-specific documentation.

**params**

| Field    | Type   | Description                                          |
|----------|--------|------------------------------------------------------|
| `driver` | string | Driver identifier (as returned by `capabilities`)    |

**result**

| Field     | Type   | Description                        |
|-----------|--------|------------------------------------|
| `content` | string | Driver documentation in Markdown   |

**example**

```json
{"id":5,"method":"driver.help","params":{"driver":"mydriver"}}
```
```json
{"id":5,"result":{"content":"# My Driver\n\nQuery language: ..."},"error":null}
```

---

## Driver

Each entry in the `capabilities.drivers` array:

| Field       | Type                              | Description                                     |
|-------------|-----------------------------------|-------------------------------------------------|
| `driver`    | string                            | Driver identifier; passed as `driver` in `connect.params` |
| `label`     | string                            | Human-readable display name (e.g. `"SQLite"`, `"SQL Server"`) |
| `params`    | array of [DriverParam](#driverparam) | Connection parameters, in display order      |
| `languages` | array of [Language](#language)    | Query languages this driver supports. Empty when the driver has no language affinity. |

## Language

String enum of standard query-language identifiers used in `Driver.languages`:

| Value      | Language                |
|------------|-------------------------|
| `"sql"`    | Structured Query Language (SQL) |
| `"cypher"` | Cypher graph query language (Neo4j) |

Mapping these to editor-specific concepts (e.g. Vim filetypes) is the client's responsibility.

## DriverParam

| Field      | Type    | Required | Description                                                        |
|------------|---------|----------|--------------------------------------------------------------------|
| `key`      | string  | yes      | Parameter key sent in `connect.params`                             |
| `type`     | string  | yes      | `"string"`, `"integer"`, or `"enum"`                               |
| `label`    | string  | yes      | Human-readable label for UI display                                |
| `required` | boolean | no       | Whether a non-empty value is required (default `true`)             |
| `default`  | string or integer | no | Default value pre-filled in the UI                       |
| `choices`  | array of [DriverParamChoice](#driverparamchoice) | for `"enum"` | Allowed options |
| `secret`   | boolean | no       | Mask input in the UI (e.g. for passwords); never persisted to disk |

## DriverParamChoice

| Field   | Type   | Description                                    |
|---------|--------|------------------------------------------------|
| `value` | string | Machine-readable value sent in `connect.params` |
| `label` | string | Human-readable display name shown in the UI    |

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

Column metadata object used inside [TableDescription](#tabledescription):

| Field      | Type             | Description                                       |
|------------|------------------|---------------------------------------------------|
| `name`     | string           | Column name                                       |
| `type`     | string           | Data type as reported by the database             |
| `nullable` | boolean or null  | Whether the column allows NULL; null if unknown   |
| `pk`       | boolean          | Whether the column is part of the primary key     |
| `default`  | string or null   | Default expression, or null if not set            |
| `exclusive_index` | boolean | `true` if this column is covered by at least one index that spans only this column |
| `composite_index` | boolean | `true` if this column is covered by at least one index that also spans other columns |

---

## TableDescription

Returned as `details` by `explore.describe` for table/view nodes:

| Field     | Type                    | Description                                              |
|-----------|-------------------------|----------------------------------------------------------|
| `type`    | string                  | Always `"table"` — use to discriminate description types |
| `table`   | string                  | Table name                                               |
| `schema`  | string or null          | Schema name, or null for databases without schema support |
| `columns` | array of [ColumnInfo](#columninfo) | Ordered column metadata                     |

---

## IndexKeyField

One field in an index key, used inside [IndexDescription](#indexdescription):

| Field       | Type   | Description                                                                 |
|-------------|--------|-----------------------------------------------------------------------------|
| `name`      | string | Field name                                                                  |
| `direction` | string | Sort direction or index kind (`"asc"`, `"desc"`, `"text"`, `"hashed"`, …)  |

---

## IndexDescription

Returned as `details` by `explore.describe` for index nodes, and embedded inside [IndicesDescription](#indicesdescription):

| Field               | Type                                     | Description                                                                                              |
|---------------------|------------------------------------------|----------------------------------------------------------------------------------------------------------|
| `type`              | string                                   | Always `"index"` — use to discriminate description types                                                 |
| `index`             | string                                   | Index name                                                                                               |
| `fields`            | array of [IndexKeyField](#indexkeyfield) | Ordered list of key fields                                                                               |
| `unique`            | boolean                                  | Whether the index enforces uniqueness (default `false`)                                                  |
| `tables`            | array of strings                         | Tables (or labels/collections) the index operates on. Typically one entry; multiple for Oracle cluster indexes and SQL Server indexed views |
| `index_type`        | string or null                           | Storage type as reported by the driver (e.g. `"btree"`, `"hash"`, `"bitmap"`, `"text"`, `"hashed"`); `null` if unknown |
| `clustered`         | boolean                                  | Whether the index defines the physical row order of the table (default `false`)                          |
| `visible`           | boolean                                  | Whether the query optimiser considers this index (default `true`); `false` for Oracle `INVISIBLE` or SQL Server `DISABLED` indexes |
| `included_columns`  | array of strings                         | Non-key columns stored in index leaf pages for covering queries (PostgreSQL / SQL Server `INCLUDE`); empty when not supported |
| `condition`         | string or null                           | Partial/filtered index predicate in the driver's native syntax; `null` if the index covers all rows      |
| `ddl`               | string or null                           | `CREATE INDEX` statement as stored by the database; `null` when the driver cannot produce it             |

---

## IndicesDescription

Returned as `details` by `explore.describe` when the path resolves to an indices group node (e.g. `["public", "users", "indices"]`):

| Field     | Type                                         | Description                                          |
|-----------|----------------------------------------------|------------------------------------------------------|
| `type`    | string                                       | Always `"indices"` — use to discriminate description types |
| `indices` | array of [IndexDescription](#indexdescription) | All indexes on this table, in driver-defined order |

---

## ColumnDescription

Returned as `details` by `explore.describe` when the path resolves to an individual column node (e.g. `["public", "users", "columns", "id"]`), and embedded inside [ColumnsDescription](#columnsdescription).

| Field               | Type                                           | Description                                                              |
|---------------------|------------------------------------------------|--------------------------------------------------------------------------|
| `type`              | string                                         | Always `"column"` — use to discriminate description types                |
| `name`              | string                                         | Column name                                                              |
| `data_type`         | string                                         | Data type as reported by the database                                    |
| `nullable`          | boolean or null                                | Whether the column allows NULL; null if unknown                          |
| `pk`                | boolean                                        | Whether the column is part of the primary key                            |
| `default`           | string or null                                 | Default expression, or null if not set                                   |
| `exclusive_indices` | array of [IndexDescription](#indexdescription) | Indices that cover only this column                                      |
| `composite_indices` | array of [IndexDescription](#indexdescription) | Indices that cover this column and at least one other column             |
| `comment`           | string or null                                 | Column comment as stored in the database; null if unsupported or not set |
| `sample`            | array                                          | Up to 3 distinct non-null representative values sampled from the column  |

---

## ColumnsDescription

Returned as `details` by `explore.describe` when the path resolves to a columns group node (e.g. `["public", "users", "columns"]`):

| Field     | Type                                             | Description                                                     |
|-----------|--------------------------------------------------|-----------------------------------------------------------------|
| `type`    | string                                           | Always `"columns"` — use to discriminate description types      |
| `columns` | array of [ColumnDescription](#columndescription) | All columns in this table, in declaration order                 |

---

## Drivers

The `driver` field in `connect.params` selects the backend. Connection parameters accepted by each driver are announced at runtime via [`capabilities`](#capabilities). Query language, bind syntax, and explore tree structure are driver-specific and documented by the server implementation.
