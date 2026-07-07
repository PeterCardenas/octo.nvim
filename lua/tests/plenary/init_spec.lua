---@diagnostic disable

describe("Octo module:", function()
  local octo
  local gh
  local polling
  local original_get
  local original_graphql
  local original_track_buffer
  local original_octo_buffers
  local created_buffers

  before_each(function()
    package.loaded["octo"] = nil
    octo = require "octo"
    gh = require "octo.gh"
    polling = require "octo.polling"
    original_get = gh.api.get
    original_graphql = gh.api.graphql
    original_track_buffer = polling.track_buffer
    original_octo_buffers = _G.octo_buffers
    created_buffers = {}
  end)

  after_each(function()
    gh.api.get = original_get
    gh.api.graphql = original_graphql
    polling.track_buffer = original_track_buffer
    _G.octo_buffers = original_octo_buffers
    for _, bufnr in ipairs(created_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end)

  local function create_named_buffer(name)
    local bufnr = vim.api.nvim_create_buf(false, true)
    table.insert(created_buffers, bufnr)
    vim.api.nvim_buf_set_name(bufnr, name)
    vim.api.nvim_set_current_buf(bufnr)
    return bufnr
  end

  it("navigates to numeric URL anchors", function()
    local received
    local octo_buffer = {
      navigate_to_comment = function(_, opts)
        received = opts
      end,
    }

    assert.has_no.errors(function()
      octo.navigate_to_anchor(octo_buffer, 3185672857)
    end)
    assert.are.same({ databaseId = 3185672857 }, received)
  end)

  it("loads pull request diff buffers from octo URIs", function()
    local graphql_opts
    local get_opts
    local tracked_bufnr
    local bufnr = create_named_buffer "octo://owner/repo/pull/7/diff"

    gh.api.graphql = function(opts)
      graphql_opts = opts
      opts.opts.cb(
        vim.json.encode {
          data = {
            repository = {
              pullRequest = {
                title = "Add descriptive pull diff titles",
                updatedAt = "2026-07-02T00:00:00Z",
                baseRefOid = "base",
                headRefOid = "head",
              },
            },
          },
        },
        nil
      )
    end
    gh.api.get = function(opts)
      get_opts = opts
      opts.opts.cb("diff --git a/file.lua b/file.lua\n@@ -1 +1 @@\n-old\n+new", nil)
    end
    polling.track_buffer = function(value)
      tracked_bufnr = value
    end

    octo.load_buffer { bufnr = bufnr }

    assert.are.same({ owner = "owner", name = "repo", number = 7 }, graphql_opts.F)
    assert.are.same("/repos/{repo}/pulls/{number}", get_opts[1])
    assert.are.same({ repo = "owner/repo", number = "7" }, get_opts.format)
    assert.are.same("base...head", _G.octo_buffers[bufnr]:get_diff_fingerprint())
    assert.are.same("diff", vim.bo[bufnr].filetype)
    assert.are.same(false, vim.bo[bufnr].modifiable)
    assert.are.same(true, vim.bo[bufnr].readonly)
    assert.are.same(false, vim.bo[bufnr].modified)
    assert.are.same("pull_diff", _G.octo_buffers[bufnr].kind)
    assert.are.same("owner/repo", _G.octo_buffers[bufnr].repo)
    assert.are.same(7, _G.octo_buffers[bufnr].number)
    assert.are.same("Add descriptive pull diff titles", _G.octo_buffers[bufnr].titleMetadata.body)
    assert.are.same(tracked_bufnr, bufnr)
    assert.are.same({
      "diff --git a/file.lua b/file.lua",
      "@@ -1 +1 @@",
      "-old",
      "+new",
    }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("passes hostname when loading pull request diff buffers", function()
    local graphql_opts
    local get_opts
    local bufnr = create_named_buffer "octo://github.enterprise.com/owner/repo/pull/7/diff"

    gh.api.graphql = function(opts)
      graphql_opts = opts
      opts.opts.cb(
        vim.json.encode {
          data = {
            repository = {
              pullRequest = {
                baseRefOid = "base",
                headRefOid = "head",
              },
            },
          },
        },
        nil
      )
    end
    gh.api.get = function(opts)
      get_opts = opts
      opts.opts.cb("", nil)
    end
    polling.track_buffer = function() end

    octo.load_buffer { bufnr = bufnr }

    assert.are.same("github.enterprise.com", graphql_opts.opts.hostname)
    assert.are.same("github.enterprise.com", get_opts.opts.hostname)
  end)
end)
