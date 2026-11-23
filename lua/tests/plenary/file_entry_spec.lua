---@diagnostic disable
local file_entry = require "octo.reviews.file-entry"
local reviews = require "octo.reviews"
local utils = require "octo.utils"
local FileEntry = file_entry.FileEntry
local eq = assert.are.same

describe("FileEntry:fetch", function()
  local original_reviews
  local original_get_file_contents
  local tabpage_key

  before_each(function()
    original_reviews = reviews.reviews
    original_get_file_contents = utils.get_file_contents
    reviews.reviews = {}
    -- A fake current review so FileEntry:fetch can resolve the diff commits.
    tabpage_key = tostring(vim.api.nvim_get_current_tabpage())
    reviews.reviews[tabpage_key] = {
      layout = {
        left = { commit = "left_sha" },
        right = { commit = "right_sha" },
      },
    }
  end)

  after_each(function()
    reviews.reviews = original_reviews
    utils.get_file_contents = original_get_file_contents
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
