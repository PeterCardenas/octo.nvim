---@diagnostic disable

local OctoBuffer = require("octo.model.octo-buffer").OctoBuffer
local commands = require "octo.commands"
local gh = require "octo.gh"
local writers = require "octo.ui.writers"

local function reaction_group(viewer_has_reacted, count)
  return {
    content = "HEART",
    viewerHasReacted = viewer_has_reacted,
    users = { totalCount = count, nodes = {} },
  }
end

local function make_comment(id, groups)
  return {
    id = id,
    databaseId = id == "first" and 101 or 202,
    author = { login = "commenter" },
    viewerDidAuthor = false,
    viewerCanUpdate = false,
    viewerCanDelete = false,
    createdAt = "2026-01-01T00:00:00Z",
    lastEditedAt = vim.NIL,
    body = "Comment " .. id,
    reactionGroups = groups,
    replyTo = nil,
    includesCreatedEdit = false,
  }
end

describe("reaction mutation targets", function()
  local bufnr
  local original_buffers
  local original_graphql

  before_each(function()
    original_buffers = _G.octo_buffers
    _G.octo_buffers = {}
    original_graphql = gh.api.graphql
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    gh.api.graphql = original_graphql
    _G.octo_buffers = original_buffers
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("resolves a reaction response to the original comment after the cursor moves", function()
    local buffer = OctoBuffer:new {
      bufnr = bufnr,
      number = 42,
      repo = "owner/repo",
      kind = "issue",
      node = { id = "issue-id", number = 42, title = "Issue", author = { login = "author" } },
    }
    local initial_groups = { reaction_group(false, 0) }
    writers.write_comment(bufnr, make_comment("first", initial_groups), "IssueComment")
    writers.write_comment(bufnr, make_comment("second", initial_groups), "IssueComment")
    local first_comment = buffer.commentsMetadata[1]
    local second_comment = buffer.commentsMetadata[2]
    local constants = require "octo.constants"
    local first_mark =
      vim.api.nvim_buf_get_extmark_by_id(bufnr, constants.OCTO_COMMENT_NS, first_comment.extmark, { details = true })
    local second_mark =
      vim.api.nvim_buf_get_extmark_by_id(bufnr, constants.OCTO_COMMENT_NS, second_comment.extmark, { details = true })
    local first_body_line = require("octo.utils").get_extmark_region(bufnr, first_mark)
    local second_body_line = require("octo.utils").get_extmark_region(bufnr, second_mark)
    local requests = {}
    gh.api.graphql = function(opts)
      requests[#requests + 1] = opts
    end

    vim.api.nvim_win_set_cursor(0, { first_body_line + 1, 0 })
    assert.are.same(first_comment, buffer:get_comment_at_cursor())
    commands.reaction_action "heart"
    assert.are.equal(1, #requests)

    vim.api.nvim_win_set_cursor(0, { second_body_line + 1, 0 })
    requests[1].opts.cb(
      vim.json.encode {
        data = {
          addReaction = {
            subject = { reactionGroups = { reaction_group(true, 1) } },
          },
        },
      },
      nil
    )

    assert.are.same({ reaction_group(true, 1) }, first_comment.reactionGroups)
    assert.are.same(initial_groups, second_comment.reactionGroups)
  end)
end)
