---@diagnostic disable
local gh = require "octo.gh"
local PullRequest = require("octo.model.pull-request").PullRequest
local pull_request_model = require "octo.model.pull-request"
local utils = require "octo.utils"
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

describe("PullRequest:get_changed_files", function()
  local original_get
  local original_commit_exists

  before_each(function()
    original_get = gh.api.get
    original_commit_exists = utils.commit_exists
  end)

  after_each(function()
    gh.api.get = original_get
    utils.commit_exists = original_commit_exists
  end)

  it("carries the resolved host through changed-file requests", function()
    local request
    gh.api.get = function(opts)
      request = opts
      opts.opts.cb("[]", "")
    end

    local pr = setmetatable({
      repo = "owner/repo",
      number = 1,
      files = {},
      hostname = "github.enterprise.internal",
      changed_files_count = 0,
    }, { __index = PullRequest })
    pr:get_changed_files(function() end)

    eq("github.enterprise.internal", request.opts.hostname)
  end)

  it("requests metadata-sized pages concurrently and emits them in file order", function()
    local requests = {}
    gh.api.get = function(opts)
      requests[opts.format.page] = opts.opts.cb
    end

    local pr = setmetatable({
      repo = "owner/repo",
      number = 1,
      files = {},
      changed_files_count = 201,
    }, { __index = PullRequest })
    local received
    local progress = {}
    pr:get_changed_files(function(files)
      received = files
    end, function(files)
      progress[#progress + 1] = #files
    end)

    eq(3, #requests)

    local function response(first, last)
      local files = {}
      for idx = first, last do
        files[#files + 1] = {
          filename = string.format("file-%03d.txt", idx),
          status = "modified",
          additions = 1,
          deletions = 0,
          changes = 1,
        }
      end
      return vim.json.encode(files)
    end

    requests[2](response(101, 200), "")
    eq({}, progress)
    requests[1](response(1, 100), "")
    eq({ 100, 200 }, progress)
    requests[3](response(201, 201), "")

    eq(201, #received)
    eq("file-001.txt", received[1].path)
    eq("file-201.txt", received[201].path)
    eq({ 100, 200, 201 }, progress)
  end)

  it("reports a page failure instead of completing with a partial file list", function()
    local request
    gh.api.get = function(opts)
      request = opts.opts.cb
    end

    local pr = setmetatable({ repo = "owner/repo", number = 1, files = {}, changed_files_count = 1 }, {
      __index = PullRequest,
    })
    local complete = false
    local error_message
    pr:get_changed_files(
      function()
        complete = true
      end,
      nil,
      function(message)
        error_message = message
      end
    )

    request(nil, "request failed")

    eq(false, complete)
    eq("request failed", error_message)
  end)

  it("rejects a changed-file response whose count differs from PR metadata", function()
    local request
    gh.api.get = function(opts)
      request = opts.opts.cb
    end

    local pr = setmetatable({ repo = "owner/repo", number = 1, files = {}, changed_files_count = 2 }, {
      __index = PullRequest,
    })
    local complete = false
    local error_message
    pr:get_changed_files(
      function()
        complete = true
      end,
      nil,
      function(message)
        error_message = message
      end
    )

    request(
      vim.json.encode {
        {
          filename = "only-file.txt",
          status = "modified",
          additions = 1,
          deletions = 0,
          changes = 1,
        },
      },
      ""
    )

    eq(false, complete)
    eq("Changed file count changed while loading (expected 2, received 1)", error_message)
  end)

  it("passes the exact merge base to the completed pull request", function()
    local original_commit_exists = utils.commit_exists
    local original_get = gh.api.get
    local merge_commit_checks = {}
    local early_left_ready
    local early_left_commit
    local early_pr
    local ready_pr
    utils.commit_exists = function(commit, callback)
      if commit == "merge-base-sha" then
        merge_commit_checks[#merge_commit_checks + 1] = commit
      end
      callback(false)
    end
    gh.api.get = function(opts)
      if opts[1] and opts[1]:find("compare", 1, true) then
        opts.opts.cb("merge-base-sha", "")
      end
    end

    local obj = {
      baseRefName = "main",
      headRefName = "topic",
      baseRefOid = "base-sha",
      headRefOid = "head-sha",
      changedFiles = 2,
      files = { nodes = {} },
    }
    local opts = {
      repo = "owner/repo",
      head_repo = "owner/repo",
      head_ref_name = "topic",
      number = 1,
      id = "pr-node",
    }

    pull_request_model.create_with_merge_base(opts, obj, function(pr)
      ready_pr = pr
    end, function(pr)
      early_pr = pr
      early_left_ready = pr.left_ready
      early_left_commit = pr.left.commit
    end)

    utils.commit_exists = original_commit_exists
    gh.api.get = original_get

    eq(false, early_left_ready)
    eq("base-sha", early_left_commit)
    eq("merge-base-sha", early_pr.left.commit)
    eq(true, early_pr.left_ready)
    eq(early_pr, ready_pr)
    eq({ "merge-base-sha" }, merge_commit_checks)
  end)
end)
