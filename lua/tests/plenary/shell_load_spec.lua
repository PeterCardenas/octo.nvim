---@diagnostic disable

local OctoBuffer = require("octo.model.octo-buffer").OctoBuffer
local writers = require "octo.ui.writers"

local function make_discussion(number)
  return {
    id = "discussion-id",
    number = number,
    title = "Discussion title",
    body = "Discussion body",
    url = "https://github.com/owner/repo/discussions/" .. number,
    author = { login = "author" },
    viewerDidAuthor = false,
    category = { name = "Ideas" },
    createdAt = "2026-01-01T00:00:00Z",
    updatedAt = "2026-01-02T00:00:00Z",
    closed = false,
    isAnswered = vim.NIL,
    labels = { nodes = {} },
    comments = { totalCount = 1, nodes = { vim.NIL } },
    answer = vim.NIL,
    poll = vim.NIL,
    reactionGroups = {},
    viewerCanUpdate = false,
    lastEditedAt = vim.NIL,
    includesCreatedEdit = false,
  }
end

describe("two-phase load shells", function()
  local bufnr
  local original_buffers
  local pull_requests
  local original_create_with_merge_base

  before_each(function()
    original_buffers = _G.octo_buffers
    pull_requests = require "octo.model.pull-request"
    original_create_with_merge_base = pull_requests.create_with_merge_base
    _G.octo_buffers = {}
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    pull_requests.create_with_merge_base = original_create_with_merge_base
    _G.octo_buffers = original_buffers
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("renders a shell PR review without requiring reviewThreads", function()
    local buffer = { bufnr = bufnr, commentsMetadata = {}, threadsMetadata = {} }
    _G.octo_buffers[bufnr] = buffer
    local review = {
      __typename = "PullRequestReview",
      id = "review-id",
      state = "APPROVED",
      body = "Looks good",
      createdAt = "2026-01-01T00:00:00Z",
      lastEditedAt = vim.NIL,
      author = { login = "reviewer" },
      viewerDidAuthor = false,
      viewerCanUpdate = false,
      reactionGroups = {},
      comments = { nodes = { { id = "review-comment" } } },
    }

    assert.has_no.errors(function()
      writers.write_timeline_items(bufnr, { timelineItems = { nodes = { review } } })
    end)
    assert.is_true(
      table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"):find("Looks good", 1, true) ~= nil
    )
  end)

  it("renders a discussion containing a deleted NIL comment node", function()
    local discussion = make_discussion(12)
    local buffer = OctoBuffer:new {
      bufnr = bufnr,
      number = discussion.number,
      repo = "owner/repo",
      kind = "discussion",
      node = discussion,
    }

    assert.has_no.errors(function()
      buffer:render_discussion()
    end)
    assert.is_true(
      table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"):find("Discussion title", 1, true) ~= nil
    )
  end)

  it("waits for a complete PR node before creating a review model", function()
    local created_from
    pull_requests.create_with_merge_base = function(_, node)
      created_from = node
    end

    local shell = {
      _loadState = "shell",
      id = "pull-id",
      number = 42,
      title = "Pull request",
    }
    local buffer = OctoBuffer:new {
      bufnr = bufnr,
      number = 42,
      repo = "owner/repo",
      kind = "pull",
      node = shell,
    }
    local callback = function() end

    assert.has_no.errors(function()
      buffer:get_pr(callback)
    end)
    assert.is_nil(created_from)

    local complete = {
      _loadState = "complete",
      id = "pull-id",
      number = 42,
      title = "Pull request",
      files = { nodes = {} },
      headRefOid = "head",
      baseRefOid = "base",
      headRefName = "head",
      baseRefName = "base",
      headRepository = { nameWithOwner = "owner/repo" },
    }
    buffer:update_node(complete)

    assert.are.same(complete, created_from)
  end)
end)
