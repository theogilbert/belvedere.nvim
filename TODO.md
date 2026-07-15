# Belvedere.nvim — Code Review TODO

Issues are grouped by category and ordered roughly by impact. Each item references the
relevant file(s) and line(s).

---

## Duplication

### 4. Password-prompt + remember-dialog block repeated three times
**File:** `lua/belvedere/connections.lua:352-365`, `453-466`, `544-557`

Identical ~14-line block (prompt password → if non-empty → ask "Remember?") appears
in `create()`, `edit()`, and `clone()`. Extract to a local helper:

```lua
local function prompt_password_and_remember(pw_param, callback)
  -- callback(pw, remember)  or  callback(nil) on cancel
end
```

---

### 5. `fields_pre` building block repeated in `edit` and `clone`
**File:** `lua/belvedere/connections.lua:403-409`, `498-504`

Both functions build a `fields_pre` list by copying driver fields and setting their
`.default` to the current connection value. The loops are byte-for-byte identical.
Extract to `local function fields_with_defaults(fields, current)`.

---

### 6. `driver_label` resolution loop repeated three times
**File:** `lua/belvedere/connections.lua:415-418`, `510-513`; `lua/belvedere/init.lua:147-150`

```lua
for _, d in ipairs(caps.drivers or {}) do
  if d.driver == driver then driver_label = d.label; break end
end
```

Extract to `connections.driver_label(caps, driver_id)` (or a local helper in each
module) to avoid the three copies.

---

### 7. Triple-nested server→driver→group→conn iteration repeated three times
**Files:** `plugin/belvedere.lua:11-25` (`saved_connection_names`),
           `plugin/belvedere.lua:61-73` (`DbDeleteConnection`),
           `lua/belvedere/init.lua:92-104` (connect-by-display-name search)

All three use the same nested-pairs pattern to walk the full connection tree.
Add `connections.iter_all(fn)` that calls `fn(server, driver_id, group, name, params)`
for every leaf, and replace all three call sites.

---

### 8. `col_picker` duplicates Buffer's `show_help` logic
**File:** `lua/belvedere/ui/col_picker.lua:223-255`

The col_picker manages its own raw buffer (not a `Buffer` instance) and includes its
own help-float implementation. `Buffer:show_help()` already does the same thing with
grouping support.

Either convert col_picker to use a `Buffer` instance, or extract the help-float into
a standalone utility used by both.

---

## Complexity

### 9. `create()`, `edit()`, `clone()` have 5–6 levels of callback nesting
**File:** `lua/belvedere/connections.lua:296-373`, `375-471`, `474-562`

Each function chains: driver select → name input → group pick → field prompts →
password input → remember dialog, all nested. This makes error paths hard to follow
and changes hard to localise.

Consider flattening with a sequential helper (similar to the existing `prompt_sequence`)
that accumulates state between steps and calls a single `finish` at the end, rather than
closing over an ever-growing set of upvalues.

---

### 10. `edit()` indentation is broken by a misplaced `vim.schedule`
**File:** `lua/belvedere/connections.lua:390-470`

The extra `vim.schedule(function() ... end)` around the group input (line 390-391)
causes the closing `end)` on line 470 to be at a different indentation level from the
matching open. This makes the nesting structure visually misleading. Remove the
`vim.schedule` wrapper if it is not needed (the callback from `vim.ui.input` is already
deferred), or reindent consistently.

---

## Architecture

### 11. Circular dependency between `init.lua` and `ui/connections.lua`
**Files:** `lua/belvedere/init.lua`, `lua/belvedere/ui/connections.lua`

`init.lua` requires `ui/connections.lua` at the top level; `ui/connections.lua` must
lazy-`require("belvedere")` inside every function that needs it (lines 116, 155, 190,
196, 217, 218, 228, 250, 256, 301, 421). This is a workaround for a circular dependency
that was never resolved.

The cleanest fix is to split `init.lua`: move connection/session state (`state`,
`set_buf_conn`, `conn_for_buf`, `active_keys`, etc.) into a dedicated `session.lua`
module that neither side circularly depends on.

---

### 12. `read_data()` called multiple times per write operation
**File:** `lua/belvedere/connections.lua`

`edit()` calls `M.get(key)` (which calls `read_data()`) at the start, then calls
`read_data()` again inside `finish()` before writing. Similarly for `clone()` and
`delete()`. Between the two reads the file could be modified externally, and the
first read's data is discarded.

Read once at the start of each operation, pass the data through to `finish`, and write
it back at the end.

---

### 13. `write_data` is not atomic
**File:** `lua/belvedere/connections.lua:82-87`

`vim.fn.writefile` writes directly to the target path. If Neovim crashes mid-write the
connections file is corrupted. Write to a temp file first (`path .. ".tmp"`), then
rename it over the target using `vim.uv.fs_rename`.

---

## Dead Code / Unfinished

### 14. Block visual mode selection is unimplemented
**File:** `lua/belvedere/selection.lua:27`

```lua
-- TODO: handle block visual mode
```

The `\22` (ctrl-V) mode is detected by `is_in_visual_mode()` but `get_selection()`
silently returns incorrect results for it (treats it as character-wise). Either
implement it or guard `execute()` to reject block-visual with a `vim.notify`.

---

### 15. Private function exports only needed for tests
**File:** `lua/belvedere/executor.lua:149-150`

```lua
M._split_queries    = split_queries
M._is_only_comments = is_only_comments
```

These exist solely so `spec/executor_spec.lua` can access them. This pollutes the
module's public API. Options: move the tests to use a test-only helper file, or accept
the `_` prefix convention as sufficient documentation.

---

## Tests

### 16. `state.pending` left dirty between tests in `connections_spec`
**File:** `spec/connections_spec.lua`

`before_each` creates a new temp file and reconfigures `config`, but the `connections`
module re-reads the file path from `config.options` on every call, so this works.
However there is no `after_each` cleanup if a test fails before the delete runs (e.g.,
an unexpected error mid-test). Use `pcall` in the `after_each` guard (already done)
but also assert the temp file was actually deleted.

---

### 17. No tests for file I/O operations
**File:** `spec/connections_spec.lua`

`M.get()` and key helpers are tested, but `write_data` / `read_data` paths are not:
- `M.delete()` modifying the file
- `M.create_group()` writing to the file
- Corrupt JSON returning nil from `read_data`
- Concurrent write (write then immediately read) round-trip

---

### 18. No tests for `table.lua`, `selection.lua`, `client.lua` logic
These modules have no specs at all.
- `table.lua`: `from_structured_data`, `null_hl_rules`, `column_byte_positions` are
  pure functions that are straightforward to unit-test.
- `selection.lua`: `get_selection` column-boundary logic is easy to test.
- `client.lua`: `_dispatch` and line-buffering in `on_stdout` can be tested in isolation.

---

## Minor / Style

### 19. Stale origin comments
**Files:** `lua/belvedere/buffer.lua:1`, `lua/belvedere/table.lua:2`

"Ported from nvim-dap-df/lua/nvim-dap-df-pane/buffer.lua" and "Adapted from
utilities/table.lua (nvim-dap-df project)" are archaeological notes that add noise for
a reader of this codebase. Remove them.

---

### 20. `on_stdout` has unnecessary parameter name
**File:** `lua/belvedere/client.lua:22`

`local function on_stdout(_, data, _)` — the signature has two `_` placeholders;
the Neovim jobstart convention names them `job_id` (first) and `event` (third).
Using named parameters makes it easier to understand the callback signature.

---

### 21. `detect_operation` misses SQL that starts with a comment
**File:** `lua/belvedere/executor.lua:18-21`

```lua
local word = (vim.trim(sql):match("^(%a+)") or ""):lower()
```

`split_queries` preserves inline comments attached to a statement (e.g.,
`"-- comment\nSELECT ..."`) so `detect_operation` will return `"affected"` instead of
`nil` for those cases (the DML verbs won't match "–" or "/"). The practical impact is
a misleading verb in the status line for DML behind a comment. Change the pattern to
skip leading comment tokens, or strip comments before matching.
