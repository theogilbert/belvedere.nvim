local client = require("grannos.client")

describe("client.check_protocol_compat", function()
  it("returns nil when the server's major version matches the client's", function()
    assert.is_nil(client.check_protocol_compat(client.PROTOCOL_VERSION))
  end)

  it("returns nil when the server's minor version differs but major matches", function()
    local client_major = client.PROTOCOL_VERSION:match("^(%d+)")
    assert.is_nil(client.check_protocol_compat(client_major .. ".99"))
  end)

  it("returns a warning when the server's major version differs", function()
    local warning = client.check_protocol_compat("999.0")
    assert.is_not_nil(warning)
    assert.truthy(warning:match("protocol version mismatch"))
  end)

  it("returns a warning when the server predates protocol versioning (nil)", function()
    local warning = client.check_protocol_compat(nil)
    assert.is_not_nil(warning)
    assert.truthy(warning:match("pre%-versioning server"))
  end)
end)
