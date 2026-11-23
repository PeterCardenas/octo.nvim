---@diagnostic disable

describe("Octo module:", function()
  local octo
  local gh
  local polling
  local original_get
  local original_graphql
  local original_load_preview
  local original_track_buffer
  local original_octo_buffers
  local created_buffers

  before_each(function()
    package.loaded["octo"] = nil
    octo = require "octo"
    gh = require "octo.gh"
    polling = require "octo.polling"
    original_get = gh.api.get
    original_graphql = gh.api.graphql
    original_load_preview = octo.load_preview
    original_track_buffer = polling.track_buffer
    original_octo_buffers = _G.octo_buffers
    created_buffers = {}
  end)

  after_each(function()
    gh.api.get = original_get
    gh.api.graphql = original_graphql
    octo.load_preview = original_load_preview
    polling.track_buffer = original_track_buffer
    _G.octo_buffers = original_octo_buffers
    for _, bufnr in ipairs(created_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end)

  local function create_named_buffer(name)
    local bufnr = vim.api.nvim_create_buf(false, true)
    table.insert(created_buffers, bufnr)
    vim.api.nvim_buf_set_name(bufnr, name)
    vim.api.nvim_set_current_buf(bufnr)
    return bufnr
  end

  it("navigates to numeric URL anchors", function()
    local received
    local octo_buffer = {
      navigate_to_comment = function(_, opts)
        received = opts
      end,
    }

    assert.has_no.errors(function()
      octo.navigate_to_anchor(octo_buffer, 3185672857)
    end)
    assert.are.same({ databaseId = 3185672857 }, received)
  end)

  it("loads pull request diff buffers from octo URIs", function()
    local graphql_opts
    local get_opts
    local tracked_bufnr
    local bufnr = create_named_buffer "octo://owner/repo/pull/7/diff"

    gh.api.graphql = function(opts)
      graphql_opts = opts
      opts.opts.cb(
        vim.json.encode {
          data = {
            repository = {
              pullRequest = {
                title = "Add descriptive pull diff titles",
                updatedAt = "2026-07-02T00:00:00Z",
                baseRefOid = "base",
                headRefOid = "head",
              },
            },
          },
        },
        nil
      )
    end
    gh.api.get = function(opts)
      get_opts = opts
      opts.opts.cb("diff --git a/file.lua b/file.lua\n@@ -1 +1 @@\n-old\n+new", nil)
    end
    polling.track_buffer = function(value)
      tracked_bufnr = value
    end

    octo.load_buffer { bufnr = bufnr }

    assert.are.same({ owner = "owner", name = "repo", number = 7 }, graphql_opts.F)
    assert.are.same("/repos/{repo}/pulls/{number}", get_opts[1])
    assert.are.same({ repo = "owner/repo", number = "7" }, get_opts.format)
    assert.are.same("base...head", _G.octo_buffers[bufnr]:get_diff_fingerprint())
    assert.are.same("diff", vim.bo[bufnr].filetype)
    assert.are.same(false, vim.bo[bufnr].modifiable)
    assert.are.same(true, vim.bo[bufnr].readonly)
    assert.are.same(false, vim.bo[bufnr].modified)
    assert.are.same("pull_diff", _G.octo_buffers[bufnr].kind)
    assert.are.same("owner/repo", _G.octo_buffers[bufnr].repo)
    assert.are.same(7, _G.octo_buffers[bufnr].number)
    assert.are.same("Add descriptive pull diff titles", _G.octo_buffers[bufnr].titleMetadata.body)
    assert.are.same(tracked_bufnr, bufnr)
    assert.are.same({
      "diff --git a/file.lua b/file.lua",
      "@@ -1 +1 @@",
      "-old",
      "+new",
    }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("deduplicates preview fetches and reuses the short-lived shell cache", function()
    local fragments = require "octo.gh.fragments"
    local queries = require "octo.gh.queries"
    fragments.setup()
    queries.setup()
    _G.octo_pv2_fragment = ""

    local requests = {}
    gh.api.graphql = function(opts)
      requests[#requests + 1] = opts
    end

    local completed = 0
    local obj = { id = "issue-id", number = 9, title = "Preview" }
    octo.load_preview("owner/repo", "issue", 9, nil, function(result)
      assert.are.same(obj, result)
      completed = completed + 1
    end)
    octo.load_preview("owner/repo", "issue", 9, nil, function(result)
      assert.are.same(obj, result)
      completed = completed + 1
    end)

    assert.are.same(1, #requests)
    requests[1].opts.cb(vim.json.encode { data = { repository = { issue = obj } } }, nil)
    assert.are.same(2, completed)

    octo.load_preview("owner/repo", "issue", 9, nil, function(result)
      assert.are.same(obj, result)
      completed = completed + 1
    end)
    assert.is_true(vim.wait(100, function()
      return completed == 3
    end))
    assert.are.same(1, #requests)
  end)

  it("loads timeline pages at exact boundaries and preserves groups across page edges", function()
    local fragments = require "octo.gh.fragments"
    local queries = require "octo.gh.queries"
    fragments.setup()
    queries.setup()
    _G.octo_pv2_fragment = ""

    local function make_node(index, count)
      if count == 101 and index == 100 then
        return { id = "node-100", __typename = "LabeledEvent", label = { name = "first" } }
      elseif count == 101 and index == 101 then
        return { id = "node-101", __typename = "UnlabeledEvent", label = { name = "second" } }
      end
      return { id = "node-" .. index, __typename = "UnusedEvent" }
    end

    for _, count in ipairs { 0, 20, 21, 100, 101, 200, 201 } do
      local expected_nodes = {}
      for index = 1, count do
        expected_nodes[index] = make_node(index, count)
      end
      local latest_nodes = {}
      for index = math.max(1, count - 19), count do
        latest_nodes[#latest_nodes + 1] = expected_nodes[index]
      end
      octo.load_preview = function(_, _, _, _, callback)
        callback { timelineItems = { filteredCount = count, nodes = latest_nodes } }
      end

      local requested_skips = {}
      local loaded
      gh.api.graphql = function(opts)
        if opts.query == queries.issue_timeline_page then
          local skip = opts.fields.skip
          requested_skips[#requested_skips + 1] = skip
          local nodes = {}
          for index = skip + 1, math.min(count, skip + 100) do
            nodes[#nodes + 1] = expected_nodes[index]
          end
          opts.opts.cb(
            vim.json.encode {
              data = {
                repository = {
                  issue = { timelineItems = { filteredCount = count, nodes = nodes } },
                },
              },
            },
            nil
          )
        else
          local nodes = {}
          for index = 1, math.min(count, 100) do
            nodes[#nodes + 1] = expected_nodes[index]
          end
          opts.opts.cb(
            vim.json.encode {
              data = {
                repository = {
                  issue = { timelineItems = { filteredCount = count, nodes = nodes } },
                },
              },
            },
            nil
          )
        end
      end

      octo.load("owner/repo", "issue", 17, nil, function(obj)
        loaded = obj
      end)

      assert.is_table(loaded, "load should complete for " .. count .. " timeline nodes")
      assert.are.same(count, #loaded.timelineItems.nodes)
      local expected_skips = {}
      for skip = 100, count - 1, 100 do
        expected_skips[#expected_skips + 1] = skip
      end
      assert.are.same(expected_skips, requested_skips)
      if count == 101 then
        local groups = require("octo.ui.writers").order_timeline_groups(loaded.timelineItems.nodes, "oldest_first")
        assert.are.same("labels", groups[#groups].key)
        assert.are.same({ "node-100", "node-101" }, {
          groups[#groups].items[1].id,
          groups[#groups].items[2].id,
        })
      end
    end
  end)

  it("falls back to cursor pagination when phase data changes during the parallel fetch", function()
    local fragments = require "octo.gh.fragments"
    local queries = require "octo.gh.queries"
    fragments.setup()
    queries.setup()
    _G.octo_pv2_fragment = ""
    octo.load_preview = function(_, _, _, _, callback)
      callback { timelineItems = { filteredCount = 2, nodes = {} } }
    end

    local fallback_used = false
    local loaded
    gh.api.graphql = function(opts)
      if opts.paginate then
        fallback_used = true
        opts.opts.cb(
          vim.json.encode {
            data = {
              repository = {
                issue = {
                  timelineItems = {
                    nodes = {
                      { id = "node-1" },
                      { id = "node-2" },
                      { id = "node-3" },
                    },
                  },
                },
              },
            },
          },
          nil
        )
      else
        opts.opts.cb(
          vim.json.encode {
            data = {
              repository = {
                issue = {
                  timelineItems = {
                    filteredCount = 3,
                    nodes = { { id = "node-1" }, { id = "node-2" }, { id = "node-3" } },
                  },
                },
              },
            },
          },
          nil
        )
      end
    end

    octo.load("owner/repo", "issue", 17, nil, function(obj)
      loaded = obj
    end)

    assert.is_true(fallback_used)
    assert.are.same(3, #loaded.timelineItems.nodes)
  end)

  it("accepts a successful REST diff when gh writes informational stderr", function()
    gh.api.get = function(opts)
      opts.opts.cb("diff --git a/file b/file\n", "non-error gh hint", 0)
    end
    gh.api.graphql = function(opts)
      opts.opts.cb(
        vim.json.encode {
          data = {
            repository = {
              pullRequest = {
                title = "Pull diff title",
                updatedAt = "2026-01-01T00:00:00Z",
                baseRefOid = "base",
                headRefOid = "head",
              },
            },
          },
        },
        nil
      )
    end

    local loaded
    octo.load_pull_diff("owner/repo", 7, nil, function(obj)
      loaded = obj
    end)

    assert.is_table(loaded)
    assert.are.same("diff --git a/file b/file\n", loaded.diff)
    assert.are.same("base...head", loaded.diffFingerprint)
  end)

  it("starts pull diff fingerprint and REST requests concurrently", function()
    local requests = {}
    gh.api.get = function(opts)
      requests[#requests + 1] = "diff"
      assert.are.same("/repos/{repo}/pulls/{number}", opts[1])
    end
    gh.api.graphql = function(opts)
      requests[#requests + 1] = "fingerprint"
      assert.is_string(opts.query)
      assert.matches("baseRefOid", opts.query)
    end

    octo.load_pull_diff("owner/repo", 7, nil, function() end)

    assert.are.same({ "diff", "fingerprint" }, requests)
  end)

  it("passes hostname when loading pull request diff buffers", function()
    local graphql_opts
    local get_opts
    local bufnr = create_named_buffer "octo://github.enterprise.com/owner/repo/pull/7/diff"

    gh.api.graphql = function(opts)
      graphql_opts = opts
      opts.opts.cb(
        vim.json.encode {
          data = {
            repository = {
              pullRequest = {
                baseRefOid = "base",
                headRefOid = "head",
              },
            },
          },
        },
        nil
      )
    end
    gh.api.get = function(opts)
      get_opts = opts
      opts.opts.cb("", nil)
    end
    polling.track_buffer = function() end

    octo.load_buffer { bufnr = bufnr }

    assert.are.same("github.enterprise.com", graphql_opts.opts.hostname)
    assert.are.same("github.enterprise.com", get_opts.opts.hostname)
  end)
end)
