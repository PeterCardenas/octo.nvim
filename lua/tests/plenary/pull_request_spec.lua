---@diagnostic disable
local gh = require "octo.gh"
local PullRequest = require("octo.model.pull-request").PullRequest
local eq = assert.are.same

describe("PullRequest:get_commit_changed_files", function()
  local original_get

  before_each(function()
    original_get = gh.api.get
  end)

  after_each(function()
    gh.api.get = original_get
  end)

  it("fetches every page of changed files for a large commit", function()
    local requests = {}
    gh.api.get = function(opts)
      requests[#requests + 1] = opts
      local files = {}
      local page = opts.format.page or 1
      local start_idx = (page - 1) * 100 + 1
      local last_idx = page == 1 and 100 or 101
      for idx = start_idx, last_idx do
        files[#files + 1] = {
          filename = string.format("file-%d.txt", idx),
          status = "modified",
          additions = 1,
          deletions = 0,
          changes = 1,
        }
      end
      opts.opts.cb(vim.json.encode { files = files }, "")
    end

    local pr = setmetatable({ repo = "owner/repo", number = 1, files = {} }, { __index = PullRequest })
    local received
    pr:get_commit_changed_files({ commit = "sha" }, function(files)
      received = files
    end)

    eq(2, #requests)
    eq(101, #received)
    eq("file-101.txt", received[101].path)
  end)
end)
