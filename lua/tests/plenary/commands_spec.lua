---@diagnostic disable

describe("Commands module:", function()
  local commands
  local original_input
  local original_get_current_buffer
  local original_pr
  local original_reload
  local utils
  local gh

  before_each(function()
    package.loaded["octo.commands"] = nil
    commands = require "octo.commands"
    commands.setup()
    utils = require "octo.utils"
    gh = require "octo.gh"

    original_input = vim.ui.input
    original_get_current_buffer = utils.get_current_buffer
    original_pr = gh.pr
    original_reload = commands.reload
  end)

  after_each(function()
    vim.ui.input = original_input
    utils.get_current_buffer = original_get_current_buffer
    gh.pr = original_pr
    commands.reload = original_reload
  end)

  local function pull_request_buffer()
    return {
      repo = "owner/repo",
      bufnr = 42,
      isPullRequest = function()
        return true
      end,
      pullRequest = function()
        return { number = 7 }
      end,
    }
  end

  it("pr close passes comment when body is provided", function()
    local close_opts
    local reloaded

    utils.get_current_buffer = function()
      return pull_request_buffer()
    end
    vim.ui.input = function(_, cb)
      cb "closing note"
    end
    commands.reload = function(opts)
      reloaded = opts
    end
    gh.pr = {
      close = function(opts)
        close_opts = opts
        opts.opts.cb("", "", 0)
      end,
    }

    commands.commands.pr.close()

    assert.are.same(7, close_opts[1])
    assert.are.same("owner/repo", close_opts.repo)
    assert.are.same("closing note", close_opts.comment)
    assert.are.same({ bufnr = 42 }, reloaded)
  end)

  it("pr close omits comment when body is blank", function()
    local close_opts

    utils.get_current_buffer = function()
      return pull_request_buffer()
    end
    vim.ui.input = function(_, cb)
      cb ""
    end
    gh.pr = {
      close = function(opts)
        close_opts = opts
      end,
    }

    commands.commands.pr.close()

    assert.are.same(nil, close_opts.comment)
  end)

  it("pr close does nothing when input is cancelled", function()
    local called = false

    utils.get_current_buffer = function()
      return pull_request_buffer()
    end
    vim.ui.input = function(_, cb)
      cb(nil)
    end
    gh.pr = {
      close = function(_)
        called = true
      end,
    }

    commands.commands.pr.close()

    assert.are.same(false, called)
  end)
end)
