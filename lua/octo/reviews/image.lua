local gh = require "octo.gh"
local config = require "octo.config"

local M = {}

---@param path string
---@return boolean
function M.supports(path)
  return _G.Snacks ~= nil and Snacks.image.config.enabled ~= false and Snacks.image.supports_file(path)
end

---@param value string
---@return string
local function encode_path(value)
  return (value:gsub("[^%w%-%._~/]", function(char)
    return string.format("%%%02X", char:byte())
  end))
end

---The existing text loaders normalize newlines and cannot carry image bytes.
---@param repo string
---@param commit string
---@param path string
---@param use_local boolean
---@param callback fun(path: string?, err: string?)
function M.fetch(repo, commit, path, use_local, callback)
  local cache = vim.fn.stdpath "cache" .. "/octo/images"
  local host = config.values.github_hostname
  if require("octo.utils").is_blank(host) then
    host = require("octo.utils").get_remote_host() or "github.com"
  end
  local key = table.concat({ host, repo, commit, path }, "\0")
  local cached = cache .. "/" .. vim.fn.sha256(key) .. "." .. vim.fn.fnamemodify(path, ":e")
  if vim.fn.filereadable(cached) == 1 then
    callback(cached)
    return
  end

  local function save(bytes)
    if not bytes or bytes == "" then
      callback(nil, "Image has no content")
      return
    end
    vim.fn.mkdir(cache, "p", 448)
    local fd, err = vim.uv.fs_open(cached, "w", 384)
    if not fd then
      callback(nil, err)
      return
    end
    local written, write_err = vim.uv.fs_write(fd, bytes, 0)
    vim.uv.fs_close(fd)
    if written ~= #bytes then
      vim.fn.delete(cached)
      callback(nil, write_err or "Incomplete image write")
      return
    end
    callback(cached)
  end

  if use_local then
    vim.system(
      { "git", "show", commit .. ":" .. path },
      {},
      vim.schedule_wrap(function(result)
        if result.code ~= 0 then
          callback(nil, vim.trim(result.stderr or "Could not read image from git"))
          return
        end
        save(result.stdout)
      end)
    )
    return
  end

  local function download(endpoint, is_blob)
    gh.api.get {
      endpoint,
      opts = {
        cb = function(output, stderr, code)
          if code ~= 0 then
            callback(nil, vim.trim(stderr or "Could not download image"))
            return
          end
          local ok, blob = pcall(vim.json.decode, output)
          if not ok or type(blob) ~= "table" then
            callback(nil, "Invalid image response")
            return
          end
          -- Contents above 1 MiB omit inline data; the blob API supports up to 100 MiB.
          if not is_blob and blob.encoding == "none" and type(blob.sha) == "string" then
            download("/repos/" .. repo .. "/git/blobs/" .. blob.sha, true)
            return
          end
          if blob.encoding ~= "base64" or type(blob.content) ~= "string" then
            callback(nil, "Image response has no base64 content")
            return
          end
          local decoded, bytes = pcall(vim.base64.decode, (blob.content:gsub("%s", "")))
          if not decoded then
            callback(nil, "Invalid base64 image content")
            return
          end
          save(bytes)
        end,
      },
    }
  end
  download("/repos/" .. repo .. "/contents/" .. encode_path(path) .. "?ref=" .. encode_path(commit), false)
end

---@param bufnr integer
---@param path string
function M.render(bufnr, path)
  Snacks.image.terminal.detect(function()
    -- Detection is async: the user may have closed or switched away from this file.
    if not vim.api.nvim_buf_is_valid(bufnr) or #vim.fn.win_findbuf(bufnr) == 0 then
      return
    end
    Snacks.image.placement.clean(bufnr)
    if not Snacks.image.supports_terminal() then
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(
        bufnr,
        0,
        -1,
        false,
        { "Image preview requires a Kitty graphics terminal (:checkhealth snacks)" }
      )
      vim.bo[bufnr].modifiable = false
      return
    end
    vim.bo[bufnr].filetype = "image"
    Snacks.image.placement.new(bufnr, path, { auto_resize = true, conceal = true })
  end)
end

return M
