local config = require "octo.config"
local vim = vim
local uv = vim.uv

local M = {}
local SCHEMA_VERSION = 3
local MAX_CACHE_BYTES = 50 * 1024 * 1024
local MAX_ENTRY_BYTES = MAX_CACHE_BYTES
local CACHE_DIRECTORY = vim.fs.joinpath(vim.fn.stdpath "cache", "octo", "persistent")
local write_queue = {} ---@type { key: string, path: string, payload: table, callback: fun()? }[]
local writing = false
local next_temp_id = 0

---@param callback fun(): nil
local function schedule(callback)
  vim.schedule(callback)
end

---@return boolean
local function is_enabled()
  return config.values.persistent_cache.enabled
end

---@param host string
---@param repo string
---@param kind string
---@param number integer|string
---@param variant? string
---@param authenticated_identity string
---@return string
function M.key(host, repo, kind, number, variant, authenticated_identity)
  local parts = { host, vim.fn.sha256(host .. "\0" .. authenticated_identity), repo, kind, tostring(number) }
  if variant then
    parts[#parts + 1] = variant
  end
  return table.concat(parts, "\0")
end

---@param key string
---@return string
local function path_for_key(key)
  return vim.fs.joinpath(CACHE_DIRECTORY, vim.fn.sha256(key) .. ".json")
end

---@param path string
---@param callback fun(ok: boolean): nil
local function ensure_directory(path, callback)
  uv.fs_stat(path, function(_, stat)
    if stat and stat.type == "directory" then
      callback(true)
      return
    end

    local parent = vim.fs.dirname(path)
    if parent == path then
      callback(false)
      return
    end
    ensure_directory(parent, function(parent_ready)
      if not parent_ready then
        callback(false)
        return
      end
      uv.fs_mkdir(path, 448, function(err)
        if not err then
          callback(true)
          return
        end
        uv.fs_stat(path, function(_, existing)
          callback(existing ~= nil and existing.type == "directory")
        end)
      end)
    end)
  end)
end

---@param callback fun(): nil
local function ensure_cache_directory(callback)
  local octo_directory = vim.fs.dirname(CACHE_DIRECTORY)
  ensure_directory(octo_directory, function(parent_ready)
    if not parent_ready then
      callback()
      return
    end
    ensure_directory(CACHE_DIRECTORY, function()
      callback()
    end)
  end)
end

---@param callback fun(): nil
local function evict_old_entries(protected_path, callback)
  uv.fs_scandir(CACHE_DIRECTORY, function(scan_err, request)
    if scan_err or not request then
      callback()
      return
    end

    local entries = {} ---@type { path: string, size: integer, modified: integer }[]
    local pending = 0
    local scanning = true
    local function maybe_finish()
      if scanning or pending > 0 then
        return
      end

      local total_size = 0
      for _, entry in ipairs(entries) do
        total_size = total_size + entry.size
      end
      table.sort(entries, function(left, right)
        return left.modified < right.modified
      end)

      local index = 1
      local function remove_until_bounded()
        while total_size > MAX_CACHE_BYTES and index <= #entries do
          local entry = entries[index]
          index = index + 1
          if entry.path ~= protected_path then
            total_size = total_size - entry.size
            uv.fs_unlink(entry.path, function()
              remove_until_bounded()
            end)
            return
          end
        end
        callback()
      end
      remove_until_bounded()
    end

    while true do
      local name = uv.fs_scandir_next(request)
      if not name then
        break
      end
      if name:match "%.json$" then
        local entry_path = vim.fs.joinpath(CACHE_DIRECTORY, name)
        pending = pending + 1
        uv.fs_stat(entry_path, function(_, stat)
          if stat and stat.type == "file" then
            entries[#entries + 1] = {
              path = entry_path,
              size = stat.size,
              modified = stat.mtime and stat.mtime.sec or 0,
            }
          end
          pending = pending - 1
          maybe_finish()
        end)
      end
    end
    scanning = false
    maybe_finish()
  end)
end

---@param key string
---@param callback fun(payload: table?): nil
function M.read(key, callback)
  if vim.in_fast_event() then
    schedule(function()
      M.read(key, callback)
    end)
    return
  end
  if not is_enabled() then
    schedule(function()
      callback(nil)
    end)
    return
  end

  local path = path_for_key(key)
  uv.fs_open(path, "r", 384, function(open_err, fd)
    if open_err or not fd then
      schedule(function()
        callback(nil)
      end)
      return
    end

    uv.fs_fstat(fd, function(stat_err, stat)
      if stat_err or not stat or stat.size > MAX_ENTRY_BYTES then
        uv.fs_close(fd)
        uv.fs_unlink(path, function() end)
        schedule(function()
          callback(nil)
        end)
        return
      end

      uv.fs_read(fd, stat.size, 0, function(read_err, contents)
        uv.fs_close(fd)
        local ok, record = pcall(vim.json.decode, contents or "")
        local payload = not read_err
            and ok
            and type(record) == "table"
            and record.version == SCHEMA_VERSION
            and record.key == key
            and type(record.payload) == "table"
            and record.payload
          or nil
        if not payload then
          uv.fs_unlink(path, function() end)
        else
          local now = os.time()
          pcall(uv.fs_utime, path, now, now, function() end)
        end
        schedule(function()
          callback(payload)
        end)
      end)
    end)
  end)
end

---@param queued { key: string, path: string, payload: table, callback: fun()? }
local function write_entry(queued)
  if not is_enabled() then
    if queued.callback then
      queued.callback()
    end
    return
  end

  local ok, encoded = pcall(vim.json.encode, {
    version = SCHEMA_VERSION,
    key = queued.key,
    payload = queued.payload,
  })
  if not ok or #encoded > MAX_ENTRY_BYTES then
    if queued.callback then
      queued.callback()
    end
    return
  end

  ensure_cache_directory(function()
    next_temp_id = next_temp_id + 1
    local target = queued.path
    local temporary = target
      .. ".tmp-"
      .. tostring(uv.os_getpid())
      .. "-"
      .. tostring(uv.hrtime())
      .. "-"
      .. tostring(next_temp_id)
    uv.fs_open(temporary, "w", 384, function(open_err, fd)
      if open_err or not fd then
        if queued.callback then
          queued.callback()
        end
        return
      end

      uv.fs_write(fd, encoded, 0, function(write_err, bytes_written)
        local function cleanup()
          uv.fs_close(fd, function() end)
          uv.fs_unlink(temporary, function() end)
          if queued.callback then
            queued.callback()
          end
        end
        if write_err or bytes_written ~= #encoded then
          cleanup()
          return
        end

        uv.fs_fsync(fd, function(sync_err)
          uv.fs_close(fd, function(close_err)
            if sync_err or close_err then
              uv.fs_unlink(temporary, function() end)
              if queued.callback then
                queued.callback()
              end
              return
            end
            uv.fs_rename(temporary, target, function(rename_err)
              if rename_err then
                uv.fs_unlink(temporary, function() end)
                if queued.callback then
                  queued.callback()
                end
                return
              end
              evict_old_entries(target, function()
                if queued.callback then
                  queued.callback()
                end
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end

local function process_write_queue()
  if writing then
    return
  end
  local queued = table.remove(write_queue, 1)
  if not queued then
    return
  end
  writing = true
  local on_complete = queued.callback
  queued.callback = function()
    writing = false
    schedule(process_write_queue)
    if on_complete then
      on_complete()
    end
  end
  write_entry(queued)
end

---@param key string
---@param payload table
---@param callback? fun(): nil
function M.write(key, payload, callback)
  if vim.in_fast_event() then
    schedule(function()
      M.write(key, payload, callback)
    end)
    return
  end
  write_queue[#write_queue + 1] = {
    key = key,
    path = path_for_key(key),
    payload = vim.deepcopy(payload),
    callback = callback,
  }
  process_write_queue()
end

return M
