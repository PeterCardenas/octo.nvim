local config = require "octo.config"

describe("discussion timeline order", function()
  local bufnr
  local original_order
  local original_writers
  local comment_order

  before_each(function()
    original_order = config.values.timeline_order
    original_writers = package.loaded["octo.ui.writers"]
    comment_order = {}
    config.values.timeline_order = "newest_first"
    package.loaded["octo.ui.writers"] = {
      write_title = function() end,
      write_state = function() end,
      write_discussion_details = function() end,
      write_body = function() end,
      write_discussion_answer = function()
        comment_order[#comment_order + 1] = "answer"
      end,
      write_comment = function(_, comment)
        comment_order[#comment_order + 1] = comment.id
      end,
      write_block = function() end,
    }
    package.loaded["octo.model.octo-buffer"] = nil
    _G.octo_buffers = {}
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    config.values.timeline_order = original_order
    package.loaded["octo.ui.writers"] = original_writers
    package.loaded["octo.model.octo-buffer"] = nil
  end)

  it("reverses top-level comments while keeping replies chronological", function()
    local old_comment = {
      id = "old-comment",
      replies = {
        totalCount = 2,
        nodes = { { id = "old-reply-1" }, { id = "old-reply-2" } },
      },
    }
    local new_comment = { id = "new-comment", replies = { totalCount = 0, nodes = {} } }
    local buffer = require("octo.model.octo-buffer").OctoBuffer:new {
      bufnr = bufnr,
      number = 5,
      repo = "owner/repo",
      kind = "discussion",
      node = {
        id = "discussion-id",
        number = 5,
        title = "Discussion",
        closed = false,
        body = "Body",
        answer = { id = "old-comment" },
        poll = vim.NIL,
        reactionGroups = {},
        comments = { nodes = { old_comment, new_comment } },
      },
    }

    buffer:render_discussion()

    assert.same({ "answer", "new-comment", "old-comment", "old-reply-1", "old-reply-2" }, comment_order)
  end)
end)
