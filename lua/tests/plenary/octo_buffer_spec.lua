---@diagnostic disable

local constants = require "octo.constants"

describe("OctoBuffer:clear()", function()
  local OctoBuffer
  local original_octo_buffers
  local bufnr

  before_each(function()
    package.loaded["octo.model.octo-buffer"] = nil
    OctoBuffer = require("octo.model.octo-buffer").OctoBuffer
    original_octo_buffers = _G.octo_buffers
    _G.octo_buffers = {}
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    _G.octo_buffers = original_octo_buffers
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  it("carries the buffer hostname into pull-request review creation", function()
    local model = require "octo.model.pull-request"
    local original_create = model.create_with_merge_base
    local received_opts
    model.create_with_merge_base = function(opts)
      received_opts = opts
    end

    local buffer = OctoBuffer:new {
      bufnr = bufnr,
      number = 17,
      repo = "owner/repo",
      hostname = "github.enterprise.internal",
      kind = "pull",
      node = {
        id = "pr-node",
        number = 17,
        headRepository = { nameWithOwner = "owner/repo" },
        headRefName = "topic",
      },
    }
    buffer:get_pr(function() end)
    model.create_with_merge_base = original_create

    assert.are.same("github.enterprise.internal", received_opts.hostname)
  end)

  it("skips native completion metadata requests when disabled", function()
    local config = require "octo.config"
    local gh = require "octo.gh"
    local original_enabled = config.values.enable_native_completion
    local original_get = gh.api.get
    local calls = 0
    gh.api.get = function()
      calls = calls + 1
    end
    config.values.enable_native_completion = false
    local buffer = OctoBuffer:new { bufnr = bufnr }
    buffer.node = { participants = { nodes = {} } }
    buffer.repo = "owner/repo"
    buffer.commentsMetadata = {}
    local ok, err = pcall(function()
      buffer:async_fetch_taggable_users()
      buffer:async_fetch_issues()
      assert.are.equal(0, calls)
      config.values.enable_native_completion = true
      buffer:async_fetch_taggable_users()
      buffer:async_fetch_issues()
      assert.are.equal(2, calls)
    end)
    config.values.enable_native_completion = original_enabled
    gh.api.get = original_get
    assert.is_true(ok, err)
  end)

  it("sweeps extmarks placed in the shared comment virtual-text namespace", function()
    local buffer = OctoBuffer:new { bufnr = bufnr }
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line 1" })

    vim.api.nvim_buf_set_extmark(bufnr, constants.OCTO_COMMENT_VT_NS, 0, 0, {
      virt_text = { { "COMMENT: someone", "OctoUser" } },
      virt_text_pos = "overlay",
    })
    local before = vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_COMMENT_VT_NS, 0, -1, {})
    assert.are.equal(1, #before)

    buffer:clear()

    local after = vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_COMMENT_VT_NS, 0, -1, {})
    assert.are.equal(0, #after)
  end)

  it("sweeps extmarks placed in the shared thread namespace", function()
    local buffer = OctoBuffer:new { bufnr = bufnr }
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line 1" })

    vim.api.nvim_buf_set_extmark(bufnr, constants.OCTO_THREAD_NS, 0, 0, {
      end_row = 0,
      end_col = 0,
      hl_group = "OctoNvimCommentLine",
    })
    local before = vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_THREAD_NS, 0, -1, {})
    assert.are.equal(1, #before)

    buffer:clear()

    local after = vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_THREAD_NS, 0, -1, {})
    assert.are.equal(0, #after)
  end)
end)
