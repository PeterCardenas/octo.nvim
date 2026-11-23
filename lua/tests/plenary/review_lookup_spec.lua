---@diagnostic disable
local gh = require "octo.gh"
local pull_request_model = require "octo.model.pull-request"
local utils = require "octo.utils"
local eq = assert.are.same

describe("current branch review lookup", function()
  local original_graphql
  local original_run
  local original_parse_git_remote
  local original_create_with_merge_base
  local original_system
  local branch
  local remote_name

  before_each(function()
    original_graphql = gh.api.graphql
    original_run = gh.run
    original_parse_git_remote = utils.parse_git_remote
    original_create_with_merge_base = pull_request_model.create_with_merge_base
    original_system = vim.fn.system
    original_system "true"
    branch = "review-branch"
    remote_name = "origin"
    vim.fn.system = function(command)
      if type(command) == "table" and command[1] == "git" and command[2] == "branch" then
        return branch .. "\n"
      elseif type(command) == "table" and command[1] == "git" and command[2] == "config" then
        return remote_name .. "\n"
      end
      return original_system(command)
    end
  end)

  after_each(function()
    gh.api.graphql = original_graphql
    gh.run = original_run
    utils.parse_git_remote = original_parse_git_remote
    pull_request_model.create_with_merge_base = original_create_with_merge_base
    vim.fn.system = original_system
  end)

  local function stub_head_remote(repo)
    utils.parse_git_remote = function()
      local remotes = { origin = { repo = repo, host = "github.com" } }
      if remote_name ~= "" then
        remotes[remote_name] = { repo = repo, host = "github.com" }
      end
      return remotes
    end
  end

  local function make_pr(number, base_repo, head_repo, ref)
    return {
      id = "pr-node-" .. number,
      number = number,
      state = "OPEN",
      baseRepository = { nameWithOwner = base_repo },
      headRepository = { nameWithOwner = head_repo },
      headRefName = ref,
      headRefOid = "head-sha",
      baseRefName = "main",
      baseRefOid = "base-sha",
      changedFiles = 2,
      files = { nodes = { { path = "file.lua", viewerViewedState = "UNVIEWED" } } },
    }
  end

  it("looks up a unique PR associated with the current head ref in one lightweight query", function()
    stub_head_remote "imu-useful/neovim"
    local query_options
    local create_options
    local received_pr
    local early_pr
    gh.api.graphql = function(opts)
      query_options = opts
      opts.opts.cb(
        vim.json.encode {
          data = {
            repository = {
              ref = {
                associatedPullRequests = { nodes = { make_pr(42959, "neovim/neovim", "imu-useful/neovim", branch) } },
              },
            },
          },
        },
        "",
        0
      )
    end
    gh.run = function()
      error "gh pr view should not run when the head ref has a unique associated PR"
    end
    pull_request_model.create_with_merge_base = function(opts, obj, callback, on_early)
      create_options = opts
      eq("file.lua", obj.files.nodes[1].path)
      if on_early then
        on_early { phase = "early" }
      end
      callback { phase = "ready" }
    end

    utils.get_pull_request_for_current_branch(function(pr)
      received_pr = pr
    end, function(pr)
      early_pr = pr
    end)

    eq("refs/heads/" .. branch, query_options.F.ref)
    eq("imu-useful", query_options.F.owner)
    eq("neovim", query_options.F.name)
    eq(nil, query_options.paginate)
    eq("neovim/neovim", create_options.repo)
    eq("imu-useful/neovim", create_options.head_repo)
    eq({ phase = "early" }, early_pr)
    eq({ phase = "ready" }, received_pr)
    assert(query_options.query:find("associatedPullRequests", 1, true))
    assert(not query_options.query:find("timelineItems", 1, true))
  end)

  it("falls back to gh pr view and preserves cross-repository base resolution", function()
    stub_head_remote "fork-owner/neovim"
    local graph_calls = {}
    local create_options
    local received_pr
    gh.api.graphql = function(opts)
      graph_calls[#graph_calls + 1] = opts
      if #graph_calls == 1 then
        opts.opts.cb(
          vim.json.encode {
            data = { repository = { ref = { associatedPullRequests = { nodes = {} } } } },
          },
          "",
          0
        )
      else
        opts.opts.cb(
          vim.json.encode {
            data = {
              repository = {
                pullRequest = make_pr(123, "neovim/neovim", "fork-owner/neovim", branch),
              },
            },
          },
          "",
          0
        )
      end
    end
    gh.run = function(opts)
      eq({ "pr", "view", "--json", "id,number,headRepositoryOwner,headRepository,isCrossRepository,url" }, opts.args)
      opts.cb(
        vim.json.encode {
          id = "pr-node-123",
          number = 123,
          headRepositoryOwner = { login = "fork-owner", name = "neovim" },
          headRepository = { name = "neovim" },
          isCrossRepository = true,
          url = "https://github.com/neovim/neovim/pull/123",
        },
        "",
        0
      )
    end
    pull_request_model.create_with_merge_base = function(opts, _, callback)
      create_options = opts
      callback { id = opts.id }
    end

    utils.get_pull_request_for_current_branch(function(pr)
      received_pr = pr
    end)

    eq(2, #graph_calls)
    eq("neovim", graph_calls[2].F.owner)
    eq("neovim", graph_calls[2].F.name)
    eq(123, graph_calls[2].F.number)
    eq(nil, graph_calls[2].paginate)
    eq("neovim/neovim", create_options.repo)
    eq("fork-owner/neovim", create_options.head_repo)
    eq({ id = "pr-node-123" }, received_pr)
    assert(not graph_calls[2].query:find("timelineItems", 1, true))
  end)
end)
