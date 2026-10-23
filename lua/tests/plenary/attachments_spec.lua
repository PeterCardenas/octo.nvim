describe("octo.attachments", function()
  local attachments = require "octo.attachments"
  local config = require "octo.config"
  local original_system = vim.system
  local original_remote_host = require("octo.utils").get_remote_host
  local original_buffers = _G.octo_buffers
  local original_select = vim.ui.select
  local original_picker = config.values.picker
  local original_fzf = package.loaded["fzf-lua"]

  local function create_png(path)
    local file = assert(io.open(path, "wb"))
    file:write("\137PNG\r\n\26\n", "synthetic")
    file:close()
  end

  local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then
      return false
    end
    file:close()
    return true
  end

  local function install_transport()
    ---@type {argv: string[], opts: vim.SystemOpts}[]
    local calls = {}
    ---@type fun(result: vim.SystemCompleted)[]
    local completions = {}
    vim.system = function(argv, opts, callback)
      calls[#calls + 1] = { argv = argv, opts = opts }
      completions[#completions + 1] = callback
      return { kill = function() end }
    end
    return calls, completions
  end

  local function send(completions, index, output, code, stderr)
    completions[index] { code = code or 0, stdout = output or "", stderr = stderr or "" }
  end

  local function make_buffer()
    local constants = require "octo.constants"
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "title", "", "body", "", "tail" })
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_win_set_cursor(0, { 3, 1 })
    local metadata = {
      viewerCanUpdate = true,
      body = "body",
      savedBody = "body",
      dirty = false,
    }
    metadata.extmark = vim.api.nvim_buf_set_extmark(bufnr, constants.OCTO_COMMENT_NS, 0, 0, {
      end_row = 4,
      end_col = 0,
    })
    local node = {}
    local buffer = require("octo.model.octo-buffer").OctoBuffer:new {
      bufnr = bufnr,
      number = 1,
      repo = "owner/repo",
      kind = "issue",
      node = node,
      commentsMetadata = {},
      threadsMetadata = {},
    }
    buffer.ready = true
    buffer.bodyMetadata = metadata
    buffer.get_body_at_cursor = function(self)
      return self.bodyMetadata
    end
    buffer.get_comment_at_cursor = function()
      return nil
    end
    buffer.update_metadata = function() end
    _G.octo_buffers = { [bufnr] = buffer }
    return buffer
  end

  local function no_remote_host()
    return nil
  end

  before_each(function()
    original_system = vim.system
    original_remote_host = require("octo.utils").get_remote_host
    original_buffers = _G.octo_buffers
    config.values.github_hostname = ""
    config.values.gh_env = {}
    require("octo.utils").get_remote_host = no_remote_host
  end)

  after_each(function()
    vim.system = original_system
    require("octo.utils").get_remote_host = original_remote_host
    config.values.github_hostname = ""
    _G.octo_buffers = original_buffers
    config.values.picker = original_picker
    vim.ui.select = original_select
    package.loaded["fzf-lua"] = original_fzf
  end)

  it("encodes upload query values", function()
    local query = attachments.upload_query("a & # ü.png", "image/png", "123")
    assert.is_truthy(query:find("name=a%20%26%20%23%20", 1, true))
    assert.is_truthy(query:lower():find("content_type=image%2fpng", 1, true))
    assert.is_truthy(query:find("repository_id=123", 1, true))
  end)

  it("accepts only the stable GitHub attachment URL", function()
    assert.is_true(attachments.valid_attachment_url "https://github.com/user-attachments/assets/a1b2")
    assert.is_false(attachments.valid_attachment_url "http://github.com/user-attachments/assets/a1b2")
    assert.is_false(attachments.valid_attachment_url "https://evil.example/user-attachments/assets/a1b2")
    assert.is_false(attachments.valid_attachment_url "https://github.com/user-attachments/redirect/a1b2")
  end)

  it("uses github.com when the plugin hostname is the default empty value", function()
    local calls, completions = install_transport()
    local path = vim.fn.tempname() .. ".png"
    create_png(path)
    local done, url = false, nil
    attachments.upload(path, "owner/repo", function(asset_url)
      url, done = asset_url, true
    end)
    assert.is_false(done)
    assert.are.equal(1, #calls)
    assert.is_truthy(table.concat(calls[1].argv, " "):find("--hostname github.com", 1, true))
    assert.is_truthy(table.concat(calls[1].argv, " "):find("https://api.github.com/repos/owner/repo", 1, true))
    send(completions, 1, '{"id":123}')
    assert.is_true(vim.wait(1000, function()
      return #calls == 2
    end))
    assert.is_truthy(table.concat(calls[2].argv, " "):find("--hostname github.com", 1, true))
    send(completions, 2, '{"data":{"repository":{"viewerPermission":"WRITE"}}}')
    assert.is_true(vim.wait(1000, function()
      return #calls == 3
    end))
    assert.is_truthy(table.concat(calls[3].argv, " "):find("--hostname github.com", 1, true))
    send(completions, 3, '{"url":"https://github.com/user-attachments/assets/abc"}')
    assert.is_true(vim.wait(1000, function()
      return done
    end))
    assert.are.equal("https://github.com/user-attachments/assets/abc", url)
    os.remove(path)
  end)

  it("rejects a GHES host before any request", function()
    config.values.github_hostname = "ghe.example.com"
    local calls = install_transport()
    local path = vim.fn.tempname() .. ".png"
    create_png(path)
    local error_message = ""
    attachments.upload(path, "owner/repo", function(_, err)
      error_message = assert(err)
    end)
    assert.are.equal(0, #calls)
    assert.is_truthy(error_message:find("GitHub Enterprise", 1, true))
    os.remove(path)
  end)

  it("rejects a non-editable metadata target and a deleted metadata extmark", function()
    local buffer = make_buffer()
    local target = attachments.capture_target(buffer, buffer.bodyMetadata)
    assert(target)
    buffer.bodyMetadata.viewerCanUpdate = false
    assert.is_false(attachments.insert_at_target(target, "https://github.com/user-attachments/assets/abc"))
    buffer.bodyMetadata.viewerCanUpdate = true
    vim.api.nvim_buf_del_extmark(buffer.bufnr, require("octo.constants").OCTO_COMMENT_NS, buffer.bodyMetadata.extmark)
    assert.is_false(attachments.insert_at_target(target, "https://github.com/user-attachments/assets/abc"))
    vim.api.nvim_buf_delete(buffer.bufnr, { force = true })
  end)

  it("preserves insertion target across active-buffer changes without saving", function()
    local buffer = make_buffer()
    local target = assert(attachments.capture_target(buffer, buffer.bodyMetadata))
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(other)
    local saved = false
    assert.is_true(attachments.insert_at_target(target, "https://github.com/user-attachments/assets/abc"))
    assert.is_false(saved)
    assert.is_truthy(vim.api.nvim_buf_get_lines(buffer.bufnr, 0, -1, false)[3]:find "user%-attachments/assets/abc")
    vim.api.nvim_buf_delete(buffer.bufnr, { force = true })
    vim.api.nvim_buf_delete(other, { force = true })
  end)

  it("rejects insertion when text changes while a picker is open", function()
    local buffer = make_buffer()
    local target = assert(attachments.capture_target(buffer, buffer.bodyMetadata))
    vim.api.nvim_buf_set_lines(buffer.bufnr, 2, 3, false, { "changed" })
    local utils = require "octo.utils"
    local original_error = utils.error
    utils.error = function() end
    local inserted = attachments.insert_at_target(target, "https://github.com/user-attachments/assets/abc")
    utils.error = original_error
    assert.is_false(inserted)
    vim.api.nvim_buf_delete(buffer.bufnr, { force = true })
  end)

  it("rejects malformed repository and permission responses", function()
    local path = vim.fn.tempname() .. ".png"
    create_png(path)
    for i, invalid in ipairs { "not-json", '{"data": []}' } do
      local calls, completions = install_transport()
      local done, err = false, nil
      attachments.upload(path, "owner/repo", function(_, message)
        err, done = message, true
      end)
      send(completions, 1, i == 1 and invalid or '{"id":123}')
      assert.is_true(vim.wait(1000, function()
        return i == 1 and done or #calls == 2
      end))
      if i == 2 then
        send(completions, 2, invalid)
        assert.is_true(vim.wait(1000, function()
          return done
        end))
      end
      assert.is_truthy(assert(err):find("malformed", 1, true))
      assert.are.equal(i, #calls)
    end
    os.remove(path)
  end)

  it("uses the regular selection picker and cleans the anchor on cancellation", function()
    config.values.picker = "fzf-lua"
    local file_picker_calls = 0
    package.loaded["fzf-lua"] = {
      files = function()
        file_picker_calls = file_picker_calls + 1
      end,
    }
    local selected = false
    vim.ui.select = function(_, _, callback)
      selected = true
      callback(nil)
    end
    local buffer = make_buffer()
    local calls = install_transport()
    attachments.pick_file()
    assert.is_true(selected)
    assert.are.equal(0, file_picker_calls)
    assert.are.equal(0, #calls)
    local ns = vim.api.nvim_get_namespaces().octo_attachments
    assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(buffer.bufnr, ns, 0, -1, {}))
    vim.api.nvim_buf_delete(buffer.bufnr, { force = true })
  end)

  it("navigates directories, filters PNGs, and inserts only after mocked upload completes", function()
    local buffer = make_buffer()
    local calls, completions = install_transport()
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory .. "/images", "p")
    local path = directory .. "/images/shot.PNG"
    create_png(path)
    create_png(directory .. "/ignored.txt")
    local original_cwd = vim.fn.getcwd()
    vim.fn.chdir(directory)
    local selections = 0
    vim.ui.select = function(choices, _, callback)
      selections = selections + 1
      if selections == 1 then
        assert.are.same({ "../", "[dir] images" }, choices)
        callback "[dir] images"
      else
        assert.are.same({ "../", "shot.PNG" }, choices)
        callback "shot.PNG"
      end
    end
    attachments.pick_file()
    vim.fn.chdir(original_cwd)
    assert.are.equal(2, selections)
    assert.are.equal(1, #calls)
    assert.is_nil(vim.api.nvim_buf_get_lines(buffer.bufnr, 2, 3, false)[1]:find "user%-attachments")
    send(completions, 1, '{"id":123}')
    assert.is_true(vim.wait(1000, function()
      return #calls == 2
    end))
    send(completions, 2, '{"data":{"repository":{"viewerPermission":"WRITE"}}}')
    assert.is_true(vim.wait(1000, function()
      return #calls == 3
    end))
    send(completions, 3, '{"url":"https://github.com/user-attachments/assets/abc"}')
    assert.is_true(vim.wait(1000, function()
      return vim.api.nvim_buf_get_lines(buffer.bufnr, 2, 3, false)[1]:find "user%-attachments/assets/abc" ~= nil
    end))
    assert.are.equal(3, #calls)
    vim.fn.delete(directory, "rf")
    vim.api.nvim_buf_delete(buffer.bufnr, { force = true })
  end)

  it("reports a failed upload response without returning an asset URL", function()
    local calls, completions = install_transport()
    local path = vim.fn.tempname() .. ".png"
    create_png(path)
    local done, err = false, nil
    attachments.upload(path, "owner/repo", function(_, message)
      err, done = message, true
    end)
    send(completions, 1, '{"id":123}')
    assert.is_true(vim.wait(1000, function()
      return #calls == 2
    end))
    send(completions, 2, '{"data":{"repository":{"viewerPermission":"WRITE"}}}')
    assert.is_true(vim.wait(1000, function()
      return #calls == 3
    end))
    send(completions, 3, "", 1, "upload rejected")
    assert.is_true(vim.wait(1000, function()
      return done
    end))
    assert.are.equal("upload rejected", err)
    os.remove(path)
  end)

  it("cleans the private clipboard file after an async upload failure", function()
    local original_clipboard = package.loaded["img-clip.clipboard"]
    local original_info = require("octo.utils").info
    local original_error = require("octo.utils").error
    local path = ""
    package.loaded["img-clip.clipboard"] = {
      save_image_async = function(temp_path, callback)
        path = temp_path
        create_png(path)
        callback(true)
      end,
    }
    require("octo.utils").info = function() end
    require("octo.utils").error = function() end
    local buffer = make_buffer()
    local calls, completions = install_transport()
    attachments.paste_clipboard()
    assert.is_true(vim.wait(1000, function()
      return #calls == 1
    end))
    assert.is_true(file_exists(path))
    send(completions, 1, "", 1, "repository request failed")
    assert.is_true(vim.wait(1000, function()
      return not file_exists(path)
    end))
    require("octo.utils").info = original_info
    require("octo.utils").error = original_error
    package.loaded["img-clip.clipboard"] = original_clipboard
    vim.api.nvim_buf_delete(buffer.bufnr, { force = true })
  end)

  it("keeps the private clipboard file until async upload completion, then cleans it", function()
    local original_clipboard = package.loaded["img-clip.clipboard"]
    local original_info = require("octo.utils").info
    local original_notify_error = require("octo.utils").error
    local path = ""
    package.loaded["img-clip.clipboard"] = {
      save_image_async = function(temp_path, callback)
        path = temp_path
        create_png(path)
        callback(true)
      end,
    }
    require("octo.utils").info = function() end
    require("octo.utils").error = function() end
    local buffer = make_buffer()
    local calls, completions = install_transport()
    attachments.paste_clipboard()
    assert.is_truthy(path)
    assert.is_true(file_exists(path))
    assert.is_true(vim.wait(1000, function()
      return #calls == 1
    end))
    send(completions, 1, '{"id":123}')
    assert.is_true(vim.wait(1000, function()
      return #calls == 2
    end))
    send(completions, 2, '{"data":{"repository":{"viewerPermission":"WRITE"}}}')
    assert.is_true(vim.wait(1000, function()
      return #calls == 3
    end))
    send(completions, 3, '{"url":"https://github.com/user-attachments/assets/abc"}')
    assert.is_true(vim.wait(1000, function()
      return not file_exists(path)
    end))
    assert.is_truthy(vim.api.nvim_buf_get_lines(buffer.bufnr, 2, 3, false)[1]:find "user%-attachments/assets/abc")
    require("octo.utils").info = original_info
    require("octo.utils").error = original_notify_error
    package.loaded["img-clip.clipboard"] = original_clipboard
    vim.api.nvim_buf_delete(buffer.bufnr, { force = true })
  end)
end)
