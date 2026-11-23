---@diagnostic disable

local constants = require "octo.constants"
local writers = require "octo.ui.writers"
local config = require "octo.config"
local octo = require "octo"
local gh = require "octo.gh"

local function make_comment(id, database_id, replies)
  return {
    id = id,
    databaseId = database_id,
    author = { login = "author" },
    viewerDidAuthor = false,
    viewerCanUpdate = false,
    viewerCanDelete = false,
    createdAt = "2026-01-01T00:00:00Z",
    lastEditedAt = vim.NIL,
    body = "Body " .. id,
    reactionGroups = {},
    replyTo = nil,
    includesCreatedEdit = false,
    replies = replies or { totalCount = 0, nodes = {} },
  }
end

local function make_issue(comments)
  return {
    id = "issue-id",
    number = 17,
    url = "https://github.com/owner/repo/issues/17",
    title = "Issue preview",
    body = "Issue body",
    state = "OPEN",
    stateReason = vim.NIL,
    author = { login = "author" },
    viewerDidAuthor = false,
    authorAssociation = "NONE",
    createdAt = "2026-01-01T00:00:00Z",
    updatedAt = "2026-01-02T00:00:00Z",
    closedAt = vim.NIL,
    lastEditedAt = vim.NIL,
    includesCreatedEdit = false,
    viewerCanUpdate = false,
    assignees = { nodes = {} },
    projectItems = { nodes = {} },
    parent = vim.NIL,
    milestone = vim.NIL,
    labels = { nodes = {} },
    issueType = vim.NIL,
    reactionGroups = {},
    timelineItems = { nodes = comments },
  }
end

local function make_discussion(comments)
  return {
    id = "discussion-id",
    number = 42,
    title = "Discussion preview",
    body = "Question body",
    url = "https://github.com/owner/repo/discussions/42",
    author = { login = "author" },
    viewerDidAuthor = false,
    category = { name = "Ideas" },
    createdAt = "2026-01-01T00:00:00Z",
    updatedAt = "2026-01-02T00:00:00Z",
    closed = false,
    isAnswered = vim.NIL,
    labels = { nodes = {} },
    comments = { totalCount = #comments, nodes = comments },
    answer = vim.NIL,
    poll = vim.NIL,
    reactionGroups = {},
    viewerCanUpdate = false,
    lastEditedAt = vim.NIL,
    includesCreatedEdit = false,
  }
end

local function find_line(bufnr, text)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:find(text, 1, true) then
      return index
    end
  end
end

describe("picker preview rendering", function()
  local bufnr
  local original_buffers
  local original_timeline_order
  local original_load_preview
  local original_graphql

  before_each(function()
    original_buffers = _G.octo_buffers
    _G.octo_buffers = {}
    original_timeline_order = config.values.timeline_order
    original_load_preview = octo.load_preview
    original_graphql = gh.api.graphql
    config.values.timeline_order = "newest_first"
    bufnr = vim.api.nvim_create_buf(false, true)
    _G.octo_buffers[bufnr] = { commentsMetadata = {}, threadsMetadata = {} }
  end)

  after_each(function()
    _G.octo_buffers = original_buffers
    config.values.timeline_order = original_timeline_order
    octo.load_preview = original_load_preview
    gh.api.graphql = original_graphql
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("adds PR check details asynchronously without delaying the fast preview paint", function()
    local shell = { id = "pull-id", number = 42, title = "Pull request", commits = { totalCount = 1 } }
    octo.load_preview = function(_, _, _, _, callback)
      callback(vim.deepcopy(shell), false)
    end
    local check_request
    gh.api.graphql = function(opts)
      check_request = opts
    end
    local deliveries = {}

    octo.load_pull_preview("owner/repo", 42, nil, function(obj, cached)
      deliveries[#deliveries + 1] = { object = obj, cached = cached }
    end)

    assert.are.same(1, #deliveries)
    assert.is_nil(deliveries[1].object.statusCheckRollup)
    assert.is_table(check_request)
    check_request.opts.cb(
      vim.json.encode {
        data = {
          repository = {
            pullRequest = {
              statusCheckRollup = { state = "SUCCESS", contexts = { nodes = {} } },
            },
          },
        },
      },
      nil
    )

    assert.are.same(2, #deliveries)
    assert.are.same("SUCCESS", deliveries[2].object.statusCheckRollup.state)
  end)

  it("renders issue activity newest first and replaces previous preview content", function()
    local older = vim.tbl_extend("force", make_comment("older", 101), { __typename = "IssueComment" })
    local newer = vim.tbl_extend("force", make_comment("newer", 202), { __typename = "IssueComment" })

    writers.issue_preview(make_issue { older, newer }, bufnr)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.is_true(find_line(bufnr, "Body newer") < find_line(bufnr, "Body older"))
    local first_extmark_count = #vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_COMMENT_NS, 0, -1, {})
    assert.is_true(first_extmark_count > 2)

    writers.issue_preview(
      make_issue { vim.tbl_extend("force", make_comment("replacement", 303), { __typename = "IssueComment" }) },
      bufnr
    )

    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.is_not_nil(find_line(bufnr, "Body replacement"))
    assert.is_nil(find_line(bufnr, "Body older"))
    assert.is_true(#vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_COMMENT_NS, 0, -1, {}) < first_extmark_count)
  end)

  it("renders discussion comments newest first and preserves chronological replies", function()
    local older = make_comment("older", 101, {
      totalCount = 2,
      nodes = { make_comment("reply-1", 102), make_comment("reply-2", 103) },
    })
    local newer = make_comment("newer", 202)

    writers.discussion_preview(make_discussion { older, newer }, bufnr)

    assert.is_true(find_line(bufnr, "Body newer") < find_line(bufnr, "Body older"))
    assert.is_true(find_line(bufnr, "Body reply-1") < find_line(bufnr, "Body reply-2"))
    assert.is_true(#vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_COMMENT_NS, 0, -1, {}) >= 4)
  end)
end)
