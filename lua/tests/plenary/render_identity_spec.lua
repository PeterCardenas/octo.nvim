---@diagnostic disable

local config = require "octo.config"
local octo = require "octo"
local polling = require "octo.polling"
local constants = require "octo.constants"
local utils = require "octo.utils"

local function make_comment(id, database_id)
  return {
    id = id,
    databaseId = database_id,
    author = { login = "author" },
    viewerDidAuthor = false,
    viewerCanUpdate = false,
    viewerCanDelete = false,
    createdAt = "2026-01-01T00:00:00Z",
    lastEditedAt = vim.NIL,
    body = "Body for " .. id,
    reactionGroups = {},
    replyTo = nil,
    includesCreatedEdit = false,
    replies = { totalCount = 0, nodes = {} },
  }
end

local function make_discussion(comments, count, load_state)
  return {
    _loadState = load_state,
    id = "discussion-id",
    number = 42,
    title = "Discussion",
    body = "Question",
    url = "https://github.com/owner/repo/discussions/42",
    author = { login = "author" },
    viewerDidAuthor = false,
    category = { name = "Ideas" },
    createdAt = "2026-01-01T00:00:00Z",
    updatedAt = "2026-01-02T00:00:00Z",
    closed = false,
    isAnswered = vim.NIL,
    labels = { nodes = {} },
    comments = { totalCount = count, nodes = comments },
    answer = vim.NIL,
    poll = vim.NIL,
    reactionGroups = {},
    viewerCanUpdate = false,
    lastEditedAt = vim.NIL,
    includesCreatedEdit = false,
  }
end

describe("render identity across progressive updates", function()
  local bufnr
  local original_load
  local original_track
  local original_cache_enabled
  local load_requests

  before_each(function()
    original_load = octo.load
    original_track = polling.track_buffer
    original_cache_enabled = config.values.persistent_cache.enabled
    config.values.persistent_cache.enabled = false
    polling.track_buffer = function() end
    load_requests = nil
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, "octo://owner/repo/discussion/42")
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    octo.load = original_load
    polling.track_buffer = original_track
    config.values.persistent_cache.enabled = original_cache_enabled
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("keeps a missing URL anchor pending until complete comments arrive", function()
    vim.b[bufnr].octo_pending_anchor = 303
    octo.create_buffer(
      "discussion",
      make_discussion({ make_comment("shell-comment", 101) }, 2, "shell"),
      "owner/repo",
      false
    )

    vim.wait(50, function()
      return false
    end, 10)
    assert.are.same(303, vim.b[bufnr].octo_pending_anchor)

    octo.create_buffer(
      "discussion",
      make_discussion({ make_comment("shell-comment", 101), make_comment("anchor-comment", 303) }, 2, "complete"),
      "owner/repo",
      false
    )
    assert.is_true(vim.wait(1000, function()
      return vim.b[bufnr].octo_pending_anchor == nil
    end))
    assert.are.same("anchor-comment", _G.octo_buffers[bufnr]:get_comment_at_cursor().id)
  end)

  it("restores the cursor to the same comment after new items shift its row", function()
    octo.load = function(_, _, _, _, callback, opts)
      load_requests = { callback = callback, opts = opts }
    end
    octo.load_buffer { bufnr = bufnr }
    load_requests.opts.on_skeleton()

    local target = make_comment("target", 101)
    load_requests.opts.on_shell(make_discussion({ target }, 2, "shell"), false)
    local buffer = _G.octo_buffers[bufnr]
    local target_metadata = buffer.commentsMetadata[1]
    local mark =
      vim.api.nvim_buf_get_extmark_by_id(bufnr, constants.OCTO_COMMENT_NS, target_metadata.extmark, { details = true })
    local body_start = utils.get_extmark_region(bufnr, mark)
    vim.api.nvim_win_set_cursor(0, { body_start + 1, 0 })
    assert.are.same("target", buffer:get_comment_at_cursor().id)

    load_requests.callback(make_discussion({ target, make_comment("newer", 202) }, 2, "complete"))

    assert.are.same("target", _G.octo_buffers[bufnr]:get_comment_at_cursor().id)
  end)
end)
