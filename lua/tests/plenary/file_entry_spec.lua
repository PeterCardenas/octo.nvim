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

  it("returns readiness when a fetch is already in flight", function()
    -- Simulate an in-flight async fetch that has already populated both sides.
    local file = make_file()
    file.left_fetching = true
    file.right_fetching = true
    file.left_fetched = true
    file.right_fetched = true

    eq(true, file:fetch(true))
  end)
end)
