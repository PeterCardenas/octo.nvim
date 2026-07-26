local Layout = require("octo.reviews.layout").Layout
local Rev = require("octo.reviews.rev").Rev
local config = require "octo.config"
local gh = require "octo.gh"
local queries = require "octo.gh.queries"
local graphql = require "octo.gh.graphql"
local thread_panel = require "octo.reviews.thread-panel"
local window = require "octo.ui.window"
local utils = require "octo.utils"
local ReviewThread = require("octo.reviews.thread").ReviewThread

---@alias ReviewLevel "COMMIT" | "PR"

---@class Review
---@field repo string
---@field number integer
---@field id string|-1
---@field threads octo.ReviewThread[]
---@field files FileEntry[]
---@field layout Layout
---@field pull_request PullRequest
local Review = {}
Review.__index = Review

local default_id = -1

---Review constructor.
---@param pull_request PullRequest
---@return Review
function Review:new(pull_request)
  local this = {
    pull_request = pull_request,
    id = default_id,
    threads = {},
    files = {},
  }
  setmetatable(this, self)
  return this
end

---Creates a new review
---@param callback fun(obj: octo.mutations.StartReview): nil
function Review:create(callback)
  local query = graphql("start_review_mutation", self.pull_request.id)
  gh.api.graphql {
    f = { query = query },
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local resp = vim.json.decode(output)
          callback(resp)
        end,
      },
    },
  }
end

---Get review threads without start a review.
---@param callback fun(obj: octo.queries.ReviewThreads): nil
function Review:populate_threads(callback)
  gh.api.graphql {
    query = queries.review_threads,
    F = { owner = self.pull_request.owner, name = self.pull_request.name, number = self.pull_request.number },
    opts = {
      cb = function(output, stderr)
        if stderr and not utils.is_blank(stderr) then
          utils.error(stderr)
        elseif output then
          local resp = vim.json.decode(output)
          callback(resp)
        end
      end,
    },
  }
end

function Review:browse()
  self:populate_threads(function(resp)
    local threads = resp.data.repository.pullRequest.reviewThreads.nodes
    self:update_threads(threads)
    self:initiate()
  end)
end

-- Starts a new review
function Review:start()
  self:create(function(resp)
    self.id = resp.data.addPullRequestReview.pullRequestReview.id
    local threads = resp.data.addPullRequestReview.pullRequestReview.pullRequest.reviewThreads.nodes
    self:update_threads(threads)
    self:initiate()
  end)
end

---Retrieves existing review
---@param callback fun(obj: octo.queries.PendingReviewThreads): nil
function Review:retrieve(callback)
  gh.api.graphql {
    query = queries.pending_review_threads,
    F = { owner = self.pull_request.owner, name = self.pull_request.name, number = self.pull_request.number },
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local resp = vim.json.decode(output)
          callback(resp)
        end,
      },
    },
  }
end

---@param review_nodes table[]
---@return string | nil
local function get_viewer_pending_review_id(review_nodes)
  for _, review in ipairs(review_nodes) do
    if review.viewerDidAuthor then
      return review.id
    end
  end
end

---@param callback fun(review_id: string | nil, threads: octo.ReviewThread[]): nil
function Review:retrieve_pending_state(callback)
  self:retrieve(function(resp)
    local pull_request = resp.data.repository.pullRequest
    callback(get_viewer_pending_review_id(pull_request.reviews.nodes), pull_request.reviewThreads.nodes)
  end)
end

---@param review Review
---@param review_id string
---@param threads octo.ReviewThread[]
local function initiate_pending_review(review, review_id, threads)
  review.id = review_id
  review:update_threads(threads)
  review:initiate()
end

-- Resumes an existing review
function Review:resume()
  self:retrieve_pending_state(function(review_id, threads)
    if not review_id then
      utils.error "No pending reviews found for viewer"
      return
    end

    initiate_pending_review(self, review_id, threads)
  end)
end

-- Resumes an existing review if there is any, else start one
function Review:start_or_resume()
  self:retrieve_pending_state(function(review_id, threads)
    if not review_id then
      utils.info "No pending review, starting one"
      self:start()
      return
    end

    utils.info "Resuming review"
    initiate_pending_review(self, review_id, threads)
  end)
end

---Register freshly fetched files as this review's files
---Selects and fetches the first unread files
---Defaults to the first file if all files are VIEWED
---@param files FileEntry[]
function Review:set_files_and_select_first(files)
  local selected_file_idx ---@type integer?
  for idx, file in ipairs(files) do
    if file.viewed_state ~= "VIEWED" then
      selected_file_idx = idx
      break
    end
  end

  if not selected_file_idx and #files > 0 then
    selected_file_idx = 1
  end

  self.layout.files = files
  if selected_file_idx then
    files[selected_file_idx]:fetch(true)
    self.layout.selected_file_idx = selected_file_idx
  end
  for _, file in ipairs(files) do
    file:fetch(false)
  end
  self.layout:update_files()
end

---Updates layout to focus on a single commit
---@param right string
---@param left string
function Review:focus_commit(right, left)
  local pr = self.pull_request
  self.layout:close()
  self.layout = Layout:new {
    right = Rev:new(right),
    left = Rev:new(left),
    files = {},
  }
  self.layout:open(self)
  local function cb(files)
    self:set_files_and_select_first(files)
  end
  if right == self.pull_request.right.commit and left == self.pull_request.left.commit then
    pr:get_changed_files(cb)
  else
    pr:get_commit_changed_files(self.layout.right, cb)
  end
end

---Initiates (starts/resumes) a review
---@param opts? { left?: Rev, right?: Rev }
function Review:initiate(opts)
  opts = opts or {}
  local pr = self.pull_request
  local conf = config.values
  if conf.use_local_fs and not utils.in_pr_branch(pr) then
    local choice = vim.fn.confirm("Currently not in PR branch, would you like to checkout?", "&Yes\n&No", 2)
    if choice == 1 then
      utils.checkout_pr_sync { repo = pr.repo, pr_number = pr.number }
    end
  end

  local left, right = opts.left or pr.left, opts.right or pr.right
  if not left.commit or not right.commit then
    utils.error "Cannot start review without commits"
    return
  end

  if self.id ~= default_id then
    require("octo.reviews").close_browse_reviews_for_pull_request(pr)
  end

  -- create the layout
  self.layout = Layout:new {
    left = opts.left or pr.left,
    right = opts.right or pr.right,
    files = {},
  }
  self.layout:open(self)

  pr:get_changed_files(function(files)
    self:set_files_and_select_first(files)
  end)
end

---Counts pending comments with non-empty bodies in review threads
---@see octo.PullRequestReviewState for explanation of why we check pullRequestReview.state
---@param threads octo.ReviewThread[]
---@return integer count The number of pending comments with content
local function count_pending_comments(threads)
  local count = 0
  for _, thread in ipairs(threads) do
    for _, comment in ipairs(thread.comments.nodes) do
      if comment.pullRequestReview.state == "PENDING" and not utils.is_blank(utils.trim(comment.body)) then
        count = count + 1
      end
    end
  end
  return count
end

---Discard the current review
---@param opts? { skip_confirm?: boolean } Options for discarding the review
function Review:discard(opts)
  opts = opts or {}
  local skip_confirm = opts.skip_confirm or false

  gh.api.graphql {
    query = queries.pending_review_threads,
    F = { owner = self.pull_request.owner, name = self.pull_request.name, number = self.pull_request.number },
    opts = {
      cb = function(output, stderr)
        if stderr and not utils.is_blank(stderr) then
          utils.error(stderr)
        elseif output then
          ---@type octo.queries.PendingReviewThreads
          local resp = vim.json.decode(output)
          if #resp.data.repository.pullRequest.reviews.nodes == 0 then
            utils.error "No pending reviews found"
            return
          end
          self.id = resp.data.repository.pullRequest.reviews.nodes[1].id

          local pending_count = count_pending_comments(resp.data.repository.pullRequest.reviewThreads.nodes)
          local choice = 1
          if pending_count > 0 and not skip_confirm then
            local message = string.format(
              "%d pending comment%s will be deleted, are you sure?",
              pending_count,
              pending_count == 1 and "" or "s"
            )
            choice = vim.fn.confirm(message, "&Yes\n&No\n&Cancel", 2)
          end

          if choice == 1 then
            local delete_query = graphql("delete_pull_request_review_mutation", self.id --[[@as string]])
            gh.api.graphql {
              f = { query = delete_query },
              opts = {
                cb = gh.create_callback {
                  success = function()
                    self.id = default_id
                    self.threads = {}
                    self.files = {}
                    utils.info "Pending review discarded"
                    require("octo.reviews").close_review(self)
                  end,
                },
              },
            }
          end
        end
      end,
    },
  }
end

---@param threads octo.ReviewThread[]
function Review:update_threads(threads)
  self.threads = {}
  for _, thread in ipairs(threads) do
    if thread.subjectType == "FILE" then
      -- File-level threads have no meaningful line numbers
      thread.line = 0
      thread.startLine = 0
      thread.originalLine = 0
      thread.originalStartLine = 0
      thread.startDiffSide = thread.diffSide
    else
      if thread.line == vim.NIL then
        thread.line = thread.originalLine
      end
      if thread.startLine == vim.NIL then
        thread.startLine = thread.line
        thread.startDiffSide = thread.diffSide
        thread.originalStartLine = thread.originalLine
      end
    end
    if not thread.isOutdated then
      self.threads[thread.id] = thread
    end
  end
  if self.layout then
    self.layout.file_panel:render()
    self.layout.file_panel:redraw()
    local file = self.layout:get_current_file()
    if file then
      file:place_signs()
    end
  end
end

function Review:collect_submit_info()
  if self.id == default_id then
    utils.error "No review in progress"
    return
  end
  if self.submit_review_win then
    utils.error "Review submit window already open"
    return
  end

  local conf = config.values
  local winid, bufnr = window.create_centered_float {
    header = string.format(
      "Press %s to approve, %s to comment or %s to request changes",
      conf.mappings.submit_win.approve_review.lhs,
      conf.mappings.submit_win.comment_review.lhs,
      conf.mappings.submit_win.request_changes.lhs
    ),
  }
  self.submit_review_win = {
    winid = winid,
    bufnr = bufnr,
  }
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(winid),
    once = true,
    callback = function()
      self.submit_review_win = nil
    end,
  })
  vim.api.nvim_set_current_win(winid)
  vim.bo[bufnr].syntax = "octo"
  utils.apply_mappings("submit_win", bufnr)
  vim.cmd [[normal G]]
end

---@param event "APPROVE" | "COMMENT" | "REQUEST_CHANGES"
function Review:submit(event)
  local review_id = self.id
  if review_id == -1 then
    utils.error "No review in progress"
    return
  end
  review_id = review_id --[[@as string]]
  local body = ""
  local winid ---@type integer?
  if self.submit_review_win then
    local bufnr = self.submit_review_win.bufnr
    winid = self.submit_review_win.winid
    self.submit_review_win = nil
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    body = utils.escape_char(utils.trim(table.concat(lines, "\n")))
  end
  local query = graphql("submit_pull_request_review_mutation", review_id, event, body, { escape = false })
  gh.api.graphql {
    f = { query = query },
    opts = {
      cb = gh.create_callback {
        success = function()
          utils.info "Review was submitted successfully!"
          pcall(vim.api.nvim_win_close, winid, 0)
          self.layout:close()
        end,
      },
    },
  }
end

function Review:show_pending_comments()
  local pending_threads = {}
  for _, thread in
    ipairs(vim.tbl_values(self.threads) --[[@as octo.ReviewThread[] ]])
  do
    for _, comment in ipairs(thread.comments.nodes) do
      if comment.pullRequestReview.state == "PENDING" and not utils.is_blank(utils.trim(comment.body)) then
        table.insert(pending_threads, thread)
      end
    end
  end
  if #pending_threads == 0 then
    utils.error "No pending comments found"
    return
  else
    require("octo.picker").pending_threads(pending_threads)
  end
end

---@param isSuggestion boolean
function Review:add_comment(isSuggestion)
  -- check if we are on the diff layout and return early if not
  local bufnr = vim.api.nvim_get_current_buf()
  local split, path = utils.get_split_and_path(bufnr)
  if not split or not path then
    return
  end

  local file = self.layout:get_current_file()
  if not file then
    return
  end

  -- get visual selected line range, used if coming from a keymap where current
  -- mode can be evaluated.
  local line1, line2 = utils.get_lines_from_context "visual"
  -- if we came from the command line the command options will provide line
  -- range
  if OctoLastCmdOpts ~= nil then
    line1 = OctoLastCmdOpts.line1
    line2 = OctoLastCmdOpts.line2
  end

  ---@type [integer, integer][], integer
  local comment_ranges, current_bufnr
  if split == "RIGHT" then
    comment_ranges = file.right_comment_ranges
    current_bufnr = file.right_bufid
  elseif split == "LEFT" then
    comment_ranges = file.left_comment_ranges
    current_bufnr = file.left_bufid
  else
    return
  end
  if not current_bufnr or not comment_ranges then
    utils.error "Failed to create comment"
    return
  end

  local diff_hunk ---@type string
  for i, range in ipairs(comment_ranges) do
    if range[1] <= line1 and range[2] >= line2 then
      diff_hunk = file.diffhunks[i]
      break
    end
  end
  if not diff_hunk then
    utils.error "Cannot place comments outside diff hunks"
    return
  end
  if not vim.startswith(diff_hunk, "@@") then
    diff_hunk = "@@ " .. diff_hunk
  end

  self.layout:ensure_both_windows()

  local alt_win = file:get_alternative_win(split)
  if vim.api.nvim_win_is_valid(alt_win) then
    local pr = file.pull_request

    -- create a thread stub representing the new comment

    ---@type string, string
    local commit, commit_abbrev
    if split == "LEFT" then
      commit = self.layout.left.commit
      commit_abbrev = self.layout.left:abbrev()
    elseif split == "RIGHT" then
      commit = self.layout.right.commit
      commit_abbrev = self.layout.right:abbrev()
    end
    local threads = {
      ReviewThread:stub {
        line1 = line1,
        line2 = line2,
        file_path = file.path,
        split = split,
        diff_hunk = diff_hunk,
        commit = commit,
        commit_abbrev = commit_abbrev,
        review_id = self.id,
      },
    }

    -- Make sure review thread panel is visible if not already
    -- The thread panel could be hidden if user has `reviews.auto_show_threads` set to false in their config
    -- or, less likely, if the add comment command is invoked before the autocmd has concluded,
    thread_panel.show_review_threads(false)
    local thread_buffer = thread_panel.create_thread_buffer(threads, pr.repo, pr.number, split, file.path)
    if thread_buffer then
      table.insert(file.associated_bufs, thread_buffer.bufnr)
      vim.api.nvim_win_set_buf(alt_win, thread_buffer.bufnr)
      vim.api.nvim_set_current_win(alt_win)
      if isSuggestion then
        local lines = vim.api.nvim_buf_get_lines(current_bufnr, line1 - 1, line2 --[[@as integer]], false)
        local suggestion = { "```suggestion" }
        vim.list_extend(suggestion, lines)
        table.insert(suggestion, "```")
        vim.api.nvim_buf_set_lines(thread_buffer.bufnr, -3, -2, false, suggestion)
        vim.bo[thread_buffer.bufnr].modified = false
      end
      thread_buffer:configure()
      vim.cmd [[diffoff!]]
      vim.cmd [[normal! vvGk]]
      vim.cmd [[startinsert]]

      vim.keymap.set("n", "q", function()
        thread_panel.hide_thread_buffer(split, file)
        local file_win = file:get_win(split)
        if vim.api.nvim_win_is_valid(file_win) then
          vim.api.nvim_set_current_win(file_win)
        end
      end, { buffer = thread_buffer.bufnr })
    end
  else
    utils.error("Cannot find diff window " .. alt_win)
  end
end

---Add a file-level review comment (not tied to a specific line).
function Review:add_file_comment()
  local bufnr = vim.api.nvim_get_current_buf()
  local split, path = utils.get_split_and_path(bufnr)
  if not split or not path then
    return
  end

  local file = self.layout:get_current_file()
  if not file then
    return
  end

  local review_level = self:get_level()
  if review_level == "COMMIT" then
    utils.error "File-level comments are not supported at the commit level"
    return
  end

  self.layout:ensure_both_windows()

  local alt_win = file:get_alternative_win(split)
  if vim.api.nvim_win_is_valid(alt_win) then
    local pr = file.pull_request

    local commit = self.layout.right.commit
    local commit_abbrev = self.layout.right:abbrev()

    local threads = {
      ReviewThread:stub {
        line1 = nil,
        line2 = nil,
        file_path = file.path,
        split = split,
        diff_hunk = "",
        commit = commit,
        commit_abbrev = commit_abbrev,
        review_id = self.id,
        subjectType = "FILE",
      },
    }

    thread_panel.show_review_threads(false)
    local thread_buffer = thread_panel.create_thread_buffer(threads, pr.repo, pr.number, split, file.path)
    if thread_buffer then
      table.insert(file.associated_bufs, thread_buffer.bufnr)
      vim.api.nvim_win_set_buf(alt_win, thread_buffer.bufnr)
      vim.api.nvim_set_current_win(alt_win)
      thread_buffer:configure()
      vim.cmd [[diffoff!]]
      vim.cmd [[normal! vvGk]]
      vim.cmd [[startinsert]]

      vim.keymap.set("n", "q", function()
        thread_panel.hide_thread_buffer(split, file)
        local file_win = file:get_win(split)
        if vim.api.nvim_win_is_valid(file_win) then
          vim.api.nvim_set_current_win(file_win)
        end
      end, { buffer = thread_buffer.bufnr })
    end
  else
    utils.error("Cannot find diff window " .. alt_win)
  end
end

---Get the review level, aka whether the review is at commit or PR level
---@return ReviewLevel
function Review:get_level()
  if
    self.layout.left.commit == self.pull_request.left.commit
    and self.layout.right.commit == self.pull_request.right.commit
  then
    return "PR"
  end
  return "COMMIT"
end

local M = {}

---@type table<string, Review>
M.reviews = {}

M.Review = Review

---@class octo.ReviewTarget
---@field id string
---@field repo string
---@field number integer

---@param pull_request PullRequest
---@return octo.ReviewTarget
local function get_review_target(pull_request)
  return {
    id = pull_request.id,
    repo = pull_request.repo,
    number = pull_request.number,
  }
end

---@param review Review
---@param target octo.ReviewTarget
---@return boolean
local function review_matches_target(review, target)
  local review_pr = review.pull_request
  local matches_id = target.id and review_pr.id == target.id
  local matches_number = review_pr.repo == target.repo and tonumber(review_pr.number) == tonumber(target.number)
  return matches_id or matches_number
end

---@param target octo.ReviewTarget
---@return Review[]
local function get_reviews_for_target(target)
  local matches = {}

  for _, review in pairs(M.reviews) do
    if review_matches_target(review, target) then
      table.insert(matches, review)
    end
  end

  return matches
end

---@param target octo.ReviewTarget
---@return Review | nil, boolean
local function get_review_for_target(target)
  local matches = get_reviews_for_target(target)
  if #matches <= 1 then
    return matches[1], false
  end

  utils.error(string.format("Found multiple active reviews for PR #%s", target.number))
  return nil, true
end

---@param pull_request PullRequest
---@return Review | nil, boolean
local function get_or_create_review_for_pull_request(pull_request)
  local review, duplicate_reviews = get_review_for_target(get_review_target(pull_request))
  if duplicate_reviews then
    return nil, true
  end

  return review or Review:new(pull_request), false
end

---@param review Review
---@return boolean
local function focus_review(review)
  if not review or not review.layout then
    return false
  end

  review.layout:ensure_layout()
  if review.layout.tabpage and vim.api.nvim_tabpage_is_valid(review.layout.tabpage) then
    vim.api.nvim_set_current_tabpage(review.layout.tabpage)
    return true
  end

  return false
end

---@param buffer OctoBuffer
---@return Review | nil, boolean
local function get_review_for_pull_request_buffer(buffer)
  if not buffer:isPullRequest() then
    return nil, false
  end

  return get_review_for_target {
    id = buffer:pullRequest().id,
    repo = buffer.repo,
    number = buffer.number,
  }
end

---@param winid integer
---@param bufnr integer
---@return Review | nil
local function get_review_for_submit_window(winid, bufnr)
  for _, review in pairs(M.reviews) do
    local submit_review_win = review.submit_review_win
    if submit_review_win and (submit_review_win.winid == winid or submit_review_win.bufnr == bufnr) then
      return review
    end
  end
end

---@param review Review
local function close_submit_review_win(review)
  local submit_review_win = review.submit_review_win
  if not submit_review_win then
    return
  end

  review.submit_review_win = nil

  if submit_review_win.winid and vim.api.nvim_win_is_valid(submit_review_win.winid) then
    pcall(vim.api.nvim_win_close, submit_review_win.winid, true)
  end
end

local function cleanup_invalid_reviews()
  for key, review in pairs(M.reviews) do
    local layout = review.layout
    local tabpage = layout and layout.tabpage
    if not tabpage or not vim.api.nvim_tabpage_is_valid(tabpage) then
      close_submit_review_win(review)
      M.reviews[key] = nil
    end
  end
end

---@param review Review | nil
---@return boolean
local function is_browse_review(review)
  return review ~= nil and review.id == default_id
end

---@param review Review
---@return boolean
local function focus_existing_review(review)
  if not review then
    return false
  end

  if review.id ~= default_id then
    if not focus_review(review) then
      utils.error "A pending review is already active for this PR"
    end
    return true
  end

  return false
end

---@param review Review
---@return Review | nil
local function prepare_review_for_pending_action(review)
  if focus_existing_review(review) then
    return
  end

  if is_browse_review(review) and review.layout then
    return Review:new(review.pull_request)
  end

  return review
end

---@param isSuggestion boolean
function M.add_review_comment(isSuggestion)
  local review = M.get_current_review()

  if not review then
    error "Could not find review"
  end

  -- we maybe in browse mode, where no review has been started.
  if review.id == -1 then
    utils.error "Please start or resume a review first"
    return
  end

  review:add_comment(isSuggestion)
end

function M.add_file_comment()
  local review = M.get_current_review()

  if not review then
    error "Could not find review"
  end

  if review.id == -1 then
    utils.error "Please start or resume a review first"
    return
  end

  review:add_file_comment()
end

---@param thread ReviewThread
function M.jump_to_pending_review_thread(thread)
  local current_review = M.get_current_review()
  if not current_review then
    return
  end
  for _, file in ipairs(current_review.layout.files) do
    if thread.path == file.path then
      current_review.layout:ensure_layout()
      current_review.layout:set_current_file(file)
      local win = file:get_win(thread.diffSide)
      if vim.api.nvim_win_is_valid(win) then
        local review_level = current_review:get_level()
        -- jumping to the original position in case we are reviewing any commit
        -- jumping to the PR position if we are reviewing the last commit
        -- This may result in a jump to the wrong line when the review is neither in the last commit or the original one
        local line = review_level == "COMMIT" and thread.originalStartLine or thread.startLine
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { line, 0 })
      else
        utils.error "Cannot find diff window"
      end
      break
    end
  end
end

--- Get the review associated with a specific tabpage.
--- @param tabpage? integer
--- @return Review | nil
function M.get_tab_review(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  return M.reviews[tostring(tabpage)]
end

--- Get the current review from the review tab, submit float, or PR buffer.
--- @return Review | nil
function M.get_current_review()
  local submit_review = get_review_for_submit_window(vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf())
  if submit_review then
    return submit_review
  end

  local buffer = utils.get_current_buffer()
  if buffer and buffer:isPullRequest() then
    local review, duplicate_reviews = get_review_for_pull_request_buffer(buffer)
    if duplicate_reviews then
      return
    end

    -- PR buffers resolve review state by exact PR identity and must not fall
    -- back to whichever review happens to own the current tabpage.
    return review
  end

  local current_review = M.get_tab_review()
  if current_review then
    return current_review
  end
end

--- Get the diff Layout of the review if any
--- @return Layout | nil
function M.get_current_layout()
  local current_review = M.get_tab_review()
  if current_review then
    return current_review.layout
  end
end

function M.on_tab_enter()
  local current_review = M.get_tab_review()
  if current_review and current_review.layout then
    current_review.layout:on_enter()
  end
end

function M.on_tab_leave()
  local current_review = M.get_tab_review()
  if current_review and current_review.layout then
    current_review.layout:on_leave()
  end
end

function M.on_win_leave()
  local current_review = M.get_tab_review()
  if current_review and current_review.layout then
    current_review.layout:on_win_leave()
  end
end

function M.cleanup_closed_tab(tabpage)
  cleanup_invalid_reviews()
end

---@param pull_request PullRequest
function M.close_browse_reviews_for_pull_request(pull_request)
  for _, review in ipairs(get_reviews_for_target(get_review_target(pull_request))) do
    if review.id == default_id then
      M.close_review(review)
    end
  end
end

---@param review Review
function M.close_review(review)
  if not review then
    return
  end

  close_submit_review_win(review)

  local layout = review.layout
  if not layout then
    return
  end

  local tabpage = layout.tabpage
  if tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
    layout:close()
  else
    M.cleanup_closed_tab(tabpage)
  end
end

function M.close_current_review()
  local current_review = M.get_current_review()
  if not current_review then
    utils.error "Please start or resume a review first"
    return
  end

  M.close_review(current_review)
end

--- Get the pull request associated with current buffer.
--- Fall back to pull request associated with the current branch if not in an Octo buffer.
--- @param cb fun(pull_request: PullRequest?): nil
local function get_pr_from_buffer_or_current_branch(cb)
  local buffer = utils.get_current_buffer()

  if not buffer then
    -- We are not in an octo buffer, try and fallback to the current branch's pr
    utils.get_pull_request_for_current_branch(cb)
    return
  end

  if buffer:isPullRequest() then
    buffer:get_pr(cb)
  else
    utils.get_pull_request_for_current_branch(cb)
  end
end

---@param cb fun(review: Review): nil
local function with_current_pr_review(cb)
  local current_review = M.get_current_review()
  if current_review then
    cb(current_review)
    return
  end

  get_pr_from_buffer_or_current_branch(function(pull_request)
    if not pull_request then
      return
    end

    local review, duplicate_reviews = get_or_create_review_for_pull_request(pull_request)
    if duplicate_reviews or not review then
      return
    end

    cb(review)
  end)
end

---@param method "start" | "resume" | "start_or_resume"
local function run_review_action(method)
  with_current_pr_review(function(review)
    local next_review = prepare_review_for_pending_action(review)
    if next_review then
      next_review[method](next_review)
    end
  end)
end

function M.browse_review()
  with_current_pr_review(function(review)
    if not is_browse_review(review) then
      utils.error "Cannot browse when a review has been started"
      return
    end

    if review.layout then
      focus_review(review)
      return
    end

    review:browse()
  end)
end

function M.start_review()
  run_review_action "start"
end

function M.resume_review()
  run_review_action "resume"
end

function M.start_or_resume_review()
  run_review_action "start_or_resume"
end

function M.discard_review()
  local current_review = M.get_current_review()
  if current_review and current_review.id ~= -1 then
    current_review:discard()
  else
    utils.error "Please start or resume a review first"
  end
end

function M.submit_review()
  local current_review = M.get_current_review()
  if current_review and current_review.id ~= -1 then
    current_review:collect_submit_info()
  else
    utils.error "Please start or resume a review first"
  end
end

return M
