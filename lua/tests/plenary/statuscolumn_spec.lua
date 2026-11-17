---@diagnostic disable
local statuscolumn = require "octo.ui.statuscolumn"
local eq = assert.are.same

local corners = {
  top = "┌╴",
  middle = "│ ",
  last = "└╴",
  single = "[ ",
}

local function setup_win(lines, width)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = 20,
    row = 0,
    col = 0,
  })
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].foldmethod = "manual"
  return bufnr, win
end

local function teardown(bufnr, win)
  statuscolumn.reset(bufnr)
  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function corner(bufnr, win, lnum, virtnum)
  local sign = statuscolumn.get_sign(bufnr, lnum, virtnum, win)
  return sign and sign.text
end

describe("statuscolumn", function()
  it("draws comment corners across wrapped lines", function()
    local bufnr, win = setup_win({ "first", "middle", string.rep("x", 30) }, 20)
    statuscolumn.add(bufnr, 0, 2, false)

    eq(corners.top, corner(bufnr, win, 1, 0))
    eq(corners.middle, corner(bufnr, win, 2, 0))
    eq(corners.middle, corner(bufnr, win, 3, 0))
    eq(corners.last, corner(bufnr, win, 3, 1))

    teardown(bufnr, win)
  end)

  it("uses the single corner only when the comment fits one screen row", function()
    local bufnr, win = setup_win({ "short", string.rep("y", 30) }, 20)
    statuscolumn.add(bufnr, 0, 0, false)
    statuscolumn.add(bufnr, 1, 1, false)

    eq(corners.single, corner(bufnr, win, 1, 0))
    eq(corners.top, corner(bufnr, win, 2, 0))
    eq(corners.last, corner(bufnr, win, 2, 1))

    teardown(bufnr, win)
  end)

  it("ends the comment on a closed fold that reaches its last line", function()
    local bufnr, win = setup_win({ "a", "b", "c", "d" }, 40)
    statuscolumn.add(bufnr, 0, 3, false)

    vim.cmd "2,4fold"
    eq(corners.top, corner(bufnr, win, 1, 0))
    eq(corners.last, corner(bufnr, win, 2, 0))

    vim.cmd "normal! zE"
    vim.cmd "1,4fold"
    eq(corners.single, corner(bufnr, win, 1, 0))

    teardown(bufnr, win)
  end)

  -- Regression: measuring the whole comment for every screen row made redraws
  -- O(rows * comment lines), which lagged scrolling and typing in long PRs.
  it("only measures the comment's last line, and only while drawing it", function()
    local lines = {}
    for i = 1, 50 do
      lines[i] = "line " .. i
    end
    local bufnr, win = setup_win(lines, 40)
    statuscolumn.add(bufnr, 0, 49, false)

    local measured = {}
    local text_height = vim.api.nvim_win_text_height
    vim.api.nvim_win_text_height = function(w, opts)
      measured[#measured + 1] = { opts.start_row, opts.end_row }
      return text_height(w, opts)
    end
    local ok, err = pcall(function()
      for lnum = 1, 49 do
        statuscolumn.get_sign(bufnr, lnum, 0, win)
      end
      eq({}, measured)
      statuscolumn.get_sign(bufnr, 50, 0, win)
    end)
    vim.api.nvim_win_text_height = text_height
    assert(ok, err)
    eq({ { 49, 49 } }, measured)

    teardown(bufnr, win)
  end)
end)
