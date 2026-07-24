---@diagnostic disable
-- Regression coverage for the OCTO_COMMENT_VT_NS fix: comment-header virtual
-- text used to live in a fresh anonymous namespace per comment
-- (`vim.api.nvim_create_namespace ""`), so deleting one comment could only
-- ever bulk-clear its own namespace. Now all comment headers share
-- constants.OCTO_COMMENT_VT_NS and each CommentMetadata tracks its own
-- `vtExtmark`, so a single comment can be deleted without touching any
-- other comment's virtual text. This test would fail if that were reverted
-- to a per-comment `nvim_buf_clear_namespace` bulk-clear, since clearing
-- comment A's own (shared) namespace would also wipe comment B's mark.

local constants = require "octo.constants"

local function make_comment(id, login)
  return {
    id = id,
    databaseId = id,
    author = { login = login },
    viewerDidAuthor = false,
    viewerCanUpdate = true,
    viewerCanDelete = true,
    createdAt = "2026-01-01T00:00:00Z",
    lastEditedAt = vim.NIL,
    body = "comment body " .. id,
    reactionGroups = {},
    replyTo = nil,
    includesCreatedEdit = false,
  }
end

describe("write_comment virtual text namespace", function()
  local writers
  local bufnr
  local original_octo_buffers

  before_each(function()
    package.loaded["octo.ui.writers"] = nil
    writers = require "octo.ui.writers"
    original_octo_buffers = _G.octo_buffers
    bufnr = vim.api.nvim_create_buf(false, true)
    _G.octo_buffers = {
      [bufnr] = { commentsMetadata = {} },
    }
  end)

  after_each(function()
    _G.octo_buffers = original_octo_buffers
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  it("gives each comment a distinct vtExtmark in the shared namespace, and deleting one leaves the other", function()
    local buffer = _G.octo_buffers[bufnr]

    writers.write_comment(bufnr, make_comment(1, "alice"), "IssueComment")
    writers.write_comment(bufnr, make_comment(2, "bob"), "IssueComment")

    assert.are.equal(2, #buffer.commentsMetadata)
    local metadata_a = buffer.commentsMetadata[1]
    local metadata_b = buffer.commentsMetadata[2]

    assert.is_not_nil(metadata_a.vtExtmark)
    assert.is_not_nil(metadata_b.vtExtmark)
    assert.are_not.equal(metadata_a.vtExtmark, metadata_b.vtExtmark)

    local before = vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_COMMENT_VT_NS, 0, -1, {})
    assert.are.equal(2, #before)

    -- Simulate delete_comment's single-mark removal (commands.lua ~1506).
    vim.api.nvim_buf_del_extmark(bufnr, constants.OCTO_COMMENT_VT_NS, metadata_a.vtExtmark)

    local remaining = vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_COMMENT_VT_NS, 0, -1, { details = true })
    assert.are.equal(1, #remaining)
    assert.are.equal(metadata_b.vtExtmark, remaining[1][1])
  end)
end)
