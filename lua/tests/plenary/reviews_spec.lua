---@diagnostic disable
local reviews = require "octo.reviews"
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
