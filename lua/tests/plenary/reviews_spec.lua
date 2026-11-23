---@diagnostic disable
local reviews = require "octo.reviews"
local Layout = require("octo.reviews.layout").Layout
local Rev = require("octo.reviews.rev").Rev
local gh = require "octo.gh"
local utils = require "octo.utils"
local eq = assert.are.same

describe("Reviews module:", function()
  local original_reviews
  local original_layout_new
  local original_in_pr_branch
  local original_utils_error
  local original_graphql

  before_each(function()
    vim.cmd "tabonly!"
    original_reviews = reviews.reviews
    original_layout_new = Layout.new
    original_in_pr_branch = utils.in_pr_branch
    original_utils_error = utils.error
    original_graphql = gh.api.graphql
    reviews.reviews = {}
  end)

  after_each(function()
    vim.cmd "tabonly!"
    reviews.reviews = original_reviews
    Layout.new = original_layout_new
    utils.in_pr_branch = original_in_pr_branch
    utils.error = original_utils_error
    gh.api.graphql = original_graphql
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

  local function make_review_flow()
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
      data = { repository = { pullRequest = { reviewThreads = { nodes = { make_thread() } } } } },
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
      data = { repository = { pullRequest = { reviewThreads = { nodes = { make_thread() } } } } },
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
      ensure_layout = function() end,
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
