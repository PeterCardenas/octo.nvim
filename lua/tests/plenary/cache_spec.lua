local cache = require "octo.cache"
local config = require "octo.config"

local original_enabled
local test_keys = {}

local function unique_key()
  local key = cache.key("cache-test", "owner/repo", "issue", vim.uv.hrtime(), nil, "cache-test-user")
  test_keys[#test_keys + 1] = key
  return key
end

local function entry_path(key)
  return vim.fs.joinpath(vim.fn.stdpath "cache", "octo", "persistent", vim.fn.sha256(key) .. ".json")
end

local function wait_for_write(key, payload)
  local complete = false
  cache.write(key, payload, function()
    complete = true
  end)
  assert.is_true(vim.wait(5000, function()
    return complete
  end))
end

local function read_entry(key)
  local finished = false
  local result = false
  cache.read(key, function(payload)
    result = payload or false
    finished = true
  end)
  assert.is_true(vim.wait(5000, function()
    return finished
  end))
  return result
end

describe("Persistent stale-while-revalidate cache", function()
  before_each(function()
    original_enabled = config.values.persistent_cache.enabled
    config.values.persistent_cache.enabled = true
    test_keys = {}
  end)

  after_each(function()
    config.values.persistent_cache.enabled = original_enabled
    for _, key in ipairs(test_keys) do
      vim.uv.fs_unlink(entry_path(key), function() end)
    end
  end)

  it("isolates cache entries by a non-reversible authenticated identity hash", function()
    local alice_key = cache.key("github.com", "owner/repo", "issue", 17, nil, "alice")
    local bob_key = cache.key("github.com", "owner/repo", "issue", 17, nil, "bob")

    assert.are_not.same(alice_key, bob_key)
    assert.is_nil(alice_key:find("alice", 1, true))
    assert.is_nil(bob_key:find("bob", 1, true))
  end)

  it("ignores and removes corrupt cache files", function()
    local key = unique_key()
    local path = entry_path(key)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local file = assert(io.open(path, "w"))
    file:write "not valid json"
    file:close()

    assert.is_false(read_entry(key))
    assert.is_true(vim.wait(1000, function()
      return vim.uv.fs_stat(path) == nil
    end))
  end)

  it("ignores and removes cache entries from a different schema version", function()
    local key = unique_key()
    local path = entry_path(key)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local file = assert(io.open(path, "w"))
    file:write(vim.json.encode { version = 0, key = key, payload = { id = "old" } })
    file:close()

    assert.is_false(read_entry(key))
    assert.is_true(vim.wait(1000, function()
      return vim.uv.fs_stat(path) == nil
    end))
  end)

  it("serializes concurrent atomic writes without leaving a partial entry", function()
    local key = unique_key()
    local complete = 0
    cache.write(key, { id = "first" }, function()
      complete = complete + 1
    end)
    cache.write(key, { id = "second" }, function()
      complete = complete + 1
    end)
    assert.is_true(vim.wait(5000, function()
      return complete == 2
    end))

    local payload = read_entry(key)
    assert.is_true(payload.id == "first" or payload.id == "second")
    assert.is_true(vim.uv.fs_stat(entry_path(key)) ~= nil)
  end)

  it("does not read or write disk entries when disabled", function()
    local key = unique_key()
    local path = entry_path(key)
    vim.uv.fs_unlink(path, function() end)
    assert.is_true(vim.wait(1000, function()
      return vim.uv.fs_stat(path) == nil
    end))

    config.values.persistent_cache.enabled = false
    wait_for_write(key, { id = "disabled" })
    assert.is_false(read_entry(key))
    assert.is_nil(vim.uv.fs_stat(path))
  end)
end)
