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

local function cached_issue(id)
  return {
    id = id,
    number = 1,
    title = id,
    body = "",
    timelineItems = { nodes = {} },
  }
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

  it("ignores malformed cache files without unlinking a possibly replaced path", function()
    local key = unique_key()
    local path = entry_path(key)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local file = assert(io.open(path, "w"))
    file:write "not valid json"
    file:close()

    assert.is_false(read_entry(key))
    assert.is_not_nil(vim.uv.fs_stat(path))
  end)

  it("ignores cache entries from a different schema version without unlinking them", function()
    local key = unique_key()
    local path = entry_path(key)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local file = assert(io.open(path, "w"))
    file:write(vim.json.encode { version = 0, key = key, payload = { id = "old" } })
    file:close()

    assert.is_false(read_entry(key))
    assert.is_not_nil(vim.uv.fs_stat(path))
  end)

  it("rejects an envelope whose JSON payload is not a cached object", function()
    local key = unique_key()
    local path = entry_path(key)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local file = assert(io.open(path, "w"))
    file:write(vim.json.encode { version = 3, key = key, payload = { id = "incomplete" } })
    file:close()

    assert.is_false(read_entry(key))
    assert.is_not_nil(vim.uv.fs_stat(path))
  end)

  it("does not let an invalid reader unlink an entry atomically replaced by a writer", function()
    local key = unique_key()
    local path = entry_path(key)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile({ "invalid old entry" }, path)

    local original_fs_read = vim.uv.fs_read
    local delayed_read
    vim.uv.fs_read = function(_, _, _, callback)
      delayed_read = callback
    end

    local read_complete = false
    cache.read(key, function()
      read_complete = true
    end)
    assert.is_true(vim.wait(1000, function()
      return delayed_read ~= nil
    end))

    wait_for_write(key, {
      id = "replaced",
      number = 1,
      title = "Replaced",
      body = "",
      timelineItems = { nodes = {} },
    })
    vim.uv.fs_read = original_fs_read
    delayed_read(nil, "invalid old entry")

    assert.is_true(vim.wait(1000, function()
      return read_complete
    end))
    vim.wait(100, function()
      return false
    end)
    assert.is_not_nil(vim.uv.fs_stat(path))
  end)

  it("serializes concurrent atomic writes without leaving a partial entry", function()
    local key = unique_key()
    local complete = 0
    cache.write(key, cached_issue "first", function()
      complete = complete + 1
    end)
    cache.write(key, cached_issue "second", function()
      complete = complete + 1
    end)
    assert.is_true(vim.wait(5000, function()
      return complete == 2
    end))

    local payload = read_entry(key)
    assert.is_true(payload.id == "first" or payload.id == "second")
    assert.is_true(vim.uv.fs_stat(entry_path(key)) ~= nil)
  end)

  it("aborts cache writes when securing the cache directory fails", function()
    local key = unique_key()
    local octo_directory = vim.fs.joinpath(vim.fn.stdpath "cache", "octo")
    local original_lstat = vim.uv.fs_lstat
    local original_chmod = vim.uv.fs_chmod
    local original_open = vim.uv.fs_open
    local opens = 0
    local completed = false
    vim.uv.fs_lstat = function(path, callback)
      if path == octo_directory then
        callback(nil, { type = "directory" })
      else
        original_lstat(path, callback)
      end
    end
    vim.uv.fs_chmod = function(path, _, callback)
      if path == octo_directory then
        callback "EACCES"
      else
        original_chmod(path, 448, callback)
      end
    end
    vim.uv.fs_open = function(...)
      opens = opens + 1
      return original_open(...)
    end

    cache.write(key, cached_issue "denied", function()
      completed = true
    end)
    assert.is_true(vim.wait(1000, function()
      return completed
    end))

    vim.uv.fs_lstat = original_lstat
    vim.uv.fs_chmod = original_chmod
    vim.uv.fs_open = original_open
    assert.are.same(0, opens)
  end)

  it("tightens existing cache directories and files to private permissions", function()
    local key = unique_key()
    local path = entry_path(key)
    local directory = vim.fs.dirname(path)
    local octo_directory = vim.fs.dirname(directory)
    vim.fn.mkdir(directory, "p")
    vim.fn.setfperm(octo_directory, "rwxr-xr-x")
    vim.fn.setfperm(directory, "rwxr-xr-x")

    wait_for_write(key, {
      id = "private",
      number = 1,
      title = "Private",
      body = "",
      timelineItems = { nodes = {} },
    })
    assert.are.same("rwx------", vim.fn.getfperm(octo_directory))
    assert.are.same("rwx------", vim.fn.getfperm(directory))

    vim.fn.setfperm(path, "rw-r--r--")
    assert.is_not_false(read_entry(key))
    assert.are.same("rw-------", vim.fn.getfperm(path))
  end)

  it("counts abandoned temporary files and only accounts for successful evictions", function()
    local key = unique_key()
    local directory = vim.fs.dirname(entry_path(key))
    local blocked = vim.fs.joinpath(directory, "eviction.tmp-blocked")
    local removable = vim.fs.joinpath(directory, "eviction.tmp-removable")
    local scan_request = {}
    local scan_names = { "eviction.tmp-blocked", "eviction.tmp-removable" }
    local next_scan_name = 0
    local blocked_unlinked = false
    local removable_unlinked = false
    local original_fs_scandir = vim.uv.fs_scandir
    local original_fs_scandir_next = vim.uv.fs_scandir_next
    local original_fs_stat = vim.uv.fs_stat
    local original_fs_unlink = vim.uv.fs_unlink

    vim.uv.fs_scandir = function(path, callback)
      if path == directory then
        callback(nil, scan_request)
      else
        original_fs_scandir(path, callback)
      end
    end
    vim.uv.fs_scandir_next = function(request)
      if request ~= scan_request then
        return original_fs_scandir_next(request)
      end
      next_scan_name = next_scan_name + 1
      return scan_names[next_scan_name]
    end
    vim.uv.fs_stat = function(path, callback)
      if path == blocked then
        callback(nil, { type = "file", size = 25 * 1024 * 1024 + 1, mtime = { sec = 1 } })
      elseif path == removable then
        callback(nil, { type = "file", size = 25 * 1024 * 1024, mtime = { sec = 2 } })
      else
        original_fs_stat(path, callback)
      end
    end
    vim.uv.fs_unlink = function(path, callback)
      if path == blocked then
        blocked_unlinked = true
        callback "EACCES"
      elseif path == removable then
        removable_unlinked = true
        callback(nil)
      else
        original_fs_unlink(path, callback)
      end
    end

    local complete = false
    cache.write(
      key,
      { id = "eviction", number = 1, title = "Eviction", body = "", timelineItems = { nodes = {} } },
      function()
        complete = true
      end
    )
    assert.is_true(vim.wait(5000, function()
      return complete
    end))

    vim.uv.fs_scandir = original_fs_scandir
    vim.uv.fs_scandir_next = original_fs_scandir_next
    vim.uv.fs_stat = original_fs_stat
    vim.uv.fs_unlink = original_fs_unlink

    assert.is_true(blocked_unlinked)
    assert.is_true(removable_unlinked)
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
