---@diagnostic disable
local file_entry = require "octo.reviews.file-entry"
local reviews = require "octo.reviews"
local utils = require "octo.utils"
local gh = require "octo.gh"
local config = require "octo.config"
local FileEntry = file_entry.FileEntry
local eq = assert.are.same

describe("FileEntry:fetch", function()
  local original_reviews
  local original_get_file_contents
  local original_graphql
  local original_github_hostname
  local tabpage_key

  before_each(function()
    original_reviews = reviews.reviews
    original_get_file_contents = utils.get_file_contents
    original_graphql = gh.api.graphql
    original_github_hostname = config.values.github_hostname
    reviews.reviews = {}
    -- A fake current review so FileEntry:fetch can resolve the diff commits.
    tabpage_key = tostring(vim.api.nvim_get_current_tabpage())
    reviews.reviews[tabpage_key] = {
      threads = {},
      get_level = function()
        return "PR"
      end,
      layout = {
        left = {
          commit = "left_sha",
          abbrev = function()
            return "left"
          end,
        },
        right = {
          commit = "right_sha",
          abbrev = function()
            return "right"
          end,
        },
        on_win_leave = function() end,
        on_enter = function() end,
        on_leave = function() end,
      },
    }
  end)

  after_each(function()
    reviews.reviews = original_reviews
    utils.get_file_contents = original_get_file_contents
    gh.api.graphql = original_graphql
    config.values.github_hostname = original_github_hostname
  end)

  local function make_file()
    return FileEntry:new {
      path = "a.txt",
      pull_request = { repo = "owner/repo", local_left = false, local_right = false, files = {} },
      status = "M",
      stats = { additions = 1, deletions = 0, changes = 1 },
    }
  end

  -- Regression: fetch(true) must report readiness so Layout:set_current_file
  -- loads the diff buffers instead of bailing and leaving the previous file's
  -- diff on screen.
  it("returns true once content is fetched synchronously", function()
    utils.get_file_contents = function(_, _, _, cb)
      cb { "line" }
    end

    local file = make_file()
    local ready = file:fetch(true)

    eq(true, ready)
    eq(true, file:is_ready_to_render())
  end)

  it("does not request content again when both sides are cached", function()
    local calls = 0
    utils.get_file_contents = function(_, _, _, cb)
      calls = calls + 1
      cb { "line" }
    end

    local file = make_file()
    eq(true, file:fetch(true))
    eq(true, file:fetch(false))
    eq(true, file:fetch(true))
    eq(2, calls)
  end)

  it("signals completion only after both sides finish fetching", function()
    local callbacks = {}
    utils.get_file_contents = function(_, _, _, cb)
      callbacks[#callbacks + 1] = cb
    end

    local file = make_file()
    local completed = 0
    file:fetch(false, function()
      completed = completed + 1
    end)
    eq(2, #callbacks)
    callbacks[1] { "right" }
    eq(0, completed)
    callbacks[2] { "left" }
    eq(1, completed)
    eq(true, file:is_ready_to_render())
  end)

  it("returns readiness when a fetch is already in flight", function()
    -- Simulate an in-flight async fetch that has already populated both sides.
    local file = make_file()
    file.left_fetching = true
    file.right_fetching = true
    file.left_fetched = true
    file.right_fetched = true

    eq(true, file:fetch(true))
  end)

  it("renders text files from the PR host instead of the configured default host", function()
    config.values.github_hostname = "other-github.example"
    local requests = {}
    gh.api.graphql = function(opts)
      requests[#requests + 1] = opts
      opts.opts.cb("loaded from enterprise", "", 0)
    end
    local file = FileEntry:new {
      path = "a.txt",
      pull_request = {
        repo = "owner/repo",
        hostname = "github.enterprise.internal",
        local_left = false,
        local_right = false,
        files = {},
      },
      status = "M",
      stats = { additions = 1, deletions = 0, changes = 1 },
    }

    eq(true, file:fetch(true))
    local left_win = vim.api.nvim_get_current_win()
    vim.cmd "vsplit"
    local right_win = vim.api.nvim_get_current_win()
    file:load_buffers(left_win, right_win)

    eq(2, #requests)
    for _, request in ipairs(requests) do
      eq("github.enterprise.internal", request.opts.hostname)
    end
    eq({ "loaded from enterprise" }, vim.api.nvim_buf_get_lines(file.left_bufid, 0, -1, false))
    eq({ "loaded from enterprise" }, vim.api.nvim_buf_get_lines(file.right_bufid, 0, -1, false))
    file:destroy()
    vim.cmd "only!"
  end)

  it("fetches the head side before merge-base metadata and the base side after it", function()
    local requests = {}
    utils.get_file_contents = function(repo, commit, path, cb)
      requests[#requests + 1] = { repo = repo, commit = commit, path = path, callback = cb }
    end
    local review = reviews.reviews[tabpage_key]
    review.layout.left.commit = "base_ref_sha"
    review.layout.right.commit = "head_sha"

    local file = FileEntry:new {
      path = "a.txt",
      pull_request = {
        repo = "owner/repo",
        local_left = false,
        local_right = false,
        left_ready = false,
        right_ready = false,
        files = {},
      },
      status = "M",
      stats = { additions = 1, deletions = 0, changes = 1 },
    }
    local completed = 0
    file:fetch(false, function()
      completed = completed + 1
    end)

    eq(0, #requests)
    eq(false, file.right_fetching)

    file.pull_request.right_ready = true
    file:fetch(false)
    eq(1, #requests)
    eq("head_sha", requests[1].commit)
    eq(false, file.left_fetching)

    review.layout.left.commit = "merge_base_sha"
    file.pull_request.left_ready = true
    file:fetch(false)

    eq(2, #requests)
    eq("merge_base_sha", requests[2].commit)
    requests[1].callback { "head" }
    eq(0, completed)
    requests[2].callback { "base" }
    eq(1, completed)
    eq({ "base" }, file.left_lines)
    eq({ "head" }, file.right_lines)
  end)
end)
