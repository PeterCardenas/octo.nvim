---@diagnostic disable

describe("Polling module:", function()
  local polling
  local original_octo_buffers
  local created_buffers

  before_each(function()
    package.loaded["octo.polling"] = nil
    polling = require "octo.polling"
    original_octo_buffers = _G.octo_buffers
    created_buffers = {}
  end)

  after_each(function()
    _G.octo_buffers = original_octo_buffers
    for _, bufnr in ipairs(created_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end)

  local function create_diff_buffer()
    local bufnr = vim.api.nvim_create_buf(false, true)
    table.insert(created_buffers, bufnr)
    vim.api.nvim_buf_set_name(bufnr, "octo://owner/repo/pull/7/diff")
    _G.octo_buffers = {
      [bufnr] = {
        kind = "pull_diff",
        repo = "owner/repo",
        number = 7,
        get_updated_at = function()
          return "2026-07-02T00:00:00Z"
        end,
        get_diff_fingerprint = function()
          return "base..head"
        end,
      },
    }
    return bufnr
  end

  it("tracks pull request diff buffers", function()
    local bufnr = create_diff_buffer()

    polling.track_buffer(bufnr)

    local status = polling.status()
    assert.are.same(1, status.tracked_count)
    assert.are.same("pull_diff", status.buffers[bufnr].kind)
    assert.are.same("base..head", status.buffers[bufnr].last_diff_fingerprint)
  end)
end)
