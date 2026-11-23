---@diagnostic disable

describe("Octo module:", function()
  local octo
  local gh
  local polling
  local original_get
  local original_graphql
  local original_load_preview
  local original_load
  local original_create_buffer
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
    original_load = octo.load
    original_create_buffer = octo.create_buffer
    original_track_buffer = polling.track_buffer
    original_octo_buffers = _G.octo_buffers
    created_buffers = {}
  end)

  after_each(function()
    gh.api.get = original_get
    gh.api.graphql = original_graphql
    octo.load_preview = original_load_preview
    octo.load = original_load
    octo.create_buffer = original_create_buffer
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

  local function install_async_load_stubs(render_issue)
    local requests = {}
    local rendered
    octo.load = function(_, _, _, _, callback, opts)
      requests[#requests + 1] = { callback = callback, opts = opts }
    end
    octo.create_buffer = function(_, obj)
      local bufnr = vim.api.nvim_get_current_buf()
      rendered = {
        bufnr = bufnr,
        node = obj,
        dirty = false,
        has_local_changes = function(self)
          return self.dirty
        end,
        update_node = function(self, node)
          self.node = node
        end,
        render_issue = function(self)
          if render_issue then
            render_issue(self)
          end
        end,
        render_discussion = function(self)
          self.discussion_rendered = (self.discussion_rendered or 0) + 1
        end,
        render_signs = function() end,
      }
      _G.octo_buffers[bufnr] = rendered
    end
    return requests, function()
      return rendered
    end
  end

  local function setup_issue_load_requests()
    local fragments = require "octo.gh.fragments"
    local queries = require "octo.gh.queries"
    fragments.setup()
    queries.setup()
    _G.octo_pv2_fragment = ""

    local requests = {}
    local shell_callback
    gh.api.graphql = function(opts)
      requests[#requests + 1] = opts
    end
    octo.load_preview = function(_, _, _, _, callback)
      shell_callback = callback
    end
    return requests, function(shell)
      shell_callback(shell)
    end, queries
  end

  local function setup_discussion_load_requests()
    local fragments = require "octo.gh.fragments"
    local queries = require "octo.gh.queries"
    fragments.setup()
    queries.setup()
    _G.octo_pv2_fragment = ""

    local requests = {}
    local shell_callback
    gh.api.graphql = function(opts)
      requests[#requests + 1] = opts
    end
    octo.load_preview = function(_, _, _, _, callback)
      shell_callback = callback
    end
    return requests, function(shell)
      shell_callback(shell)
    end, queries
  end

  local function issue_response(count, nodes)
    return vim.json.encode {
      data = {
        repository = {
          issue = {
            id = "issue-id",
            number = 17,
            title = "Issue",
            timelineItems = { filteredCount = count, nodes = nodes },
          },
        },
      },
    }
  end

  local function discussion_response(count, nodes)
    return vim.json.encode {
      data = {
        repository = {
          discussion = {
            id = "discussion-id",
            number = 17,
            title = "Discussion",
            comments = {
              totalCount = count,
              nodes = nodes,
              pageInfo = { hasPreviousPage = false, startCursor = "start" },
            },
          },
        },
      },
    }
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
    local phase_two_callback
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
        phase_two_callback = opts.opts.cb
      end
    end

    octo.load("owner/repo", "issue", 17, nil, function(obj)
      loaded = obj
    end)

    phase_two_callback(
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

    assert.is_true(fallback_used)
    assert.are.same(3, #loaded.timelineItems.nodes)
  end)

  it("starts full issue details concurrently and ignores a late shell after details win", function()
    local requests, deliver_shell = setup_issue_load_requests()
    local loaded
    local shells = 0

    octo.load("owner/repo", "issue", 17, nil, function(obj)
      loaded = obj
    end, {
      on_shell = function()
        shells = shells + 1
      end,
    })

    assert.are.same(1, #requests)
    assert.is_nil(requests[1].paginate)
    requests[1].opts.cb(issue_response(1, { { id = "detail-node" } }), nil)
    deliver_shell { timelineItems = { filteredCount = 1, nodes = { { id = "shell-node" } } } }

    assert.are.same(0, shells)
    assert.are.same("detail-node", loaded.timelineItems.nodes[1].id)
  end)

  it("renders the shell when it arrives before full issue details", function()
    local requests, deliver_shell = setup_issue_load_requests()
    local loaded
    local shells = 0

    octo.load("owner/repo", "issue", 17, nil, function(obj)
      loaded = obj
    end, {
      on_shell = function()
        shells = shells + 1
      end,
    })
    deliver_shell { timelineItems = { filteredCount = 1, nodes = { { id = "shell-node" } } } }

    assert.are.same(1, shells)
    requests[1].opts.cb(issue_response(1, { { id = "detail-node" } }), nil)

    assert.are.same("detail-node", loaded.timelineItems.nodes[1].id)
  end)

  it("fans out timeline pages before a late shell arrives", function()
    local requests, deliver_shell, queries = setup_issue_load_requests()
    local nodes = {}
    for index = 1, 100 do
      nodes[index] = { id = "node-" .. index }
    end
    local loaded
    local shells = 0

    octo.load("owner/repo", "issue", 17, nil, function(obj)
      loaded = obj
    end, {
      on_shell = function()
        shells = shells + 1
      end,
    })
    requests[1].opts.cb(issue_response(101, nodes), nil)

    assert.are.same(2, #requests)
    assert.are.same(queries.issue_timeline_page, requests[2].query)
    assert.are.same(100, requests[2].fields.skip)
    requests[2].opts.cb(issue_response(101, { { id = "node-101" } }), nil)
    deliver_shell { timelineItems = { filteredCount = 101, nodes = { { id = "shell-node" } } } }

    assert.are.same(0, shells)
    assert.are.same(101, #loaded.timelineItems.nodes)
  end)

  it("falls back to cursor pagination when a concurrent detail request fails", function()
    local requests, deliver_shell = setup_issue_load_requests()
    local loaded
    local shells = 0

    octo.load("owner/repo", "issue", 17, nil, function(obj)
      loaded = obj
    end, {
      on_shell = function()
        shells = shells + 1
      end,
    })
    requests[1].opts.cb("", "network failure")

    assert.are.same(2, #requests)
    assert.is_true(requests[2].paginate)
    requests[2].opts.cb(issue_response(1, { { id = "fallback-node" } }), nil)
    deliver_shell { timelineItems = { filteredCount = 1, nodes = { { id = "late-shell" } } } }

    assert.are.same(0, shells)
    assert.are.same("fallback-node", loaded.timelineItems.nodes[1].id)
  end)

  it("falls back to cursor pagination when a skip page fails", function()
    local requests, deliver_shell = setup_issue_load_requests()
    local nodes = {}
    for index = 1, 100 do
      nodes[index] = { id = "node-" .. index }
    end
    local loaded

    octo.load("owner/repo", "issue", 17, nil, function(obj)
      loaded = obj
    end)
    deliver_shell { timelineItems = { filteredCount = 101, nodes = { { id = "shell-node" } } } }
    requests[2].opts.cb("", "network failure")

    assert.are.same(3, #requests)
    assert.is_true(requests[3].paginate)
    requests[3].opts.cb(issue_response(101, nodes), nil)
    assert.are.same(100, #loaded.timelineItems.nodes)
  end)

  it("starts full discussion details concurrently and ignores a late shell after details win", function()
    local requests, deliver_shell, queries = setup_discussion_load_requests()
    local loaded
    local shells = 0

    octo.load("owner/repo", "discussion", 17, nil, function(obj)
      loaded = obj
    end, {
      on_shell = function()
        shells = shells + 1
      end,
    })

    assert.are.same(1, #requests)
    assert.are.same(queries.discussion_full_recent, requests[1].query)
    requests[1].opts.cb(discussion_response(1, { { id = "detail-comment" } }), nil)
    deliver_shell { comments = { totalCount = 1, nodes = { { id = "shell-comment" } } } }

    assert.are.same(0, shells)
    assert.are.same("detail-comment", loaded.comments.nodes[1].id)
  end)

  it("renders a discussion shell when it arrives before full details", function()
    local requests, deliver_shell = setup_discussion_load_requests()
    local loaded
    local shells = 0

    octo.load("owner/repo", "discussion", 17, nil, function(obj)
      loaded = obj
    end, {
      on_shell = function()
        shells = shells + 1
      end,
    })
    deliver_shell { comments = { totalCount = 1, nodes = { { id = "shell-comment" } } } }

    assert.are.same(1, shells)
    requests[1].opts.cb(discussion_response(1, { { id = "detail-comment" } }), nil)

    assert.are.same("detail-comment", loaded.comments.nodes[1].id)
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

  it("does not overwrite edits made while the second phase is loading", function()
    local bufnr = create_named_buffer "octo://owner/repo/pull/17"
    local requests, get_buffer = install_async_load_stubs()
    local local_changes = 0
    octo.load_buffer {
      bufnr = bufnr,
      on_local_changes = function()
        local_changes = local_changes + 1
      end,
    }

    requests[1].opts.on_shell { id = "shell" }
    local buffer = get_buffer()
    buffer.dirty = true
    requests[1].callback { id = "complete" }

    assert.are.same("shell", buffer.node.id)
    assert.are.same(1, local_changes)
  end)

  it("ignores callbacks from an older reload while the latest load wins", function()
    local bufnr = create_named_buffer "octo://owner/repo/issue/17"
    local requests, get_buffer = install_async_load_stubs()
    octo.load_buffer { bufnr = bufnr }
    octo.load_buffer { bufnr = bufnr }

    requests[1].opts.on_shell { id = "stale-shell" }
    assert.is_nil(get_buffer())
    requests[2].opts.on_shell { id = "current-shell" }
    requests[1].callback { id = "stale-complete" }
    requests[2].callback { id = "current-complete" }

    assert.are.same("current-complete", get_buffer().node.id)
  end)

  it("does not render after the target buffer closes mid-load", function()
    local bufnr = create_named_buffer "octo://owner/repo/discussion/17"
    local requests, get_buffer = install_async_load_stubs()
    local errors = 0
    octo.load_buffer {
      bufnr = bufnr,
      on_error = function()
        errors = errors + 1
      end,
    }
    vim.api.nvim_buf_delete(bufnr, { force = true })

    requests[1].opts.on_shell { id = "shell" }
    requests[1].callback { id = "complete" }

    assert.is_nil(get_buffer())
    assert.are.same(1, errors)
  end)

  it("preserves closed comment folds across the phase-two rerender", function()
    local constants = require "octo.constants"
    local bufnr = create_named_buffer "octo://owner/repo/pull/17"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "header", "body one", "body two", "body three", "tail" })
    local old_mark = vim.api.nvim_buf_set_extmark(bufnr, constants.OCTO_COMMENT_NS, 1, 0, { end_row = 4 })
    vim.cmd [[setlocal foldmethod=manual]]
    vim.cmd [[1,5fold]]
    vim.cmd [[1foldopen]]

    local requests, get_buffer = install_async_load_stubs(function(buffer)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "header", "body one", "body two", "body three", "tail" })
      local new_mark = vim.api.nvim_buf_set_extmark(bufnr, constants.OCTO_COMMENT_NS, 1, 0, { end_row = 4 })
      buffer.commentsMetadata = { { id = "comment-1", extmark = new_mark } }
      vim.cmd [[1,5fold]]
      vim.cmd [[1foldopen]]
    end)
    octo.load_buffer { bufnr = bufnr }
    requests[1].opts.on_shell { id = "shell" }
    get_buffer().commentsMetadata = { { id = "comment-1", extmark = old_mark } }
    vim.cmd [[1foldclose]]

    requests[1].callback { id = "complete" }

    assert.are.same(1, vim.fn.foldclosed(3))
  end)

  it("preserves the cursor moved during phase two and rerenders discussion buffers as discussions", function()
    local bufnr = create_named_buffer "octo://owner/repo/discussion/17"
    local requests, get_buffer = install_async_load_stubs(function(buffer)
      vim.api.nvim_buf_set_lines(buffer.bufnr, 0, -1, false, { "one", "two", "three", "four", "five" })
    end)
    octo.load_buffer { bufnr = bufnr }
    requests[1].opts.on_shell { id = "shell" }

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three", "four", "five" })
    vim.api.nvim_win_set_cursor(0, { 4, 2 })
    requests[1].callback { id = "complete" }

    assert.are.same({ 4, 2 }, vim.api.nvim_win_get_cursor(0))
    assert.are.same(1, get_buffer().discussion_rendered)
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
