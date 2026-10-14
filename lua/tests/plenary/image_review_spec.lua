---@diagnostic disable
local FileEntry = require("octo.reviews.file-entry").FileEntry
local reviews = require "octo.reviews"
local utils = require "octo.utils"
local gh = require "octo.gh"
local eq = assert.are.same
local bytes = "\137PNG\r\n\26\n\0\255\r\nimage\0"

local function read_bytes(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read "*a"
  file:close()
  return content
end

describe("automatic image reviews", function()
  local original_reviews, original_snacks, original_get, original_text, original_system
  local files, requests, rendered, cleaned

  before_each(function()
    original_reviews, original_snacks = reviews.reviews, _G.Snacks
    original_get, original_text, original_system = gh.api.get, utils.get_file_contents, vim.system
    files, requests, rendered, cleaned = {}, {}, {}, {}
    reviews.reviews = {
      [tostring(vim.api.nvim_get_current_tabpage())] = {
        threads = {},
        get_level = function()
          return "PR"
        end,
        layout = {
          left = {
            commit = "left_sha",
            abbrev = function()
              return "left"
            end,
          },
          right = {
            commit = "right_sha",
            abbrev = function()
              return "right"
            end,
          },
          on_win_leave = function() end,
          on_win_enter = function() end,
          on_buf_enter = function() end,
        },
      },
    }
    _G.Snacks = {
      image = {
        config = { enabled = true },
        supports_file = function(path)
          return path:match "%.png$" ~= nil
        end,
        terminal = {
          detect = function(cb)
            cb()
          end,
        },
        supports_terminal = function()
          return true
        end,
        placement = {
          new = function(buf, path)
            rendered[buf] = path
          end,
          clean = function(buf)
            cleaned[buf] = true
          end,
        },
      },
    }
    utils.get_file_contents = function(_, _, _, cb)
      cb { "text" }
    end
    gh.api.get = function(opts)
      requests[#requests + 1] = opts[1]
      opts.opts.cb(vim.json.encode { encoding = "base64", content = vim.base64.encode(bytes), sha = "blob_sha" }, "", 0)
    end
  end)

  after_each(function()
    for _, file in ipairs(files) do
      file:destroy()
      for _, path in ipairs { file.left_image_path or "", file.right_image_path or "" } do
        if path ~= "" then
          vim.fn.delete(path)
        end
      end
    end
    reviews.reviews, _G.Snacks = original_reviews, original_snacks
    vim.cmd "silent! only!"
    gh.api.get, utils.get_file_contents, vim.system = original_get, original_text, original_system
  end)

  local function make_file(status, path)
    local file = FileEntry:new {
      path = path or "images/a #?.png",
      previous_path = "images/old.png",
      pull_request = { repo = "owner/repo", local_left = false, local_right = false, files = {} },
      status = status or "M",
      stats = { additions = 0, deletions = 0, changes = 0 },
    }
    files[#files + 1] = file
    return file
  end

  it("fetches both revisions as bytes and escapes GitHub paths", function()
    local file = make_file()
    eq(true, file:fetch(true))
    assert.is_not_nil(file.left_image_path)
    assert.is_not_nil(file.right_image_path)
    eq(bytes, read_bytes(file.left_image_path))
    eq(bytes, read_bytes(file.right_image_path))
    eq({
      "/repos/owner/repo/contents/images/a%20%23%3F.png?ref=right_sha",
      "/repos/owner/repo/contents/images/a%20%23%3F.png?ref=left_sha",
    }, requests)
    eq(2, #requests)
    eq(true, file:fetch(true))
    eq(2, #requests)
  end)

  it("renders the two images without enabling text diff and cleans placements", function()
    local file = make_file()
    file:fetch(true)
    local left = vim.api.nvim_get_current_win()
    vim.cmd "vsplit"
    local right = vim.api.nvim_get_current_win()
    file:load_buffers(left, right)
    eq(file.left_image_path, rendered[file.left_bufid])
    eq(file.right_image_path, rendered[file.right_bufid])
    eq("image", vim.bo[file.left_bufid].filetype)
    eq(false, vim.wo[left].diff)
    eq(false, vim.wo[right].diff)
    eq(false, vim.bo[file.left_bufid].modifiable)
    file:detach_buffers()
    eq(true, cleaned[file.left_bufid])
    eq(true, cleaned[file.right_bufid])
    file:load_buffers(left, right)
    eq(file.left_image_path, rendered[file.left_bufid])
  end)

  it("does not request the missing side of additions or deletions", function()
    for _, status in ipairs { "A", "D" } do
      requests = {}
      local file = make_file(status)
      eq(true, file:fetch(true))
      eq(1, #requests)
      if status == "A" then
        eq(nil, file.left_image_path)
        eq({ "Image added (no previous version)" }, file.left_lines)
      else
        eq(nil, file.right_image_path)
        eq({ "Image deleted" }, file.right_lines)
      end
    end
  end)

  it("uses the previous path for renamed images", function()
    local file = make_file "R"
    file:fetch(true)
    eq("/repos/owner/repo/contents/images/old.png?ref=left_sha", requests[2])
  end)

  it("finishes failed downloads with a visible error instead of timing out", function()
    gh.api.get = function(opts)
      opts.opts.cb("", "Not Found", 1)
    end
    local file = make_file()
    eq(true, file:fetch(true))
    eq(nil, file.left_image_path)
    assert.matches("Not Found", file.left_lines[1])
    eq(false, file.left_fetching)
    eq(false, file.right_fetching)
  end)

  it("preserves local binary bytes without text normalization", function()
    vim.system = function(command, options, cb)
      requests[#requests + 1] = command
      eq(nil, options.text)
      cb { code = 0, stdout = bytes, stderr = "" }
    end
    local file = make_file()
    file.pull_request.local_left, file.pull_request.local_right = true, true
    eq(true, file:fetch(true))
    eq(
      true,
      vim.wait(1000, function()
        return file:is_ready_to_render()
      end)
    )
    eq(bytes, read_bytes(file.left_image_path))
    eq({ "git", "show", "right_sha:images/a #?.png" }, requests[1])
  end)

  it("falls back to the blob API for images larger than the contents API inline limit", function()
    gh.api.get = function(opts)
      requests[#requests + 1] = opts[1]
      if opts[1]:find("/contents/", 1, true) then
        opts.opts.cb(vim.json.encode { encoding = "none", content = "", sha = "large_blob" }, "", 0)
      else
        opts.opts.cb(vim.json.encode { encoding = "base64", content = vim.base64.encode(bytes) }, "", 0)
      end
    end
    local file = make_file()
    eq(true, file:fetch(true))
    assert.is_not_nil(file.left_image_path)
    eq(bytes, read_bytes(file.left_image_path))
    eq("/repos/owner/repo/git/blobs/large_blob", requests[2])
  end)

  it("detaches the previous image before selecting another file", function()
    local layout = require("octo.reviews.layout").Layout:new {
      left = {},
      right = {},
      files = {},
    }
    local detached = {}
    local function entry(name)
      return {
        path = name,
        is_ready_to_render = function()
          return true
        end,
        detach_buffers = function()
          detached[#detached + 1] = name
        end,
        load_buffers = function() end,
      }
    end
    layout.files = { entry "old.png", entry "new.png" }
    layout.ensure_layout = function() end
    layout.file_safeguard = function()
      return false
    end
    layout.prefetch_nearby_files = function() end
    layout.file_panel = { mark_selected = function() end, set_cursor_to_file = function() end }
    layout.left_winid, layout.right_winid = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_win()
    layout:set_current_file(layout.files[2])
    eq({ "old.png" }, detached)
  end)

  it("does not render after terminal detection completes for a hidden buffer", function()
    local file = make_file()
    file:fetch(true)
    local complete_detection
    Snacks.image.terminal.detect = function(cb)
      complete_detection = cb
    end
    local left = vim.api.nvim_get_current_win()
    vim.cmd "vsplit"
    local right = vim.api.nvim_get_current_win()
    file:load_buffers(left, right)
    local hidden_buf = file.right_bufid
    vim.api.nvim_win_set_buf(right, vim.api.nvim_create_buf(false, true))
    complete_detection()
    eq(nil, rendered[hidden_buf])
  end)

  it("leaves ordinary text files and disabled image support on the existing path", function()
    local file = make_file("M", "a.lua")
    eq(true, file:fetch(true))
    eq({ "text" }, file.left_lines)
    eq(0, #requests)
    _G.Snacks.image.config.enabled = false
    file = make_file()
    eq(true, file:fetch(true))
    eq({ "text" }, file.right_lines)
    eq(0, #requests)
  end)
end)
