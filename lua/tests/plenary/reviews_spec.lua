---@diagnostic disable
local reviews = require "octo.reviews"
local Layout = require("octo.reviews.layout").Layout
local Rev = require("octo.reviews.rev").Rev
local gh = require "octo.gh"
local pull_request_model = require "octo.model.pull-request"
local utils = require "octo.utils"
local config = require "octo.config"
local eq = assert.are.same

describe("Reviews module:", function()
  local original_reviews
  local original_layout_new
  local original_in_pr_branch
  local original_utils_error
  local original_graphql
  local original_get
  local original_commit_exists
  local original_file_panel_icons
  local make_review_flow

  before_each(function()
    vim.cmd "tabonly!"
    original_reviews = reviews.reviews
    original_layout_new = Layout.new
    original_in_pr_branch = utils.in_pr_branch
    original_utils_error = utils.error
    original_graphql = gh.api.graphql
    original_get = gh.api.get
    original_commit_exists = utils.commit_exists
    original_file_panel_icons = config.values.file_panel.use_icons
    reviews.reviews = {}
  end)

  after_each(function()
    vim.cmd "tabonly!"
    reviews.reviews = original_reviews
    Layout.new = original_layout_new
    utils.in_pr_branch = original_in_pr_branch
    utils.error = original_utils_error
    gh.api.graphql = original_graphql
    gh.api.get = original_get
    utils.commit_exists = original_commit_exists
    config.values.file_panel.use_icons = original_file_panel_icons
  end)

  it("keeps the registered review tab open when merge-base resolution falls back to the base OID", function()
    config.values.file_panel.use_icons = false
    local reported_errors = {}
    utils.error = function(message)
      reported_errors[#reported_errors + 1] = message
    end
    utils.in_pr_branch = function()
      return true
    end
    utils.commit_exists = function(_, callback)
      callback(false)
    end
    local compare_requests = 0
    local files_endpoint_requested = false
    gh.api.get = function(opts)
      if opts[1] and opts[1]:find("compare", 1, true) then
        compare_requests = compare_requests + 1
        opts.opts.cb(nil, "deleted fork head", 404)
      elseif opts[1] and opts[1]:find("/files", 1, true) then
        files_endpoint_requested = true
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
      elseif opts.jq == "{base: .base.sha, head: .head.sha}" then
        opts.opts.cb(vim.json.encode { base = "captured-base", head = "captured-head" }, "")
      end
    end

    local early_review
    local ready_pull_request
    pull_request_model.create_with_merge_base({
      repo = "owner/repo",
      head_repo = "fork-owner/repo",
      head_ref_name = "deleted-branch",
      number = 19,
      id = "deleted-pr",
    }, {
      baseRefOid = "captured-base",
      headRefOid = "captured-head",
      baseRefName = "main",
      headRefName = "deleted-branch",
      changedFiles = 1,
      files = { nodes = {} },
    }, function(pr)
      ready_pull_request = pr
    end, function(pr)
      early_review = reviews.Review:new(pr)
      early_review.populate_threads = function(_, callback)
        callback {
          data = {
            repository = {
              pullRequest = {
                baseRefOid = "captured-base",
                headRefOid = "captured-head",
                reviewThreads = { nodes = {} },
              },
            },
          },
        }
      end
      early_review:browse()
    end)

    local layout = early_review.layout
    assert.are.same(early_review.pull_request, ready_pull_request)
    assert.are.same("captured-base", ready_pull_request.left.commit)
    assert.is_true(vim.api.nvim_tabpage_is_valid(layout.tabpage))
    assert.is_true(layout:is_live())
    eq(1, #layout.files)
    eq(1, compare_requests)
    eq(true, files_endpoint_requested)
    assert.is_true(reported_errors[1]:find("Failed to fetch merge base", 1, true) ~= nil)
    early_review:close_layout(layout)
  end)

  it("checks the captured thread revision before starting the review mutation", function()
    local mutation_requests = 0
    gh.api.graphql = function()
      mutation_requests = mutation_requests + 1
    end
    local review = setmetatable({
      pull_request = {
        id = "pr-node",
        hostname = "github.enterprise.internal",
        owner = "owner",
        name = "repo",
        number = 17,
        base_oid = "captured-base",
        head_oid = "captured-head",
      },
      populate_threads = function(_, callback)
        callback {
          data = {
            repository = {
              pullRequest = {
                baseRefOid = "captured-base",
                headRefOid = "moved-head",
                reviewThreads = { nodes = {} },
              },
            },
          },
        }
      end,
    }, { __index = reviews.Review })
    local error_message

    review:create(function()
      error "must not create a review against a changed thread revision"
    end, function(message)
      error_message = message
    end)

    eq(0, mutation_requests)
    eq("Pull request revision changed while loading review; reopen the review", error_message)
  end)

  it("pins the start-review mutation to the captured head commit", function()
    local request
    gh.api.graphql = function(opts)
      request = opts
    end
    local review = setmetatable({
      pull_request = {
        id = "pr-node",
        hostname = "github.enterprise.internal",
        owner = "owner",
        name = "repo",
        number = 17,
        base_oid = "captured-base",
        head_oid = "captured-head",
      },
      populate_threads = function(_, callback)
        callback {
          data = {
            repository = {
              pullRequest = {
                baseRefOid = "captured-base",
                headRefOid = "captured-head",
                reviewThreads = { nodes = {} },
              },
            },
          },
        }
      end,
    }, { __index = reviews.Review })

    review:create(function() end)

    assert.is_true(request.f.query:find 'commitOID: "captured%-head"' ~= nil)
  end)

  it("carries the pull request host through review-thread queries", function()
    local request
    gh.api.graphql = function(opts)
      request = opts
      opts.opts.cb(
        vim.json.encode { data = { repository = { pullRequest = { reviewThreads = { nodes = {} } } } } },
        "",
        0
      )
    end
    local review = setmetatable({
      pull_request = {
        hostname = "github.enterprise.internal",
        owner = "owner",
        name = "repo",
        number = 17,
      },
    }, { __index = reviews.Review })

    review:populate_threads(function() end)
    eq("github.enterprise.internal", request.opts.hostname)
  end)

  it("uses markdown for the review submission buffer", function()
    local review = setmetatable({ id = "pending_review" }, { __index = reviews.Review })

    review:collect_submit_info()

    local bufnr = review.submit_review_win.bufnr
    local filetype = vim.bo[bufnr].filetype
    vim.api.nvim_win_close(review.submit_review_win.winid, true)
    vim.api.nvim_buf_delete(bufnr, { force = true })

    eq("markdown", filetype)
  end)

  it("matches pull request repositories case-insensitively", function()
    local closed = false
    reviews.reviews.review = {
      id = -1,
      pull_request = { id = "stored_pr", repo = "pwntester/Octo.nvim", number = 1 },
      layout = {
        tabpage = vim.api.nvim_get_current_tabpage(),
        close = function()
          closed = true
        end,
      },
    }

    reviews.close_browse_reviews_for_pull_request {
      id = "target_pr",
      repo = "PWNTESTER/octo.NVIM",
      number = 1,
    }

    eq(true, closed)
  end)

  make_review_flow = function()
    local file_callbacks = {}
    local thread_callback
    local thread_error
    local opened_layout
    local pull_request = {
      id = "pr_1",
      repo = "owner/repo",
      owner = "owner",
      name = "repo",
      number = 1,
      base_oid = "base",
      head_oid = "head",
      left = { commit = "base" },
      right = { commit = "head" },
      get_changed_files = function(_, callback, on_page, on_error)
        file_callbacks = { complete = callback, page = on_page, error = on_error }
      end,
    }

    utils.in_pr_branch = function()
      return true
    end
    Layout.new = function(_, opts)
      opened_layout = {
        left = opts.left,
        right = opts.right,
        files = opts.files,
        selected_file_idx = 1,
        user_selected_file = false,
        file_panel = {
          files = opts.files,
          loading = false,
          render = function() end,
          redraw = function() end,
        },
        is_live = function(self)
          return self.live == true
        end,
        open = function(self, review)
          self.live = true
          self.tabpage = vim.api.nvim_get_current_tabpage()
          self.review = review
          reviews.reviews[tostring(self.tabpage)] = review
        end,
        close = function(self)
          self.live = false
          self.closed = true
        end,
        run_in_tabpage = function(self, callback)
          if self.live then
            callback()
          end
        end,
        get_current_file = function(self)
          return self.files[self.selected_file_idx]
        end,
        update_files = function(self)
          self.file_panel.files = self.files
          self.updates = (self.updates or 0) + 1
        end,
      }
      return opened_layout
    end

    local review = setmetatable(
      { pull_request = pull_request, id = -1, threads = {}, files = {} },
      { __index = reviews.Review }
    )
    review.populate_threads = function(_, callback, on_error)
      thread_callback = callback
      thread_error = on_error
    end
    return {
      review = review,
      file_callbacks = file_callbacks,
      get_file_callbacks = function()
        return file_callbacks
      end,
      get_thread_callback = function()
        return thread_callback
      end,
      get_thread_error = function()
        return thread_error
      end,
      get_layout = function()
        return opened_layout
      end,
    }
  end

  it("does not start a pending review after its loading tab is closed", function()
    local flow = make_review_flow()
    local mutation_requests = 0
    gh.api.graphql = function()
      mutation_requests = mutation_requests + 1
    end

    flow.review:start()
    local layout = flow.get_layout()
    layout:close()
    flow.get_thread_callback() {
      data = {
        repository = {
          pullRequest = {
            baseRefOid = "base",
            headRefOid = "head",
            reviewThreads = { nodes = {} },
          },
        },
      },
    }

    eq(false, layout.live)
    eq(0, mutation_requests)
  end)

  it("does not start a review when file loading fails before thread verification returns", function()
    local flow = make_review_flow()
    local mutation_requests = 0
    gh.api.graphql = function()
      mutation_requests = mutation_requests + 1
    end

    flow.review:start()
    local layout = flow.get_layout()
    flow.get_file_callbacks().error "file enumeration failed"
    flow.get_thread_callback() {
      data = {
        repository = {
          pullRequest = {
            baseRefOid = "base",
            headRefOid = "head",
            reviewThreads = { nodes = {} },
          },
        },
      },
    }

    eq(true, layout.closed)
    eq(0, mutation_requests)
  end)

  local function make_thread()
    return {
      id = "thread_1",
      subjectType = "LINE",
      isOutdated = false,
      isResolved = false,
      line = 2,
      startLine = 2,
      originalLine = 2,
      originalStartLine = 2,
      diffSide = "RIGHT",
      comments = {
        nodes = {
          {
            body = "pending body",
            state = "PENDING",
            pullRequestReview = { state = "PENDING" },
          },
        },
      },
    }
  end

  local function make_file()
    return {
      path = "file.lua",
      viewed_state = "UNVIEWED",
      is_ready_to_render = function()
        return false
      end,
    }
  end

  it("opens browse layout and loads threads before changed files", function()
    local flow = make_review_flow()
    flow.review:browse()
    local layout = flow.get_layout()
    local callbacks = flow.get_file_callbacks()

    eq(true, layout.live)
    eq(true, layout.file_panel.loading)
    eq(true, type(flow.get_thread_callback()) == "function")
    eq(true, type(callbacks.page) == "function")

    flow.get_thread_callback() {
      data = {
        repository = {
          pullRequest = {
            baseRefOid = "base",
            headRefOid = "head",
            reviewThreads = { nodes = { make_thread() } },
          },
        },
      },
    }
    eq("pending body", flow.review.threads.thread_1.comments.nodes[1].body)
    eq(0, #layout.files)

    local files = { make_file() }
    callbacks.page(files)
    eq(true, layout.file_panel.loading)
    callbacks.complete(files)

    eq(files, layout.files)
    eq(false, layout.file_panel.loading)
  end)

  it("renders changed files before review threads arrive", function()
    local flow = make_review_flow()
    flow.review:browse()
    local layout = flow.get_layout()
    local callbacks = flow.get_file_callbacks()
    local files = { make_file() }

    callbacks.page(files)
    callbacks.complete(files)
    eq(files, layout.files)
    eq(nil, flow.review.threads.thread_1)

    flow.get_thread_callback() {
      data = {
        repository = {
          pullRequest = {
            baseRefOid = "base",
            headRefOid = "head",
            reviewThreads = { nodes = { make_thread() } },
          },
        },
      },
    }
    eq("pending body", flow.review.threads.thread_1.comments.nodes[1].body)
  end)

  it("tears down the loading layout when the thread request fails", function()
    local flow = make_review_flow()
    local errors = {}
    utils.error = function(message)
      errors[#errors + 1] = message
    end
    flow.review:browse()
    local layout = flow.get_layout()

    flow.get_thread_error() "network unavailable"

    eq(true, layout.closed)
    eq({ "Failed to load review threads: network unavailable" }, errors)
  end)

  it("does not apply review threads after the PR revision is retargeted", function()
    local flow = make_review_flow()
    local errors = {}
    utils.error = function(message)
      errors[#errors + 1] = message
    end
    flow.review:browse()
    local layout = flow.get_layout()

    flow.get_thread_callback() {
      data = {
        repository = {
          pullRequest = {
            baseRefOid = "base",
            headRefOid = "new-head",
            reviewThreads = { nodes = { make_thread() } },
          },
        },
      },
    }

    eq(true, layout.closed)
    eq({}, flow.review.threads)
    eq({ "Pull request revision changed while loading review; reopen the review" }, errors)
  end)

  it("ignores file and thread results after the review tab closes", function()
    local flow = make_review_flow()
    flow.review:browse()
    local layout = flow.get_layout()
    local callbacks = flow.get_file_callbacks()
    layout.live = false

    flow.get_thread_callback() {
      data = { repository = { pullRequest = { reviewThreads = { nodes = { make_thread() } } } } },
    }
    local files = { make_file() }
    callbacks.page(files)
    callbacks.complete(files)

    eq(0, #layout.files)
    eq(0, layout.updates or 0)
    eq(nil, layout.closed)
  end)

  it("starts pending-review lookup concurrently with changed-file loading", function()
    local flow = make_review_flow()
    local pending_callback
    flow.review.retrieve_pending_state = function(_, callback)
      pending_callback = callback
    end

    flow.review:resume()

    eq(true, type(pending_callback) == "function")
    eq(true, type(flow.get_file_callbacks().page) == "function")
    pending_callback("pending-review", { make_thread() })
    eq("pending-review", flow.review.id)
    eq("pending body", flow.review.threads.thread_1.comments.nodes[1].body)
  end)

  local function assert_pending_review_tab_survives(action)
    Layout.new = original_layout_new
    utils.in_pr_branch = function()
      return true
    end

    local pull_request = {
      id = "pr_1",
      repo = "owner/repo",
      owner = "owner",
      name = "repo",
      number = 1,
      left = Rev:new "base",
      right = Rev:new "head",
      get_changed_files = function(_, callback)
        callback {}
      end,
    }
    local review = setmetatable({ pull_request = pull_request, id = -1, threads = {}, files = {} }, {
      __index = reviews.Review,
    })
    local pending_callback
    review.retrieve_pending_state = function(_, callback)
      pending_callback = callback
    end

    review[action](review)
    local layout = review.layout
    local tabpage = layout.tabpage
    eq(true, vim.api.nvim_tabpage_is_valid(tabpage))
    eq(review, reviews.reviews[tostring(tabpage)])

    pending_callback("pending-review", { make_thread() })

    eq("pending-review", review.id)
    eq(true, vim.api.nvim_tabpage_is_valid(tabpage))
    eq(review, reviews.reviews[tostring(tabpage)])
    review:close_layout(layout)
  end

  it("keeps the freshly opened registered tab when resuming a pending review", function()
    assert_pending_review_tab_survives "resume"
  end)

  it("keeps the freshly opened registered tab in the pending start-or-resume branch", function()
    assert_pending_review_tab_survives "start_or_resume"
  end)

  it("opens the loading layout before starting a review and closes an older browse tab", function()
    local flow = make_review_flow()
    vim.cmd "tabnew"
    local browse_tab = vim.api.nvim_get_current_tabpage()
    local browse_layout = {
      tabpage = browse_tab,
      close = function(self)
        self.closed = true
      end,
      on_enter = function() end,
      on_leave = function() end,
      on_win_leave = function() end,
    }
    reviews.reviews[tostring(browse_tab)] = {
      id = -1,
      pull_request = flow.review.pull_request,
      layout = browse_layout,
    }
    vim.cmd "tabnew"

    local create_callback
    flow.review.create = function(_, callback)
      create_callback = callback
    end
    flow.review:start()
    local layout = flow.get_layout()

    eq(true, layout.live)
    eq(true, layout.file_panel.loading)
    eq(true, type(create_callback) == "function")
    eq(true, type(flow.get_file_callbacks().page) == "function")

    create_callback {
      data = {
        addPullRequestReview = {
          pullRequestReview = {
            id = "pending_review",
            pullRequest = { reviewThreads = { nodes = {} } },
          },
        },
      },
    }

    eq("pending_review", flow.review.id)
    eq(true, browse_layout.closed)
  end)

  it("re-enters a loading layout asynchronously instead of synchronously fetching its file", function()
    local update_mode
    local layout = setmetatable({
      ready = true,
      files = {},
      file_panel = { loading = true },
      get_current_file = function()
        return nil
      end,
      update_files = function(_, async)
        update_mode = async
      end,
    }, { __index = Layout })

    layout:on_enter()

    eq(true, update_mode)
  end)

  it("does not recover an asynchronously updated review layout by switching tabs", function()
    vim.cmd "tabnew"
    local review_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd "tabnew"
    local user_tab = vim.api.nvim_get_current_tabpage()
    local recovery_count, render_count = 0, 0
    local pending_callback
    local file = {
      is_ready_to_render = function()
        return false
      end,
      fetch = function(_, _, on_complete)
        pending_callback = on_complete
      end,
      load_buffers = function()
        render_count = render_count + 1
      end,
      detach_buffers = function() end,
    }
    local layout = setmetatable({
      tabpage = review_tab,
      closed = false,
      files = { file },
      selected_file_idx = 1,
      file_panel = {
        mark_selected = function() end,
        set_cursor_to_file = function() end,
      },
      get_current_file = function()
        return file
      end,
      validate_layout = function()
        return { valid = false, tabpage = true, left_win = false, right_win = true }
      end,
      recover_layout = function()
        recovery_count = recovery_count + 1
        vim.api.nvim_set_current_tabpage(review_tab)
      end,
      prefetch_nearby_files = function() end,
    }, { __index = Layout })
    reviews.reviews[tostring(review_tab)] = { layout = layout }

    layout:set_current_file_async(file)
    pending_callback()

    eq(user_tab, vim.api.nvim_get_current_tabpage())
    eq(0, recovery_count)
    eq(0, render_count)
    vim.cmd "tabonly!"
  end)

  it("ignores files from an earlier focus_commit layout generation", function()
    local callbacks = {}
    local applied_files = {}
    local old_layout = { close = function() end }
    local original_layout_new = Layout.new
    Layout.new = function(_, opts)
      local layout = { right = opts.right, left = opts.left, files = {}, live = true }
      function layout:open() end
      function layout:close()
        self.live = false
      end
      function layout:is_live()
        return self.live
      end
      return layout
    end
    local pull_request = {
      left = { commit = "pr-base" },
      right = { commit = "pr-head" },
      get_commit_changed_files = function(_, rev, callback)
        callbacks[rev.commit] = callback
      end,
    }
    local review = setmetatable({ pull_request = pull_request, layout = old_layout }, { __index = reviews.Review })
    review.set_files_and_select_first = function(_, files)
      applied_files[#applied_files + 1] = files[1]
    end

    review:focus_commit("first-head", "first-base")
    review:focus_commit("second-head", "second-base")
    callbacks["first-head"] { "stale-file" }
    eq(0, #applied_files)
    callbacks["second-head"] { "current-file" }

    eq({ "current-file" }, applied_files)
    Layout.new = original_layout_new
  end)

  it("keeps stale file callbacks window-scoped and ignores errors after selection moves", function()
    local target_tab = vim.api.nvim_get_current_tabpage()
    local target_win = vim.api.nvim_get_current_win()
    vim.cmd "tabnew"
    local tab_enters = 0
    local group = vim.api.nvim_create_augroup("octo_review_async_test", { clear = true })
    vim.api.nvim_create_autocmd("TabEnter", {
      group = group,
      callback = function()
        tab_enters = tab_enters + 1
      end,
    })

    local stale_error
    local selected_file = {
      path = "stale.lua",
      is_ready_to_render = function()
        return false
      end,
      fetch = function(_, _, _, on_error)
        stale_error = on_error
      end,
      detach_buffers = function() end,
    }
    local next_file = {
      is_ready_to_render = function()
        return true
      end,
      load_buffers = function() end,
      detach_buffers = function() end,
    }
    local layout = setmetatable({
      tabpage = target_tab,
      left_winid = target_win,
      right_winid = target_win,
      files = { selected_file, next_file },
      selected_file_idx = 1,
      file_panel = {
        mark_selected = function() end,
        set_cursor_to_file = function() end,
      },
      async_file_loads = {},
      prefetch_nearby_files = function() end,
    }, { __index = Layout })
    local failure_count = 0
    local review = {
      layout = layout,
      fail_loading = function()
        failure_count = failure_count + 1
        layout.closed = true
      end,
    }
    layout.review = review
    reviews.reviews[tostring(target_tab)] = review

    layout:set_current_file_async(selected_file)
    layout:set_current_file_async(next_file)
    stale_error "late error from old selection"

    assert.are.same(next_file, layout:get_current_file())
    assert.are.same(0, failure_count)
    assert.is_falsy(layout.closed)
    assert.are.same(0, tab_enters)
    vim.api.nvim_del_augroup_by_id(group)
  end)

  it("fills a wide nearby prefetch window with bounded, selection-prioritized requests", function()
    local files = {}
    local fetched = {}
    local callbacks = {}
    for idx = 1, 1019 do
      files[idx] = {
        ready = false,
        is_ready_to_render = function(self)
          return self.ready
        end,
        fetch = function(self, sync, on_complete)
          fetched[#fetched + 1] = { idx, sync }
          self.left_fetching = true
          self.right_fetching = true
          callbacks[idx] = on_complete
        end,
        load_buffers = function() end,
        detach_buffers = function() end,
      }
    end
    local layout = setmetatable({
      files = files,
      selected_file_idx = 1,
      tabpage = vim.api.nvim_get_current_tabpage(),
      left_winid = vim.api.nvim_get_current_win(),
      right_winid = vim.api.nvim_get_current_win(),
      ensure_layout = function()
        return true
      end,
      file_safeguard = function()
        return false
      end,
      file_panel = {
        mark_selected = function() end,
        set_cursor_to_file = function() end,
      },
    }, { __index = Layout })
    local function complete(idx)
      files[idx].ready = true
      files[idx].left_fetching = false
      files[idx].right_fetching = false
      callbacks[idx]()
    end

    files[1].ready = true
    layout:set_current_file(files[1])
    eq({ { 2, false }, { 3, false }, { 4, false }, { 5, false } }, fetched)
    complete(2)
    eq({ 6, false }, fetched[5])
    files[500].ready = true
    layout:set_current_file(files[500])
    eq(5, #fetched)
    complete(3)
    eq({ 501, false }, fetched[6])
    files[1019].ready = true
    layout:set_current_file(files[1019])
    complete(4)
    eq({ 1018, false }, fetched[7])
    eq(4, layout.prefetching)
    layout.prefetch_closed = true
    complete(5)
    eq(7, #fetched)
  end)

  it("cleans up a review whose tab handle differs from its closed tab number", function()
    vim.cmd "tabnew"
    vim.cmd "tabnew"

    local review_tab = vim.api.nvim_get_current_tabpage()
    local review_key = tostring(review_tab)
    local review = {
      pull_request = { id = "pr_1", repo = "pwntester/octo.nvim", number = 1 },
      layout = {
        tabpage = review_tab,
        on_enter = function() end,
        on_leave = function() end,
        on_win_leave = function() end,
      },
    }
    reviews.reviews[review_key] = review

    vim.cmd "tabprevious"
    vim.cmd "tabclose"

    eq(review, reviews.reviews[review_key])
    eq(2, vim.fn.tabpagenr())

    vim.cmd "tabclose"
    reviews.cleanup_closed_tab(vim.fn.tabpagenr())

    eq(nil, reviews.reviews[review_key])
  end)
end)
