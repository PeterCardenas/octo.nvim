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
