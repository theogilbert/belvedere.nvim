local column = require("belvedere.ui.column")

local function base_col(overrides)
  local col = {
    type = "column",
    name = "user_id",
    data_type = "INTEGER",
    nullable = false,
    pk = false,
    default = vim.NIL,
    exclusive_indices = {},
    composite_indices = {},
    comment = vim.NIL,
    sample = {},
  }
  return vim.tbl_extend("force", col, overrides or {})
end

describe("column.hover_lines", function()
  it("omits foreign key lines when outgoing_references is absent", function()
    local lines = column.hover_lines(base_col())
    assert.same({ "user_id", "  INTEGER  ·  not null" }, lines)
  end)

  it("omits foreign key lines when outgoing_references is empty", function()
    local lines = column.hover_lines(base_col({ outgoing_references = {} }))
    assert.same({ "user_id", "  INTEGER  ·  not null" }, lines)
  end)

  it("appends one arrow line per reference, schema-qualified when present", function()
    local lines, hls = column.hover_lines(base_col({
      outgoing_references = {
        { column = "user_id", table = "users", ref_column = "id", schema = vim.NIL },
        { column = "user_id", table = "archived_users", ref_column = "id", schema = "public" },
      },
    }))
    assert.same({
      "user_id",
      "  INTEGER  ·  not null",
      "  →  users.id",
      "  →  public.archived_users.id",
    }, lines)

    local groups_on_row = function(row)
      local groups = {}
      for _, h in ipairs(hls) do
        if h[2] == row then groups[#groups + 1] = h[1] end
      end
      return groups
    end
    assert.same({ "BelvedereExplorerTable", "BelvedereExplorerColumn" }, groups_on_row(2))
    assert.same({ "BelvedereExplorerTable", "BelvedereExplorerColumn" }, groups_on_row(3))
  end)
end)
