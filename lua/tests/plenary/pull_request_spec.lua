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
  local original_graphql
  local original_commit_exists

  before_each(function()
    original_get = gh.api.get
    original_graphql = gh.api.graphql
    original_commit_exists = utils.commit_exists
  end)

  after_each(function()
    gh.api.get = original_get
    gh.api.graphql = original_graphql
    utils.commit_exists = original_commit_exists
  end)

  local function revision_json(base, head)
    return vim.json.encode { base = base, head = head }
  end

  it("loads more than 300 changed files from paginated PR files after validating the pinned revision", function()
    local requests = {}
    gh.api.get = function(opts)
      requests[#requests + 1] = opts
      if opts[1]:find("/files", 1, true) then
        local pages = {}
        for page = 1, 4 do
          local files = {}
          local first = (page - 1) * 100 + 1
          local last = page == 4 and 305 or page * 100
          for index = first, last do
            files[#files + 1] = {
              filename = string.format("file-%03d.txt", index),
              status = "modified",
              additions = 1,
              deletions = 0,
              changes = 1,
            }
          end
          pages[#pages + 1] = files
        end
        opts.opts.cb(vim.json.encode(pages), "")
      else
        opts.opts.cb(revision_json("base-oid", "head-oid"), "")
      end
    end

    local pr = setmetatable({
      repo = "owner/repo",
      number = 1,
      files = {},
      hostname = "github.enterprise.internal",
      base_oid = "base-oid",
      head_oid = "head-oid",
      left = { commit = "base-oid" },
      right = { commit = "head-oid" },
      changed_files_count = 305,
    }, { __index = PullRequest })
    local received
    local error_message
    pr:get_changed_files(
      function(files)
        received = files
      end,
      nil,
      function(message)
        error_message = message
      end
    )

    eq(nil, error_message)
    eq(305, #received)
    eq("file-305.txt", received[305].path)
    eq(3, #requests)
    eq("github.enterprise.internal", requests[1].opts.hostname)
    eq(true, requests[2].paginate)
    eq(true, requests[2].slurp)
    eq("/repos/{repo}/pulls/{number}/files", requests[2][1])
  end)

  it("carries the resolved host through revision and changed-file requests", function()
    local requests = {}
    gh.api.get = function(opts)
      requests[#requests + 1] = opts
      if opts[1]:find("/files", 1, true) then
        opts.opts.cb("[]", "")
      else
        opts.opts.cb(revision_json("base-oid", "head-oid"), "")
      end
    end

    local pr = setmetatable({
      repo = "owner/repo",
      number = 1,
      files = {},
      hostname = "github.enterprise.internal",
      base_oid = "base-oid",
      head_oid = "head-oid",
      left = { commit = "base-oid" },
      right = { commit = "head-oid" },
      changed_files_count = 0,
    }, { __index = PullRequest })
    pr:get_changed_files(function() end)

    eq(3, #requests)
    for _, request in ipairs(requests) do
      eq("github.enterprise.internal", request.opts.hostname)
    end
  end)

  it("uses paginated PR files and verifies the immutable head before and after loading", function()
    local requests = {}
    gh.api.get = function(opts)
      requests[#requests + 1] = opts
      if opts[1]:find("/files", 1, true) then
        opts.opts.cb(
          vim.json.encode {
            {
              {
                filename = "file.lua",
                status = "modified",
                additions = 1,
                deletions = 0,
                changes = 1,
              },
            },
          },
          ""
        )
      else
        opts.opts.cb(revision_json("snapshot-base-oid", "snapshot-head-oid"), "")
      end
    end

    local pr = setmetatable({
      repo = "owner/repo",
      number = 1,
      files = {},
      hostname = "github.enterprise.internal",
      base_oid = "snapshot-base-oid",
      head_oid = "snapshot-head-oid",
      left = { commit = "merge-base-oid" },
      right = { commit = "snapshot-head-oid" },
      changed_files_count = 1,
    }, { __index = PullRequest })
    local received
    local progress
    pr:get_changed_files(function(files)
      received = files
    end, function(files)
      progress = files
    end)

    eq(3, #requests)
    eq("/repos/{repo}/pulls/{number}/files", requests[2][1])
    eq(true, requests[2].paginate)
    eq(true, requests[2].slurp)
    eq("{base: .base.sha, head: .head.sha}", requests[1].jq)
    eq("{base: .base.sha, head: .head.sha}", requests[3].jq)
    eq("file.lua", received[1].path)
    eq(received, progress)
  end)

  it("accepts successful paginated files with informational gh stderr", function()
    gh.api.get = function(opts)
      if opts[1]:find("/files", 1, true) then
        opts.opts.cb("[[]]", "hint: use gh event listen", 0)
      else
        opts.opts.cb(revision_json("base-oid", "head-oid"), "", 0)
      end
    end

    local pr = setmetatable({
      repo = "owner/repo",
      number = 1,
      files = {},
      head_oid = "head-oid",
      left = { commit = "base-oid" },
      right = { commit = "head-oid" },
      changed_files_count = 0,
    }, { __index = PullRequest })
    local completed = false
    local error_message
    pr:get_changed_files(
      function()
        completed = true
      end,
      nil,
      function(message)
        error_message = message
      end
    )

    eq(true, completed)
    eq(nil, error_message)
  end)

  it("reports a head revision change that occurs during the paginated file load", function()
    local head_lookups = 0
    gh.api.get = function(opts)
      if opts[1]:find("/files", 1, true) then
        opts.opts.cb(
          vim.json.encode {
            {
              {
                filename = "file.lua",
                status = "modified",
                additions = 1,
                deletions = 0,
                changes = 1,
              },
            },
          },
          ""
        )
      else
        head_lookups = head_lookups + 1
        opts.opts.cb(
          head_lookups == 1 and revision_json("base-oid", "head-oid") or revision_json("base-oid", "moved-head"),
          ""
        )
      end
    end

    local pr = setmetatable({
      repo = "owner/repo",
      number = 1,
      files = {},
      head_oid = "head-oid",
      left = { commit = "base-oid" },
      right = { commit = "head-oid" },
      changed_files_count = 1,
    }, { __index = PullRequest })
    local completed = false
    local error_message
    pr:get_changed_files(
      function()
        completed = true
      end,
      nil,
      function(message)
        error_message = message
      end
    )

    eq(false, completed)
    eq("Pull request head changed while loading review; reopen the review", error_message)
  end)

  it("rejects a same-count file list when only the base revision moved", function()
    local revision_callbacks = {}
    local files_callback
    local requests = {}
    gh.api.get = function(opts)
      requests[#requests + 1] = opts
      if opts[1]:find("/files", 1, true) then
        files_callback = opts.opts.cb
      else
        revision_callbacks[#revision_callbacks + 1] = opts.opts.cb
      end
    end

    local pr = setmetatable({
      repo = "owner/repo",
      number = 1,
      files = {},
      base_oid = "base-oid",
      head_oid = "head-oid",
      left = { commit = "base-oid" },
      right = { commit = "head-oid" },
      changed_files_count = 1,
    }, { __index = PullRequest })
    local completed = false
    local error_message
    pr:get_changed_files(
      function()
        completed = true
      end,
      nil,
      function(message)
        error_message = message
      end
    )

    eq(2, #requests)
    revision_callbacks[1](revision_json("base-oid", "head-oid"), "", 0)
    files_callback(
      vim.json.encode {
        {
          {
            filename = "same-count.lua",
            status = "modified",
            additions = 1,
            deletions = 0,
            changes = 1,
          },
        },
      },
      "",
      0
    )
    eq(3, #requests)
    revision_callbacks[2](revision_json("moved-base", "head-oid"), "", 0)

    eq(false, completed)
    eq("Pull request base changed while loading review; reopen the review", error_message)
  end)

  it("reports a paginated files failure instead of completing a partial list", function()
    local file_request
    gh.api.get = function(opts)
      if opts[1]:find("/files", 1, true) then
        file_request = opts.opts.cb
      else
        opts.opts.cb(revision_json("base-oid", "head-oid"), "")
      end
    end

    local pr = setmetatable({
      repo = "owner/repo",
      number = 1,
      files = {},
      head_oid = "head-oid",
      left = { commit = "base-oid" },
      right = { commit = "head-oid" },
      changed_files_count = 1,
    }, { __index = PullRequest })
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

    file_request(nil, "request failed")

    eq(false, complete)
    eq("request failed", error_message)
  end)

  it("rejects a changed-file response whose count differs from PR metadata", function()
    gh.api.get = function(opts)
      if opts[1]:find("/files", 1, true) then
        opts.opts.cb(
          vim.json.encode {
            {
              {
                filename = "only-file.txt",
                status = "modified",
                additions = 1,
                deletions = 0,
                changes = 1,
              },
            },
          },
          ""
        )
      else
        opts.opts.cb(revision_json("base-oid", "head-oid"), "")
      end
    end

    local pr = setmetatable({
      repo = "owner/repo",
      number = 1,
      files = {},
      head_oid = "head-oid",
      left = { commit = "base-oid" },
      right = { commit = "head-oid" },
      changed_files_count = 2,
    }, { __index = PullRequest })
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

    eq(false, complete)
    eq("Changed file count changed while loading (expected 2, received 1)", error_message)
  end)

  it("compares cross-fork PR revisions by immutable OIDs", function()
    local original_commit_exists = utils.commit_exists
    local original_get = gh.api.get
    local merge_commit_checks = {}
    local compare_request
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
        compare_request = opts
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
      head_repo = "fork-owner/repo",
      head_ref_name = "topic",
      hostname = "github.enterprise.internal",
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
    eq("repos/owner/repo/compare/base-sha...head-sha", compare_request[1])
    eq("github.enterprise.internal", compare_request.opts.hostname)
  end)

  it("hydrates missing review-file metadata before constructing a pull request", function()
    require("octo.gh.queries").setup()
    local metadata_request
    gh.api.graphql = function(opts)
      metadata_request = opts
      opts.opts.cb(
        vim.json.encode {
          data = {
            repository = {
              pullRequest = {
                baseRefOid = "base-oid",
                headRefOid = "head-oid",
                changedFiles = 1,
                files = { nodes = { { path = "hydrated.lua", viewerViewedState = "UNVIEWED" } } },
              },
            },
          },
        },
        "",
        0
      )
    end
    utils.commit_exists = function(_, callback)
      callback(false)
    end
    gh.api.get = function(opts)
      if opts[1] and opts[1]:find("compare", 1, true) then
        opts.opts.cb("merge-base-oid", "")
      end
    end

    local ready_pr
    local failed
    assert.has_no.errors(function()
      pull_request_model.create_with_merge_base(
        {
          repo = "owner/repo",
          head_repo = "owner/repo",
          head_ref_name = "topic",
          number = 27,
          id = "incomplete-full-pull",
        },
        {
          baseRefName = "main",
          headRefName = "topic",
          baseRefOid = "base-oid",
          headRefOid = "head-oid",
          changedFiles = 1,
        },
        function(pr)
          ready_pr = pr
        end,
        nil,
        function(message)
          failed = message
        end
      )
    end)

    assert.is_not_nil(metadata_request)
    eq("owner", metadata_request.F.owner)
    eq("UNVIEWED", ready_pr.files["hydrated.lua"])
    eq(nil, failed)
  end)

  it("uses the captured OIDs for merged pull requests", function()
    local original_commit_exists = utils.commit_exists
    local original_get = gh.api.get
    local compare_request
    utils.commit_exists = function(_, callback)
      callback(false)
    end
    gh.api.get = function(opts)
      if opts[1] and opts[1]:find("compare", 1, true) then
        compare_request = opts
        opts.opts.cb("merged-base-oid", "")
      end
    end

    local merged = {
      baseRefOid = "merged-base-oid",
      headRefOid = "merged-head-oid",
      baseRefName = "main",
      headRefName = "topic",
      merged = true,
      changedFiles = 0,
      files = { nodes = {} },
    }
    local ready_pr
    pull_request_model.create_with_merge_base(
      {
        repo = "owner/repo",
        head_repo = "owner/repo",
        head_ref_name = "topic",
        number = 9,
        id = "merged-pr",
      },
      merged,
      function(pr)
        ready_pr = pr
      end
    )

    utils.commit_exists = original_commit_exists
    gh.api.get = original_get

    eq("repos/owner/repo/compare/merged-base-oid...merged-head-oid", compare_request[1])
    eq("merged-head-oid", ready_pr.right.commit)
    eq("merged-base-oid", ready_pr.left.commit)
  end)

  it("falls back to the captured base OID when a deleted fork head cannot be compared", function()
    local original_error = utils.error
    local reported_errors = {}
    utils.error = function(message)
      reported_errors[#reported_errors + 1] = message
    end
    utils.commit_exists = function(_, callback)
      callback(false)
    end
    local compare_request
    gh.api.get = function(opts)
      if opts[1] and opts[1]:find("compare", 1, true) then
        compare_request = opts
        opts.opts.cb(nil, "head commit is no longer reachable", 404)
      end
    end

    local ready_pr
    local error_callback_called = false
    pull_request_model.create_with_merge_base(
      {
        repo = "owner/repo",
        head_repo = "fork-owner/repo",
        head_ref_name = "deleted-branch",
        number = 42,
        id = "deleted-head-pr",
      },
      {
        baseRefName = "main",
        headRefName = "deleted-branch",
        baseRefOid = "captured-base-oid",
        headRefOid = "captured-head-oid",
        changedFiles = 0,
        files = { nodes = {} },
      },
      function(pr)
        ready_pr = pr
      end,
      nil,
      function()
        error_callback_called = true
      end
    )

    utils.error = original_error

    eq("repos/owner/repo/compare/captured-base-oid...captured-head-oid", compare_request[1])
    eq("captured-base-oid", ready_pr.left.commit)
    eq(true, ready_pr.left_ready)
    eq(false, error_callback_called)
    assert.is_true(reported_errors[1]:find("Failed to fetch merge base", 1, true) ~= nil)
  end)
end)
