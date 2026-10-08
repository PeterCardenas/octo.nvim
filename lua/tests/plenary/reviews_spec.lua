---@diagnostic disable
local reviews = require "octo.reviews"
local Layout = require("octo.reviews.layout").Layout
local eq = assert.are.same

describe("Reviews module:", function()
  local original_reviews

  before_each(function()
    vim.cmd "tabonly!"
    original_reviews = reviews.reviews
    reviews.reviews = {}
  end)

  after_each(function()
    vim.cmd "tabonly!"
    reviews.reviews = original_reviews
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

  it("fetches the first unread file before rendering the layout", function()
    local review = setmetatable({ layout = { update_files = function() end } }, { __index = reviews.Review })
    local fetched = {}
    local files = {
      {
        viewed_state = "VIEWED",
        fetch = function(self, sync)
          table.insert(fetched, { self, sync })
        end,
      },
      {
        viewed_state = "UNVIEWED",
        fetch = function(self, sync)
          table.insert(fetched, { self, sync })
        end,
      },
      {
        viewed_state = "UNVIEWED",
        fetch = function(self, sync)
          table.insert(fetched, { self, sync })
        end,
      },
    }

    review:set_files_and_select_first(files)

    eq(files, review.layout.files)
    eq(2, review.layout.selected_file_idx)
    eq({ { files[2], true } }, fetched)
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
