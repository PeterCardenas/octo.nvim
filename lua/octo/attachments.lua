local config = require "octo.config"
local constants = require "octo.constants"
local utils = require "octo.utils"
local M = {}

local namespace = vim.api.nvim_create_namespace "octo_attachments"
local signature = "\137PNG\r\n\26\n"
local max_size = 10 * 1024 * 1024
local api_host = "github.com"
local api_base = "https://api.github.com"

---@class octo.AttachmentTarget
---@field buffer OctoBuffer
---@field metadata BodyMetadata|CommentMetadata
---@field anchor integer
---@field changedtick integer

---@param name string
---@param mime string
---@param repo_id string
---@return string
function M.upload_query(name, mime, repo_id)
  return "content_type="
    .. vim.uri_encode(mime, "rfc2396")
    .. "&name="
    .. vim.uri_encode(name, "rfc2396")
    .. "&repository_id="
    .. repo_id
end

---@param url string?
---@return boolean
function M.valid_attachment_url(url)
  return type(url) == "string" and url:match "^https://github%.com/user%-attachments/assets/[%w%-]+$" ~= nil
end

local function effective_host()
  local host = config.values.github_hostname
  if utils.is_blank(host) then
    host = utils.get_remote_host() or api_host
  end
  return host
end

---@param path string
---@return boolean?, string?
local function read_png(path)
  local file = io.open(path, "rb")
  if not file then
    return nil, "Cannot read image file"
  end
  local bytes = file:read(8)
  local size = file:seek "end"
  file:close()
  if not size or size == 0 or size > max_size then
    return nil, "PNG must be non-empty and no larger than 10 MiB"
  end
  if bytes ~= signature then
    return nil, "File does not have the PNG signature"
  end
  return true
end

---@param args string[]
---@param callback fun(output: string?, err?: string)
local function run_gh(args, callback)
  local env = config.values.gh_env
  if type(env) == "function" then
    ---@type boolean, table<string, string|integer>
    local env_ok, configured_env = pcall(env)
    if not env_ok then
      callback(nil, tostring(configured_env))
      return
    end
    env = configured_env
  end
  local start_ok, start_err = pcall(
    vim.system,
    vim.list_extend({ config.values.gh_cmd }, args),
    { text = true, env = env },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        local message = result.stderr ~= "" and result.stderr or result.stdout or "GitHub CLI request failed"
        callback(nil, message:gsub("%s+$", ""))
      else
        callback(result.stdout)
      end
    end)
  )
  if not start_ok then
    callback(nil, tostring(start_err))
  end
end

---@param value string
---@param label string
---@return {id?: number|string, data?: {repository?: {viewerPermission?: string}}, url?: string}?, string?
local function decode_object(value, label)
  local ok, decoded = pcall(vim.json.decode, value)
  if not ok or type(decoded) ~= "table" then
    return nil, "GitHub returned malformed " .. label .. " JSON"
  end
  return decoded
end

---@param path string
---@param repo string
---@param callback fun(url: string?, err?: string)
function M.upload(path, repo, callback)
  local host = effective_host()
  if host ~= api_host then
    callback(nil, "Image attachments require github.com; GitHub Enterprise is unsupported")
    return
  end
  local owner, name = repo:match "^([%w_.-]+)/([%w_.-]+)$"
  if not owner or not name then
    callback(nil, "Image attachment requires a repository in owner/name format")
    return
  end
  local ok, err = read_png(path)
  if not ok then
    callback(nil, err)
    return
  end

  run_gh(
    { "api", "--hostname", api_host, api_base .. "/repos/" .. owner .. "/" .. name },
    function(repo_output, repo_err)
      if not repo_output then
        callback(nil, repo_err)
        return
      end
      local repo_data, decode_err = decode_object(repo_output, "repository")
      if not repo_data then
        callback(nil, decode_err)
        return
      end
      local repo_id = tonumber(repo_data.id)
      if not repo_id then
        callback(nil, "GitHub did not return a repository ID")
        return
      end

      local permission_query =
        string.format("query { repository(owner: %q, name: %q) { viewerPermission } }", owner, name)
      run_gh(
        { "api", "--hostname", api_host, api_base .. "/graphql", "-f", "query=" .. permission_query },
        function(permission_output, permission_err)
          if not permission_output then
            callback(nil, permission_err)
            return
          end
          local permission_data, permission_decode_err = decode_object(permission_output, "permission")
          if not permission_data then
            callback(nil, permission_decode_err)
            return
          end
          local permission_root = permission_data.data
          local repository = type(permission_root) == "table" and permission_root.repository or nil
          if type(repository) ~= "table" or type(repository.viewerPermission) ~= "string" then
            callback(nil, "GitHub returned malformed permission JSON")
            return
          end
          local permission = repository.viewerPermission
          if permission ~= "WRITE" and permission ~= "ADMIN" and permission ~= "MAINTAIN" then
            callback(nil, "Image upload requires WRITE, MAINTAIN, or ADMIN repository permission")
            return
          end

          local upload_url = "https://uploads.github.com/user-attachments/assets?"
            .. M.upload_query(vim.fs.basename(path), "image/png", tostring(repo_id))
          run_gh({
            "api",
            "--hostname",
            api_host,
            "--method",
            "POST",
            upload_url,
            "--input",
            path,
            "--header",
            "Content-Type: application/octet-stream",
            "--header",
            "Accept: application/vnd.github+json",
          }, function(response, upload_err)
            if not response then
              callback(nil, upload_err)
              return
            end
            local decoded, response_decode_err = decode_object(response, "upload")
            if not decoded then
              callback(nil, response_decode_err)
              return
            end
            if not M.valid_attachment_url(decoded.url) then
              callback(nil, "GitHub returned an unexpected image attachment URL")
              return
            end
            callback(decoded.url)
          end)
        end
      )
    end
  )
end

---@param buffer OctoBuffer
---@param metadata BodyMetadata|CommentMetadata
---@return boolean
local function metadata_is_editable(buffer, metadata)
  if not vim.api.nvim_buf_is_valid(buffer.bufnr) or not vim.api.nvim_buf_is_loaded(buffer.bufnr) then
    return false
  end
  if not vim.bo[buffer.bufnr].modifiable or not buffer.ready or metadata.viewerCanUpdate ~= true then
    return false
  end
  if buffer.bodyMetadata ~= metadata and not vim.tbl_contains(buffer.commentsMetadata or {}, metadata) then
    return false
  end
  if type(metadata.extmark) ~= "number" then
    return false
  end
  local mark = vim.api.nvim_buf_get_extmark_by_id(buffer.bufnr, constants.OCTO_COMMENT_NS, metadata.extmark, {
    details = true,
  })
  return #mark == 3 and type(mark[3].end_row) == "number"
end

---@param bufnr integer
---@param metadata BodyMetadata|CommentMetadata
---@param row integer
---@param col integer
---@return boolean
local function insertion_is_in_metadata(bufnr, metadata, row, col)
  local mark =
    vim.api.nvim_buf_get_extmark_by_id(bufnr, constants.OCTO_COMMENT_NS, metadata.extmark, { details = true })
  if #mark ~= 3 then
    return false
  end
  local first_row, last_row = utils.get_extmark_region(bufnr, mark)
  local start_row, start_col = mark[1], mark[2]
  local end_row, end_col = mark[3].end_row, mark[3].end_col
  if first_row == nil or last_row == nil or row < first_row or row > last_row then
    return false
  end
  if row == start_row and col < start_col then
    return false
  end
  if row == end_row and col > end_col then
    return false
  end
  return true
end

---@param target octo.AttachmentTarget
---@param check_changedtick boolean
---@return boolean
local function target_is_valid(target, check_changedtick)
  local buffer = target.buffer
  local bufnr = buffer.bufnr
  if not _G.octo_buffers or _G.octo_buffers[bufnr] ~= buffer or not metadata_is_editable(buffer, target.metadata) then
    return false
  end
  local position = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, target.anchor, {})
  if #position == 0 or not insertion_is_in_metadata(bufnr, target.metadata, position[1], position[2]) then
    return false
  end
  return not check_changedtick or vim.api.nvim_buf_get_changedtick(bufnr) == target.changedtick
end

---@param buffer OctoBuffer
---@param metadata BodyMetadata|CommentMetadata
---@return octo.AttachmentTarget?
function M.capture_target(buffer, metadata)
  if not metadata_is_editable(buffer, metadata) then
    return nil
  end
  if vim.api.nvim_get_current_buf() ~= buffer.bufnr then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  if not insertion_is_in_metadata(buffer.bufnr, metadata, row, col) then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(buffer.bufnr, row, row + 1, false)[1]
  col = math.min(col, #line)
  local anchor = vim.api.nvim_buf_set_extmark(buffer.bufnr, namespace, row, col, { right_gravity = true })
  return {
    buffer = buffer,
    metadata = metadata,
    anchor = anchor,
    changedtick = vim.api.nvim_buf_get_changedtick(buffer.bufnr),
  }
end

---@param target octo.AttachmentTarget
---@param url string
---@return boolean
function M.insert_at_target(target, url)
  if not target_is_valid(target, true) then
    return false
  end
  local buffer = target.buffer
  local position = vim.api.nvim_buf_get_extmark_by_id(buffer.bufnr, namespace, target.anchor, {})
  vim.api.nvim_buf_set_text(
    buffer.bufnr,
    position[1],
    position[2],
    position[1],
    position[2],
    { "![image](" .. url .. ")" }
  )
  vim.api.nvim_buf_del_extmark(buffer.bufnr, namespace, target.anchor)
  buffer:update_metadata()
  return true
end

---@param callback fun(path: string?)
local function choose_file(callback)
  if config.values.picker == "fzf-lua" then
    local ok, fzf = pcall(require, "fzf-lua")
    if ok then
      local selected = false
      local options = {
        prompt = "Select PNG image> ",
        actions = {
          default = function(entries, picker_opts)
            if not entries or not entries[1] then
              return
            end
            selected = true
            local parsed, entry = pcall(fzf.path.entry_to_file, entries[1], picker_opts)
            local path = parsed and type(entry.path) == "string" and vim.fn.fnamemodify(entry.path, ":p") or nil
            callback(path)
          end,
          ["esc"] = function()
            callback(nil)
          end,
        },
        winopts = {
          on_close = function()
            vim.schedule(function()
              if not selected then
                callback(nil)
              end
            end)
          end,
        },
      }
      if pcall(fzf.files, options) then
        return
      end
    end
  end
  local function browse(directory)
    local choices = { "../" }
    for name, kind in vim.fs.dir(directory) do
      if kind == "directory" or name:lower():match "%.png$" then
        choices[#choices + 1] = (kind == "directory" and "[dir] " or "") .. name
      end
    end
    table.sort(choices)
    vim.ui.select(choices, { prompt = "Select PNG (directories navigate):" }, function(choice)
      if not choice then
        callback(nil)
        return
      end
      local name = choice:gsub("^%[dir%] ", "")
      local path = vim.fs.normalize(directory .. "/" .. name)
      if choice:match "^%[dir%] " or choice == "../" then
        browse(path)
      else
        callback(path)
      end
    end)
  end
  browse(vim.fn.getcwd())
end

---@param buffer OctoBuffer
---@param source "file"|"clipboard"
local function attach(buffer, source)
  local lookup_ok, metadata = pcall(function()
    return buffer:get_body_at_cursor() or buffer:get_comment_at_cursor()
  end)
  if not lookup_ok or not metadata then
    utils.error "Place the cursor inside an editable issue/PR description or comment"
    return
  end
  local target = M.capture_target(buffer, metadata)
  if not target then
    utils.error "Image attachment requires a loaded, modifiable Octo body or comment that you can edit"
    return
  end
  local finished = false
  ---@param url string?
  ---@param err? string
  ---@param temp_path? string
  local function finish(url, err, temp_path)
    if finished then
      return
    end
    finished = true
    if temp_path then
      os.remove(temp_path)
    end
    if not url then
      pcall(vim.api.nvim_buf_del_extmark, buffer.bufnr, namespace, target.anchor)
      if err then
        utils.error(err)
      end
      return
    end
    if not M.insert_at_target(target, url) then
      pcall(vim.api.nvim_buf_del_extmark, buffer.bufnr, namespace, target.anchor)
      utils.error "Image uploaded but its Markdown could not be inserted; remote asset may be orphaned"
    else
      utils.info "Image Markdown inserted; write the Octo buffer to save it"
    end
  end
  ---@param path string?
  ---@param temp_path? string
  local function upload(path, temp_path)
    if not path then
      finish(nil, nil, temp_path)
      return
    end
    if not target_is_valid(target, true) then
      finish(nil, "Octo edit target changed or became unavailable; image was not uploaded", temp_path)
      return
    end
    M.upload(path, buffer.repo, function(url, err)
      finish(url, err, temp_path)
    end)
  end
  if source == "file" then
    choose_file(function(path)
      upload(path)
    end)
    return
  end
  ---@type boolean, {save_image_async: fun(path: string, callback: fun(saved: boolean))}
  local ok, clipboard = pcall(require, "img-clip.clipboard")
  if not ok or type(clipboard.save_image_async) ~= "function" then
    finish(nil, "Clipboard image paste requires img-clip.nvim with async PNG capture support")
    return
  end
  local path = vim.fn.tempname() .. ".png"
  local uv = vim.uv or vim.loop
  local fd = uv.fs_open(path, "wx", 384)
  if not fd then
    finish(nil, "Could not create a private temporary image file")
    return
  end
  uv.fs_close(fd)
  ---@type boolean, string?
  local capture_ok, capture_err = pcall(
    clipboard.save_image_async,
    path,
    vim.schedule_wrap(function(saved)
      if not saved then
        finish(nil, "Clipboard does not contain a PNG image or clipboard capture failed", path)
        return
      end
      upload(path, path)
    end)
  )
  if not capture_ok then
    finish(nil, tostring(capture_err), path)
  end
end

function M.paste_clipboard()
  local buffer = utils.get_current_buffer()
  if buffer and (buffer:isIssue() or buffer:isPullRequest()) then
    attach(buffer, "clipboard")
  end
end

function M.pick_file()
  local buffer = utils.get_current_buffer()
  if buffer and (buffer:isIssue() or buffer:isPullRequest()) then
    attach(buffer, "file")
  end
end

return M
