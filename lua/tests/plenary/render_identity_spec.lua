---@diagnostic disable

local config = require "octo.config"
local octo = require "octo"
local polling = require "octo.polling"
local constants = require "octo.constants"
local gh = require "octo.gh"
local utils = require "octo.utils"
local commands = require "octo.commands"

local function make_comment(id, database_id, reaction_groups)
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
    reactionGroups = reaction_groups or {},
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
  local original_auth_context
  local original_graphql
  local original_buffers
  local load_requests

  before_each(function()
    original_load = octo.load
    original_track = polling.track_buffer
    original_cache_enabled = config.values.persistent_cache.enabled
    original_auth_context = gh.get_auth_context
    original_graphql = gh.api.graphql
    original_buffers = _G.octo_buffers
    _G.octo_buffers = {}
    gh.get_auth_context = function(hostname, callback)
      callback { hostname = hostname, token = "test-token", fingerprint = "test-identity", env = {} }
    end
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
    gh.get_auth_context = original_auth_context
    gh.api.graphql = original_graphql
    _G.octo_buffers = original_buffers
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

  it("retries an older URL anchor after the in-place phase-two repaint", function()
    octo.load = function(_, _, _, _, callback, opts)
      load_requests = { callback = callback, opts = opts }
    end
    vim.b[bufnr].octo_pending_anchor = 303
    octo.load_buffer { bufnr = bufnr }
    load_requests.opts.on_skeleton()
    load_requests.opts.on_shell(make_discussion({ make_comment("shell-comment", 101) }, 2, "shell"), false)

    assert.is_true(vim.wait(1000, function()
      return _G.octo_buffers[bufnr] ~= nil
    end))
    assert.are.same(303, vim.b[bufnr].octo_pending_anchor)

    load_requests.callback(
      make_discussion({ make_comment("shell-comment", 101), make_comment("older-anchor", 303) }, 2, "complete")
    )

    assert.is_true(vim.wait(1000, function()
      return vim.b[bufnr].octo_pending_anchor == nil
    end))
    assert.are.same("older-anchor", _G.octo_buffers[bufnr]:get_comment_at_cursor().id)
  end)

  it("resolves a pending reaction against current comment extmarks after load_buffer replaces the model", function()
    local loads = {}
    octo.load = function(_, _, _, _, callback, opts)
      loads[#loads + 1] = { callback = callback, opts = opts }
    end
    local requests = {}
    gh.api.graphql = function(opts)
      requests[#requests + 1] = opts
    end
    local reacted = {
      {
        content = "HEART",
        viewerHasReacted = true,
        users = { totalCount = 1, nodes = {} },
      },
    }
    local target = make_comment("target", 303, reacted)

    octo.load_buffer { bufnr = bufnr }
    loads[1].opts.on_skeleton()
    loads[1].opts.on_shell(make_discussion({ target }, 1, "shell"), false)
    local old_buffer = _G.octo_buffers[bufnr]
    local old_metadata = old_buffer:get_reaction_metadata "target"
    local old_line = old_metadata.reactionLine
    local constants = require "octo.constants"
    local old_mark =
      vim.api.nvim_buf_get_extmark_by_id(bufnr, constants.OCTO_COMMENT_NS, old_metadata.extmark, { details = true })
    local old_body_line = utils.get_extmark_region(bufnr, old_mark)
    vim.api.nvim_win_set_cursor(0, { old_body_line + 1, 0 })
    commands.reaction_action "heart"
    assert.are.same(1, #requests)

    octo.load_buffer { bufnr = bufnr }
    loads[2].opts.on_shell(
      make_discussion({ target, make_comment("newer-one", 404), make_comment("newer-two", 505) }, 3, "shell"),
      false
    )
    loads[2].callback(
      make_discussion({ target, make_comment("newer-one", 404), make_comment("newer-two", 505) }, 3, "complete")
    )
    local current_buffer = _G.octo_buffers[bufnr]
    local current_metadata = current_buffer:get_reaction_metadata "target"
    assert.is_not.equal(old_buffer, current_buffer)
    assert.is_not.equal(old_line, current_metadata.reactionLine)

    requests[1].opts.cb(vim.json.encode { data = { removeReaction = { subject = { reactionGroups = {} } } } }, nil)

    assert.is_nil(current_buffer:get_reaction_metadata("target").reactionLine)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.is_true(vim.tbl_contains(lines, "Body for newer-one"))
    assert.is_true(vim.tbl_contains(lines, "Body for newer-two"))
    assert.is_true(vim.tbl_contains(lines, "Body for target"))
  end)

  it("keeps an anchor missed by a cached complete object until live data arrives", function()
    octo.load = function(_, _, _, _, callback, opts)
      load_requests = { callback = callback, opts = opts }
    end
    vim.b[bufnr].octo_pending_anchor = 303
    octo.load_buffer { bufnr = bufnr }
    octo.create_buffer(
      "discussion",
      make_discussion({ make_comment("cached-comment", 101) }, 2, "complete"),
      "owner/repo",
      false
    )

    assert.is_true(vim.wait(1000, function()
      return _G.octo_buffers[bufnr] ~= nil
    end))
    assert.are.same(303, vim.b[bufnr].octo_pending_anchor)

    load_requests.callback(make_discussion({ make_comment("live-anchor", 303) }, 2, "complete"))

    assert.is_true(vim.wait(1000, function()
      return vim.b[bufnr].octo_pending_anchor == nil
    end))
    assert.are.same("live-anchor", _G.octo_buffers[bufnr]:get_comment_at_cursor().id)
  end)

  it("navigates a URL anchor only in a window displaying the target buffer", function()
    vim.b[bufnr].octo_pending_anchor = 303
    local target_win = vim.api.nvim_get_current_win()
    vim.cmd "vsplit"
    local other_win = vim.api.nvim_get_current_win()
    local other_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(other_win, other_buf)
    vim.api.nvim_win_set_cursor(other_win, { 1, 0 })

    vim.api.nvim_win_call(target_win, function()
      octo.create_buffer(
        "discussion",
        make_discussion({ make_comment("live-anchor", 303) }, 1, "complete"),
        "owner/repo",
        false
      )
    end)

    assert.is_true(vim.wait(1000, function()
      return vim.b[bufnr].octo_pending_anchor == nil
    end))
    local anchor_comment = vim.api.nvim_win_call(target_win, function()
      return _G.octo_buffers[bufnr]:get_comment_at_cursor()
    end)
    assert.are.same("live-anchor", anchor_comment.id)
    assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(other_win))

    vim.api.nvim_win_close(other_win, true)
    vim.api.nvim_buf_delete(other_buf, { force = true })
  end)

  it("does not treat a reaction-only line insertion as a local edit before live completion", function()
    local loads = {}
    octo.load = function(_, _, _, _, callback, opts)
      loads[#loads + 1] = { callback = callback, opts = opts }
    end
    local requests = {}
    gh.api.graphql = function(opts)
      requests[#requests + 1] = opts
    end
    local empty_reaction = {
      { content = "HEART", viewerHasReacted = false, users = { totalCount = 0, nodes = {} } },
    }
    local reacted = {
      { content = "HEART", viewerHasReacted = true, users = { totalCount = 1, nodes = {} } },
    }
    local target = make_comment("target", 303, empty_reaction)
    local local_changes = 0

    octo.load_buffer {
      bufnr = bufnr,
      on_local_changes = function()
        local_changes = local_changes + 1
      end,
    }
    loads[1].opts.on_shell(make_discussion({ target }, 1, "shell"), false)
    local buffer = _G.octo_buffers[bufnr]
    local mark =
      vim.api.nvim_buf_get_extmark_by_id(bufnr, constants.OCTO_COMMENT_NS, buffer.commentsMetadata[1].extmark, {
        details = true,
      })
    local body_start = utils.get_extmark_region(bufnr, mark)
    vim.api.nvim_win_set_cursor(0, { body_start + 1, 0 })
    commands.reaction_action "heart"
    requests[1].opts.cb(vim.json.encode { data = { addReaction = { subject = { reactionGroups = reacted } } } }, nil)

    assert.is_false(vim.bo[bufnr].modified)
    loads[1].callback(make_discussion({ make_comment("target", 303, reacted) }, 1, "complete"))

    assert.are.same(0, local_changes)
    assert.are.same("complete", _G.octo_buffers[bufnr].node._loadState)
  end)

  it("resolves reaction cursor targeting from live marks after rows shift", function()
    local reacted = {
      { content = "HEART", viewerHasReacted = true, users = { totalCount = 1, nodes = {} } },
    }
    octo.create_buffer(
      "discussion",
      make_discussion({ make_comment("target", 303, reacted) }, 1, "complete"),
      "owner/repo",
      false
    )
    local buffer = _G.octo_buffers[bufnr]
    local metadata = buffer.commentsMetadata[1]
    local stale_reaction_line = metadata.reactionLine
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted row one", "inserted row two" })
    local mark =
      vim.api.nvim_buf_get_extmark_by_id(bufnr, constants.OCTO_COMMENT_NS, metadata.extmark, { details = true })
    local _, end_line = utils.get_extmark_region(bufnr, mark)
    local live_reaction_line = end_line + 3
    assert.are_not.same(stale_reaction_line, live_reaction_line)

    vim.api.nvim_win_set_cursor(0, { live_reaction_line, 0 })

    assert.are.same("target", buffer:get_reactions_at_cursor())
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
