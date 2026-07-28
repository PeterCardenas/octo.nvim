---@diagnostic disable

local config = require "octo.config"
local gh = require "octo.gh"

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

  ---@param opts? { number: integer }
  local function create_diff_buffer(opts)
    local number = (opts and opts.number) or 7
    local bufnr = vim.api.nvim_create_buf(false, true)
    table.insert(created_buffers, bufnr)
    vim.api.nvim_buf_set_name(bufnr, string.format("octo://owner/repo/pull/%d/diff", number))
    -- Merge (rather than replace) so tests that need more than one buffer
    -- tracked at once (e.g. a hidden buffer plus a visible sentinel) can call
    -- this helper more than once without clobbering earlier entries.
    _G.octo_buffers = vim.tbl_extend("force", _G.octo_buffers or {}, {
      [bufnr] = {
        kind = "pull_diff",
        repo = "owner/repo",
        number = number,
        get_updated_at = function()
          return "2026-07-02T00:00:00Z"
        end,
        get_diff_fingerprint = function()
          return "base..head"
        end,
        -- Displaying this buffer in a window fires the real "octo://*"
        -- BufEnter autocmd, which calls `buffer:configure()`; stub it out.
        configure = function() end,
      },
    })
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

  describe("should_poll_buffer", function()
    it("is pollable when shown in a window of the current tab page", function()
      local bufnr = create_diff_buffer()
      vim.api.nvim_win_set_buf(0, bufnr)

      assert.is_true(polling.should_poll_buffer(bufnr))
    end)

    it("is skipped when not shown in any window", function()
      local bufnr = create_diff_buffer()
      -- Buffer is tracked but never displayed in a window.

      assert.is_false(polling.should_poll_buffer(bufnr))
    end)

    it("is skipped when shown only in a different tab page", function()
      local bufnr = create_diff_buffer()
      vim.api.nvim_win_set_buf(0, bufnr)

      vim.cmd "tabnew"
      local new_tab_bufnr = vim.api.nvim_get_current_buf()

      assert.is_false(polling.should_poll_buffer(bufnr))

      vim.cmd "tabclose"
      pcall(vim.api.nvim_buf_delete, new_tab_bufnr, { force = true })
    end)
  end)

  -- Integration coverage for the visibility gate: drives the real repeating
  -- timer (via track_buffer/start) rather than calling should_poll_buffer
  -- directly, so a regression in start_timer's condition would be caught
  -- even if should_poll_buffer itself stayed correct.
  describe("start_timer visibility gate", function()
    local original_poll_enabled
    local original_poll_interval
    local original_graphql

    before_each(function()
      original_poll_enabled = config.values.poll.enabled
      original_poll_interval = config.values.poll.interval
      original_graphql = gh.api.graphql
      config.values.poll.enabled = true
      config.values.poll.interval = 15
    end)

    after_each(function()
      -- Stop the real uv timer before restoring the stubbed graphql function
      -- and config, otherwise a leaked timer could keep firing against the
      -- real gh.api.graphql after this test ends.
      polling.stop()
      gh.api.graphql = original_graphql
      config.values.poll.enabled = original_poll_enabled
      config.values.poll.interval = original_poll_interval
    end)

    it("issues a graphql request for a buffer shown in the current tab page", function()
      local bufnr = create_diff_buffer()
      vim.api.nvim_win_set_buf(0, bufnr)

      local call_count = 0
      gh.api.graphql = function()
        call_count = call_count + 1
      end

      polling.track_buffer(bufnr)
      polling.start()

      assert.is_true(vim.wait(2000, function()
        return call_count > 0
      end, 20))
    end)

    it("issues no graphql request for a buffer not shown in any window", function()
      -- Track a hidden buffer alongside a visible "sentinel" buffer so this
      -- test proves a tick actually landed (via the sentinel) rather than
      -- passing vacuously if timer delivery were broken. Each tracked buffer
      -- can produce at most one graphql call here (the stub never invokes
      -- opts.cb, so `tracking.loading` latches true after the first call),
      -- so call counts are keyed per-buffer via the query's `number`
      -- variable (F.number), which octo/polling.lua sets from tracking.number
      -- and is therefore genuinely distinguishing across buffers.
      local hidden_bufnr = create_diff_buffer { number = 7 }
      local sentinel_bufnr = create_diff_buffer { number = 8 }
      vim.api.nvim_win_set_buf(0, sentinel_bufnr)
      -- hidden_bufnr is never displayed in any window.

      local call_counts_by_number = {}
      gh.api.graphql = function(opts)
        local number = opts.F.number
        call_counts_by_number[number] = (call_counts_by_number[number] or 0) + 1
      end

      polling.track_buffer(hidden_bufnr)
      polling.track_buffer(sentinel_bufnr)
      polling.start()

      assert.is_true(vim.wait(2000, function()
        return (call_counts_by_number[8] or 0) > 0
      end, 20))

      assert.are.same(0, call_counts_by_number[7] or 0)
    end)
  end)
end)
