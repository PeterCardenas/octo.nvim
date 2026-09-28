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

  describe("set_enabled", function()
    it("stops polling and prevents buffer tracking from restarting it", function()
      local original_enabled = config.values.poll.enabled
      config.values.poll.enabled = true
      local bufnr = create_diff_buffer()
      polling.track_buffer(bufnr)
      assert.is_true(polling.status().running)

      polling.set_enabled(false)
      polling.track_buffer(bufnr)
      assert.is_false(polling.status().running)
      assert.is_false(polling.status().enabled)
      config.values.poll.enabled = original_enabled
    end)

    it("preserves toggle after a manual stop", function()
      local original_enabled = config.values.poll.enabled
      config.values.poll.enabled = true
      polling.track_buffer(create_diff_buffer())
      polling.stop()

      polling.toggle()
      assert.is_true(polling.status().running)
      polling.set_enabled(false)
      config.values.poll.enabled = original_enabled
    end)

    it("resumes polling for already tracked buffers", function()
      local original_enabled = config.values.poll.enabled
      config.values.poll.enabled = false
      local bufnr = create_diff_buffer()
      polling.track_buffer(bufnr)
      assert.is_false(polling.status().running)

      polling.set_enabled(true)
      assert.is_true(polling.status().running)
      assert.is_true(polling.status().enabled)
      polling.stop()
      config.values.poll.enabled = original_enabled
    end)
  end)

  describe("start_timer", function()
    local original_poll_enabled
    local original_poll_interval
    local original_graphql
    local original_new_timer
    local original_should_poll_buffer

    before_each(function()
      original_poll_enabled = config.values.poll.enabled
      original_poll_interval = config.values.poll.interval
      original_graphql = gh.api.graphql
      original_new_timer = vim.uv.new_timer
      original_should_poll_buffer = config.values.poll.should_poll_buffer
      config.values.poll.enabled = true
      config.values.poll.interval = 15
    end)

    after_each(function()
      -- Stop the real uv timer before restoring the stubbed graphql function
      -- and config, otherwise a leaked timer could keep firing against the
      -- real gh.api.graphql after this test ends.
      polling.stop()
      gh.api.graphql = original_graphql
      vim.uv.new_timer = original_new_timer
      config.values.poll.should_poll_buffer = original_should_poll_buffer
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

    it("keeps the new tracking entry loading after a stale callback", function()
      local bufnr = create_diff_buffer { number = 7 }
      vim.api.nvim_win_set_buf(0, bufnr)

      local timer_callback
      vim.uv.new_timer = function()
        return {
          start = function(_, _, _, callback)
            timer_callback = callback
          end,
          stop = function() end,
          close = function() end,
          is_closing = function()
            return false
          end,
        }
      end

      local requests = {}
      gh.api.graphql = function(opts)
        requests[#requests + 1] = opts
      end

      polling.track_buffer(bufnr)
      polling.start()
      timer_callback()
      assert.is_true(vim.wait(100, function()
        return #requests == 1
      end))

      polling.track_buffer(bufnr)
      -- Model the replacement resource's in-flight request while retaining the
      -- first request callback as the stale completion. The resource metadata
      -- is intentionally unchanged; only the tracking entry is replaced.
      polling.status().buffers[bufnr].loading = true

      requests[1].opts.cb('{"data":{"repository":{"pullRequest":{"updatedAt":"2026-07-03T00:00:00Z"}}}}', nil)
      vim.wait(100)

      assert.is_true(polling.status().buffers[bufnr].loading)
    end)

    it("skips only buffers rejected by the configured predicate", function()
      local hidden_bufnr = create_diff_buffer { number = 7 }
      local visible_bufnr = create_diff_buffer { number = 8 }
      local calls = {}
      config.values.poll.should_poll_buffer = function(bufnr)
        return bufnr ~= hidden_bufnr
      end
      gh.api.graphql = function(opts)
        calls[opts.F.number] = (calls[opts.F.number] or 0) + 1
      end

      polling.track_buffer(hidden_bufnr)
      polling.track_buffer(visible_bufnr)
      assert.is_true(vim.wait(2000, function()
        return (calls[8] or 0) > 0
      end, 20))
      assert.are.same(0, calls[7] or 0)
    end)

    it("polls a tracked buffer even when another buffer is displayed", function()
      local bufnr = create_diff_buffer()
      local call_count = 0
      gh.api.graphql = function()
        call_count = call_count + 1
      end

      polling.track_buffer(bufnr)
      assert.is_true(vim.wait(2000, function()
        return call_count > 0
      end, 20))
    end)
  end)
end)
