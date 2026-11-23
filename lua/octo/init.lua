local OctoBuffer = require("octo.model.octo-buffer").OctoBuffer
local autocmds = require "octo.autocmds"
local config = require "octo.config"
local constants = require "octo.constants"
local commands = require "octo.commands"
local completion = require "octo.completion"
local folds = require "octo.folds"
local gh = require "octo.gh"
local headers = require "octo.gh.headers"
local queries = require "octo.gh.queries"
local graphql = require "octo.gh.graphql"
local picker = require "octo.picker"
local reviews = require "octo.reviews"
local signs = require "octo.ui.signs"
local window = require "octo.ui.window"
local colors = require "octo.ui.colors"
local persistent_cache = require "octo.cache"
local writers = require "octo.ui.writers"
local utils = require "octo.utils"
local uri = require "octo.uri"
local vim = vim

---@type table<string, { number: integer, title: string }[]>
_G.octo_repo_issues = {}
---@type table<integer, OctoBuffer>
_G.octo_buffers = {}

local M = {}
local next_load_generation = 0
local next_auth_generation = 0
local active_auth_loads = {} ---@type table<integer, integer>
local active_loads = {} ---@type table<integer, integer>
local cached_indicator_ns = vim.api.nvim_create_namespace "octo_persistent_cache"

---@param bufnr integer
local function mark_cached(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, cached_indicator_ns, 0, -1)
  vim.api.nvim_buf_set_extmark(bufnr, cached_indicator_ns, 0, 0, {
    virt_text = { { " (cached)", "Comment" } },
    virt_text_pos = "eol",
  })
  vim.b[bufnr].octo_cached = true
end

---@param bufnr integer
local function clear_cached_mark(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local was_cached = vim.b[bufnr].octo_cached == true
  vim.api.nvim_buf_clear_namespace(bufnr, cached_indicator_ns, 0, -1)
  vim.b[bufnr].octo_cached = nil
  if was_cached and vim.api.nvim_buf_is_loaded(bufnr) then
    -- Diff buffers can keep showing virtual text until their window is redrawn.
    vim.api.nvim__redraw { buf = bufnr, valid = false, flush = true }
  end
end

---@param hostname string?
---@return string
local function resolve_hostname(hostname)
  if not utils.is_blank(hostname) then
    return hostname
  end
  if not utils.is_blank(config.values.github_hostname) then
    return config.values.github_hostname
  end
  return utils.get_remote_host() or "github.com"
end

---@param bufnr integer
---@param cached boolean
function M.set_cached_indicator(bufnr, cached)
  if cached then
    mark_cached(bufnr)
  else
    clear_cached_mark(bufnr)
  end
end

---Invalidate async loads tied to a buffer that is unloading or changing identity.
---@param bufnr integer
function M.invalidate_load(bufnr)
  active_loads[bufnr] = nil
  active_auth_loads[bufnr] = nil
end

function M.setup(user_config)
  if not vim.fn.has "nvim-0.7" then
    utils.error "octo.nvim requires neovim 0.7+"
    return
  end

  config.setup(user_config or {})
  if not vim.fn.executable(config.values.gh_cmd) then
    utils.error("gh executable not found using path: " .. config.values.gh_cmd)
    return
  end

  colors.setup()
  signs.setup()
  picker.setup()
  completion.setup()
  folds.setup()
  autocmds.setup()
  commands.setup()
  utils.apply_mappings "global"
  gh.setup()
end

function M.update_layout_for_current_file()
  local bufnr = vim.api.nvim_get_current_buf()
  local thisfile = vim.api.nvim_buf_get_name(bufnr)
  local relative_path = vim.fn.fnamemodify(thisfile, ":~:.")
  local review = reviews.get_current_review()
  if review == nil then
    return
  end
  local files = review.layout.files
  for _, file in ipairs(files) do
    if file.path == relative_path then
      review.layout:set_current_file(file)
      vim.api.nvim_set_current_win(review.layout.right_winid)
    end
  end
end

function M.configure_octo_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local split, path = utils.get_split_and_path(bufnr)
  local buffer = octo_buffers[bufnr]
  if split and path then
    -- review diff buffers
    local current_review = reviews.get_current_review()
    if current_review and #current_review.threads > 0 then
      current_review.layout:get_current_file():place_signs()
    end
  elseif buffer then
    -- issue/pr/reviewthread buffers
    buffer:configure()
  end
end

function M.save_buffer()
  local buffer = utils.get_current_buffer()
  if not buffer then
    return
  end
  buffer:save()
end

---@class ReloadOpts
---@field bufnr number
---@field verbose? boolean
---@field on_local_changes? fun()
---@field on_cached? fun()
---@field on_reload? fun()
---@field on_error? fun()

--- Load issue/pr/repo buffer
---@param opts? ReloadOpts
---@return nil
function M.load_buffer(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local bufname = vim.fn.bufname(bufnr)
  local buffer_info = uri.parse(bufname)
  if buffer_info == nil then
    utils.print_err("Cannot parse buffer name: " .. bufname)
    return
  end
  local repo, kind, id, hostname = buffer_info.repo, buffer_info.kind, buffer_info.id, buffer_info.hostname
  if kind == "pull" or kind == "issue" or kind == "discussion" or kind == "pull_diff" then
    local number = tonumber(id)
    if not number or number < 1 or number > 2147483647 or number ~= math.floor(number) then
      utils.print_err(string.format("Invalid %s number in buffer URI: %s", kind, id))
      return
    end
    id = number
  end

  if not opts.auth_context_resolved then
    next_auth_generation = next_auth_generation + 1
    local auth_generation = next_auth_generation
    active_auth_loads[bufnr] = auth_generation
    if vim.api.nvim_buf_is_valid(bufnr) and not vim.b[bufnr].octo_cached then
      local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      if #current_lines == 1 and current_lines[1] == "" then
        local label = kind == "pull" and "pull request" or kind
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
          string.format("Loading %s #%s from %s…", label, id, repo),
        })
        vim.bo[bufnr].filetype = "octo"
        vim.bo[bufnr].modified = false
        vim.bo[bufnr].modifiable = false
        vim.b[bufnr].octo_loading_skeleton = true
      end
    end
    gh.get_auth_context(resolve_hostname(hostname), function(auth_context)
      if
        active_auth_loads[bufnr] ~= auth_generation
        or not vim.api.nvim_buf_is_valid(bufnr)
        or vim.api.nvim_buf_get_name(bufnr) ~= bufname
      then
        return
      end
      active_auth_loads[bufnr] = nil
      opts.auth_context = auth_context
      opts.auth_context_resolved = true
      M.load_buffer(opts)
    end)
    return
  end

  local auth_context = opts.auth_context
  next_load_generation = next_load_generation + 1
  local load_generation = next_load_generation
  active_loads[bufnr] = load_generation
  local function is_latest_load()
    if active_loads[bufnr] ~= load_generation then
      return false
    end
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_buf_get_name(bufnr) ~= bufname then
      M.invalidate_load(bufnr)
      return false
    end
    return true
  end
  local function finish_load()
    if is_latest_load() then
      active_loads[bufnr] = nil
    end
  end

  local load_error_handled = false
  local function handle_load_error()
    if load_error_handled or not is_latest_load() then
      return
    end
    load_error_handled = true
    finish_load()
    if vim.api.nvim_buf_is_valid(bufnr) then
      local was_skeleton = vim.b[bufnr].octo_loading_skeleton
      vim.b[bufnr].octo_loading_skeleton = nil
      local current_buffer = octo_buffers[bufnr]
      if current_buffer and type(current_buffer.clear_timeline_loading_indicator) == "function" then
        current_buffer:clear_timeline_loading_indicator()
      end
      if was_skeleton then
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
        vim.bo[bufnr].modified = false
        vim.bo[bufnr].modifiable = false
      end
    end
    if opts.on_error then
      opts.on_error()
    else
      utils.print_err(string.format("Failed to revalidate %s buffer %s", kind, id))
    end
  end

  -- Find a window showing this buffer so we can save/restore cursor and
  -- ensure fold commands target the correct window during rendering.
  local win ---@type integer|nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      win = w
      break
    end
  end
  local cursor_pos = win and vim.api.nvim_win_get_cursor(win) or nil
  local window_view = win and vim.api.nvim_win_call(win, vim.fn.winsaveview) or nil
  local cursor_comment_anchor ---@type { id: string?, databaseId: integer?, row_offset: integer, col: integer }?

  local function capture_cursor_comment_anchor(buffer)
    if
      type(buffer.get_comment_at_line) ~= "function"
      or not win
      or not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_win_get_buf(win) ~= bufnr
    then
      return
    end
    local position = vim.api.nvim_win_get_cursor(win)
    local comment = buffer:get_comment_at_line(position[1])
    if not comment or not comment.extmark then
      return
    end
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, constants.OCTO_COMMENT_NS, comment.extmark, {})
    if not mark[1] then
      return
    end
    return {
      id = comment.id,
      databaseId = comment.databaseId,
      row_offset = math.max(0, position[1] - (mark[1] + 1)),
      col = position[2],
    }
  end

  local function restore_cursor()
    if not cursor_pos or not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
      return
    end
    if window_view then
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(window_view)
      end)
    end

    local restored_position ---@type integer[]|nil
    local buffer = octo_buffers[bufnr]
    if cursor_comment_anchor and buffer then
      for _, comment in ipairs(buffer.commentsMetadata or {}) do
        if
          (cursor_comment_anchor.databaseId and comment.databaseId == cursor_comment_anchor.databaseId)
          or (cursor_comment_anchor.id and comment.id == cursor_comment_anchor.id)
        then
          local mark =
            vim.api.nvim_buf_get_extmark_by_id(bufnr, constants.OCTO_COMMENT_NS, comment.extmark, { details = true })
          if mark[1] then
            local first_line = mark[1] + 1
            local last_line = mark[3].end_row + 1
            restored_position = {
              math.max(first_line, math.min(first_line + cursor_comment_anchor.row_offset, last_line)),
              cursor_comment_anchor.col,
            }
            break
          end
        end
      end
    end

    if not restored_position then
      restored_position = {
        math.min(cursor_pos[1], vim.api.nvim_buf_line_count(bufnr)),
        math.max(0, cursor_pos[2]),
      }
    end
    vim.api.nvim_win_set_cursor(win, restored_position)
  end

  local function has_local_changes()
    if vim.bo[bufnr].modified then
      return true
    end
    local current_buffer = octo_buffers[bufnr]
    return current_buffer ~= nil and current_buffer:has_local_changes()
  end

  local function is_pristine_buffer()
    if not vim.api.nvim_buf_is_valid(bufnr) or octo_buffers[bufnr] or vim.bo[bufnr].modified then
      return false
    end
    if vim.b[bufnr].octo_loading_skeleton then
      return true
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return #lines == 1 and lines[1] == ""
  end

  ---@param buffer OctoBuffer
  ---@return table<string, { start_offset: integer, end_offset: integer, closed: boolean }[]>
  local function capture_comment_fold_states(buffer)
    local states = {} ---@type table<string, { start_offset: integer, end_offset: integer, closed: boolean }[]>
    if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
      return states
    end
    vim.api.nvim_win_call(win, function()
      for _, comment in ipairs(buffer.commentsMetadata or {}) do
        if comment.id and comment.extmark then
          local mark =
            vim.api.nvim_buf_get_extmark_by_id(bufnr, constants.OCTO_COMMENT_NS, comment.extmark, { details = true })
          if mark[1] and mark[3] and mark[3].end_row then
            local first_line = mark[1] + 1
            local last_line = math.min(mark[3].end_row + 1, vim.api.nvim_buf_line_count(bufnr))
            local folds = {} ---@type { start_offset: integer, end_offset: integer, closed: boolean }[]
            local previous_level = first_line > 1 and vim.fn.foldlevel(first_line - 1) or 0
            for line = first_line, last_line do
              local level = vim.fn.foldlevel(line)
              if level > previous_level then
                local closed_start = vim.fn.foldclosed(line)
                if closed_start == -1 or closed_start == line then
                  local end_line = line
                  for candidate = line + 1, last_line do
                    if vim.fn.foldlevel(candidate) < level then
                      break
                    end
                    end_line = candidate
                  end
                  folds[#folds + 1] = {
                    start_offset = line - first_line,
                    end_offset = end_line - first_line,
                    closed = closed_start == line,
                  }
                end
              end
              previous_level = level
            end
            if #folds > 0 then
              states[tostring(comment.id)] = folds
            end
          end
        end
      end
    end)
    return states
  end

  ---@param buffer OctoBuffer
  ---@param states table<string, { start_offset: integer, end_offset: integer, closed: boolean }[]>
  local function restore_comment_fold_states(buffer, states)
    if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
      return
    end
    vim.api.nvim_win_call(win, function()
      for _, comment in ipairs(buffer.commentsMetadata or {}) do
        local saved_folds = comment.id and states[tostring(comment.id)] or nil
        if saved_folds and comment.extmark then
          local mark =
            vim.api.nvim_buf_get_extmark_by_id(bufnr, constants.OCTO_COMMENT_NS, comment.extmark, { details = true })
          if mark[1] and mark[3] and mark[3].end_row then
            local first_line = mark[1] + 1
            local last_line = mark[3].end_row + 1
            table.sort(saved_folds, function(left, right)
              return left.start_offset < right.start_offset
            end)
            for _, state in ipairs(saved_folds) do
              local line = first_line + state.start_offset
              if line <= last_line and vim.fn.foldlevel(line) > 0 then
                vim.api.nvim_win_set_cursor(win, { line, 0 })
                if state.closed then
                  if vim.fn.foldclosed(line) == -1 then
                    vim.cmd "normal! zc"
                  end
                else
                  while vim.fn.foldclosed(line) ~= -1 do
                    vim.cmd "normal! zo"
                  end
                end
              end
            end
          end
        end
      end
    end)
  end

  local shell_rendered = false
  local cached_rendered = false
  local cached_full_rendered = false
  local fresh_shell_rendered = false
  local fresh_response_received = false
  local cached_notification_sent = false
  local function notify_cached()
    if not cached_notification_sent then
      cached_notification_sent = true
      if opts.on_cached then
        opts.on_cached()
      end
    end
  end
  local cacheable_kind = kind == "pull" or kind == "issue" or kind == "discussion" or kind == "pull_diff"
  local cache_key ---@type string?
  if config.values.persistent_cache.enabled and cacheable_kind then
    local host = resolve_hostname(hostname)
    if auth_context and auth_context.fingerprint then
      cache_key = persistent_cache.key(host, repo, kind, id, nil, auth_context.fingerprint)
    end

    ---@param object table
    ---@return boolean
    local function is_complete_cached_object(object)
      if
        type(object.number) ~= "number"
        or object.number ~= math.floor(object.number)
        or type(object.title) ~= "string"
      then
        return false
      end
      if kind == "pull_diff" then
        return type(object.diff) == "string"
      end
      if type(object.id) ~= "string" or type(object.body) ~= "string" or object._loadState == "shell" then
        return false
      end
      if kind == "discussion" then
        return type(object.comments) == "table" and type(object.comments.nodes) == "table"
      end
      return type(object.timelineItems) == "table" and type(object.timelineItems.nodes) == "table"
    end

    ---@param payload table?
    ---@return octo.PersistentObjectCacheEntry|nil
    local function validate_object_cache_payload(payload)
      if type(payload) ~= "table" or type(payload.object) ~= "table" then
        return
      end
      local object = payload.object
      if not is_complete_cached_object(object) then
        return
      end
      if kind == "pull_diff" then
        ---@type octo.CachedPullDiff
        local diff = object
        return { object = diff }
      end
      if
        type(object.id) ~= "string"
        or type(object.body) ~= "string"
        or object._loadState == "shell"
        or (kind == "discussion" and type(object.comments) ~= "table")
        or (kind ~= "discussion" and type(object.timelineItems) ~= "table")
      then
        return
      end
      ---@type octo.PullRequest|octo.Issue|octo.Discussion
      local node = object
      return { object = node }
    end

    local function render_cached_object(cache_entry)
      if
        not is_latest_load()
        or not vim.api.nvim_buf_is_valid(bufnr)
        or fresh_shell_rendered
        or not is_pristine_buffer()
        or has_local_changes()
      then
        return
      end
      local validated_entry = validate_object_cache_payload(cache_entry)
      if not validated_entry then
        return
      end
      local cached_obj = validated_entry.object
      vim.schedule(function()
        if
          not is_latest_load()
          or fresh_response_received
          or not vim.api.nvim_buf_is_valid(bufnr)
          or not is_pristine_buffer()
          or has_local_changes()
        then
          return
        end
        vim.api.nvim_buf_call(bufnr, function()
          vim.bo[bufnr].modifiable = true
          vim.bo[bufnr].readonly = false
          if kind == "pull_diff" then
            M.create_pull_diff_buffer(cached_obj, repo, false, hostname)
          else
            M.create_buffer(kind, cached_obj, repo, false, hostname)
          end
          shell_rendered = true
          cached_rendered = true
          cached_full_rendered = true
          mark_cached(bufnr)
          notify_cached()
          restore_cursor()
        end)
      end)
    end

    if cache_key then
      persistent_cache.read(cache_key, render_cached_object)
    end
  end

  if kind == "pull_diff" then
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd [[setlocal filetype=diff]]
      vim.cmd [[setlocal buftype=nofile]]
      vim.cmd [[setlocal bufhidden=hide]]
      vim.cmd [[setlocal noswapfile]]
      vim.cmd [[setlocal readonly]]
      vim.cmd [[setlocal nomodifiable]]
    end)

    M.load_pull_diff(repo, id, hostname, function(obj)
      if not is_latest_load() then
        return
      end
      fresh_response_received = true
      if not vim.api.nvim_buf_is_valid(bufnr) then
        finish_load()
        if opts.on_error then
          opts.on_error()
        end
        return
      end

      local has_local_buffer_edits = has_local_changes()
      clear_cached_mark(bufnr)
      if has_local_buffer_edits then
        finish_load()
        if opts.on_local_changes then
          opts.on_local_changes()
        end
        return
      end

      vim.api.nvim_buf_call(bufnr, function()
        M.create_pull_diff_buffer(obj, repo, false, hostname)
        restore_cursor()

        if opts.verbose then
          utils.info(string.format("Loaded %s/%s/%s", repo, kind, id))
        end
      end)

      if cache_key then
        persistent_cache.write(cache_key, { object = obj })
      end
      finish_load()
      if opts.on_reload then
        opts.on_reload()
      end
    end, handle_load_error, auth_context)
    return
  end

  M.load(repo, kind, id, hostname, function(obj)
    if not is_latest_load() then
      return
    end
    fresh_response_received = true
    if not vim.api.nvim_buf_is_valid(bufnr) then
      finish_load()
      if opts.on_error then
        opts.on_error()
      end
      return
    end

    local octo_buf = octo_buffers[bufnr]
    if has_local_changes() then
      clear_cached_mark(bufnr)
      finish_load()
      if opts.on_local_changes then
        opts.on_local_changes()
      end
      return
    end

    local comment_fold_states = {} ---@type table<string, { start_offset: integer, end_offset: integer, closed: boolean }[]>
    if shell_rendered and octo_buf then
      comment_fold_states = capture_comment_fold_states(octo_buf)
    end
    if shell_rendered and win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      if octo_buf then
        cursor_comment_anchor = capture_cursor_comment_anchor(octo_buf)
      end
      cursor_pos = vim.api.nvim_win_get_cursor(win)
      window_view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    end

    clear_cached_mark(bufnr)
    vim.api.nvim_buf_call(bufnr, function()
      vim.bo[bufnr].modifiable = true
      vim.bo[bufnr].readonly = false
      if shell_rendered and octo_buf then
        octo_buf:update_node(obj)
        -- Rendering clears the old comment extmarks, so their metadata must be rebuilt too.
        octo_buf.commentsMetadata = {}
        octo_buf.threadsMetadata = {}
        if kind == "discussion" then
          octo_buf:render_discussion()
        else
          octo_buf:render_issue()
        end
        octo_buf:render_signs()
        restore_comment_fold_states(octo_buf, comment_fold_states)
      else
        M.create_buffer(kind, obj, repo, false, hostname)
      end

      restore_cursor()

      if opts.verbose then
        utils.info(string.format("Loaded %s/%s/%d", repo, kind, id))
      end
    end)

    if cache_key then
      persistent_cache.write(cache_key, { object = obj })
    end
    finish_load()
    if opts.on_reload then
      opts.on_reload()
    end
  end, {
    on_skeleton = function()
      if not vim.api.nvim_buf_is_valid(bufnr) or octo_buffers[bufnr] then
        return
      end
      local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      if #current_lines ~= 1 or current_lines[1] ~= "" then
        return
      end
      local label = kind == "pull" and "pull request" or kind
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        string.format("Loading %s #%s from %s…", label, id, repo),
      })
      vim.bo[bufnr].filetype = "octo"
      vim.bo[bufnr].modified = false
      vim.bo[bufnr].modifiable = false
      vim.b[bufnr].octo_loading_skeleton = true
    end,
    on_shell = function(shell, is_cached)
      if not is_latest_load() or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local octo_buf = octo_buffers[bufnr]
      if has_local_changes() then
        return
      end
      if cached_full_rendered or (is_cached and fresh_shell_rendered) then
        return
      end
      if not is_cached then
        fresh_shell_rendered = true
        if cached_rendered then
          return
        end
      end

      vim.api.nvim_buf_call(bufnr, function()
        vim.bo[bufnr].modifiable = true
        vim.bo[bufnr].readonly = false
        M.create_buffer(kind, shell, repo, false, hostname)
        shell_rendered = true
        if is_cached then
          cached_rendered = true
          mark_cached(bufnr)
          notify_cached()
        end
        restore_cursor()
      end)
    end,
    on_error = handle_load_error,
    auth_context = auth_context,
  })
end

---@param repo string
---@param number integer|string
---@param hostname string|nil
---@param cb fun(obj: table): nil
---@param on_error? fun()
---@param auth_context? octo.AuthContext
function M.load_pull_diff(repo, number, hostname, cb, on_error, auth_context)
  local owner, name = utils.split_repo(repo)
  local function get_diff_fingerprint(pr)
    if not pr then
      return ""
    end
    local base_ref_oid = utils.is_blank(pr.baseRefOid) and "" or pr.baseRefOid
    local head_ref_oid = utils.is_blank(pr.headRefOid) and "" or pr.headRefOid
    if base_ref_oid == "" and head_ref_oid == "" then
      return ""
    end
    return base_ref_oid .. "..." .. head_ref_oid
  end

  local fingerprint, updated_at, title = "", nil, nil
  local fingerprint_finished = false
  local diff_finished = false
  local diff_output ---@type string?
  local failed = false

  local function finish_if_ready()
    if failed or not fingerprint_finished or not diff_finished then
      return
    end
    cb {
      id = string.format("%s#%s:diff", repo, number),
      number = tonumber(number),
      title = title,
      diff = diff_output or "",
      diffFingerprint = fingerprint,
      updatedAt = updated_at,
    }
  end

  -- The REST diff does not depend on the optional GraphQL fingerprint query.
  gh.api.get {
    "/repos/{repo}/pulls/{number}",
    format = { repo = repo, number = number },
    opts = {
      headers = { headers.diff },
      hostname = hostname,
      auth_context = auth_context,
      cb = function(diff, stderr, status)
        if status == nil or status == 0 then
          diff_output = diff or ""
          diff_finished = true
          finish_if_ready()
        else
          failed = true
          utils.print_err(stderr or "")
          if on_error then
            on_error()
          end
        end
      end,
    },
  }

  gh.api.graphql {
    query = queries.pull_diff_fingerprint,
    F = { owner = owner, name = name, number = tonumber(number) },
    jq = ".",
    opts = {
      hostname = hostname,
      auth_context = auth_context,
      cb = gh.create_callback {
        failure = function()
          fingerprint_finished = true
          finish_if_ready()
        end,
        success = function(output)
          local ok, resp = pcall(vim.json.decode, output)
          local pr = ok and vim.tbl_get(resp, "data", "repository", "pullRequest") or nil
          if type(pr) == "table" then
            fingerprint = get_diff_fingerprint(pr)
            updated_at = pr.updatedAt
            title = pr.title
          end
          fingerprint_finished = true
          finish_if_ready()
        end,
      },
    },
  }
end

---@param obj table
---@return octo.LoadShell|nil
local function validate_preview_object(obj)
  if
    type(obj.id) ~= "string"
    or type(obj.number) ~= "number"
    or obj.number < 1
    or obj.number ~= math.floor(obj.number)
    or type(obj.title) ~= "string"
    or type(obj.body) ~= "string"
  then
    return
  end
  obj._loadState = "shell"
  return obj
end

---@type table<string, { expires_at: number, obj: octo.LoadShell }>
local fast_load_cache = {}
---@type table<string, { success: fun(obj: octo.LoadShell, cached: boolean), failure: fun(stderr: string)?, cached_delivered: boolean, fresh_delivered: boolean }[]>
local fast_load_inflight = {}

---@param repo string
---@param kind "pull"|"pull_request"|"issue"|"discussion"
---@param id integer|string
---@param hostname string?
---@param cb fun(obj: octo.LoadShell, cached: boolean): nil
---@param on_error? fun(stderr: string): nil
---@param auth_context? octo.AuthContext
function M.load_preview(repo, kind, id, hostname, cb, on_error, auth_context)
  local normalized_kind = kind == "pull_request" and "pull" or kind
  local owner, name = utils.split_repo(repo)
  local host = resolve_hostname(hostname)
  if not auth_context then
    gh.get_auth_context(host, function(context)
      M.load_preview(repo, kind, id, hostname, cb, on_error, context)
    end)
    return
  end
  local identity = auth_context.fingerprint
  local identity_key = identity and vim.fn.sha256(host .. "\0" .. identity) or tostring(vim.loop.hrtime())
  local cache_key = table.concat({ host, identity_key, repo, normalized_kind, tostring(id) }, "|")
  local preview_key = config.values.persistent_cache.enabled
      and identity
      and persistent_cache.key(host, repo, normalized_kind, id, "preview", identity)
    or nil
  local query, fields
  if normalized_kind == "pull" then
    query = graphql("pull_request_fast_query", _G.octo_pv2_fragment)
    fields = { owner = owner, name = name, number = tonumber(id), timelineCount = 10 }
  elseif normalized_kind == "issue" then
    query = graphql("issue_fast_query", _G.octo_pv2_fragment)
    fields = { owner = owner, name = name, number = tonumber(id), timelineCount = 10 }
  elseif normalized_kind == "discussion" then
    query = queries.discussion_fast
    fields = { owner = owner, name = name, number = tonumber(id) }
  else
    return
  end

  local waiter = {
    success = cb,
    failure = on_error,
    cached_delivered = false,
    fresh_delivered = false,
  }
  local function deliver_cached(callback, obj)
    if callback.cached_delivered or callback.fresh_delivered then
      return
    end
    local preview_obj = type(obj) == "table" and validate_preview_object(obj) or nil
    if not preview_obj then
      return
    end
    callback.cached_delivered = true
    callback.success(vim.deepcopy(preview_obj), true)
  end

  local now = vim.loop.hrtime() / 1000000000
  local memory_cached = fast_load_cache[cache_key]
  if memory_cached and memory_cached.expires_at > now then
    vim.schedule(function()
      deliver_cached(waiter, memory_cached.obj)
    end)
  elseif memory_cached then
    fast_load_cache[cache_key] = nil
  end

  local callbacks = fast_load_inflight[cache_key]
  if callbacks then
    callbacks[#callbacks + 1] = waiter
  else
    callbacks = { waiter }
    fast_load_inflight[cache_key] = callbacks
  end

  if preview_key then
    persistent_cache.read(preview_key, function(cached_obj)
      if type(cached_obj) == "table" then
        for _, callback in ipairs(callbacks) do
          deliver_cached(callback, cached_obj)
        end
      end
    end)
  end

  if #callbacks > 1 then
    return
  end

  gh.api.graphql {
    query = query,
    fields = fields,
    jq = ".",
    opts = {
      hostname = host,
      auth_context = auth_context,
      cb = gh.create_callback {
        failure = function(stderr)
          local waiting = fast_load_inflight[cache_key]
          fast_load_inflight[cache_key] = nil
          for _, callback in ipairs(waiting or {}) do
            if callback.failure then
              callback.failure(stderr)
            elseif not callback.cached_delivered then
              utils.print_err(stderr)
            end
          end
        end,
        success = function(output)
          local ok, resp = pcall(vim.json.decode, output)
          local obj = ok
              and vim.tbl_get(
                resp,
                "data",
                "repository",
                normalized_kind == "pull" and "pullRequest" or normalized_kind
              )
            or nil
          local preview_obj = type(obj) == "table" and validate_preview_object(obj) or nil
          if not preview_obj then
            local waiting = fast_load_inflight[cache_key]
            fast_load_inflight[cache_key] = nil
            for _, callback in ipairs(waiting or {}) do
              if callback.failure then
                callback.failure "Fast query returned an invalid preview object"
              end
            end
            return
          end
          fast_load_cache[cache_key] = {
            expires_at = vim.loop.hrtime() / 1000000000 + 30,
            obj = vim.deepcopy(preview_obj),
          }
          if preview_key then
            persistent_cache.write(preview_key, preview_obj)
          end
          local waiting = fast_load_inflight[cache_key]
          fast_load_inflight[cache_key] = nil
          for _, callback in ipairs(waiting or {}) do
            callback.fresh_delivered = true
            callback.success(vim.deepcopy(preview_obj), false)
          end
        end,
      },
    },
  }
end

---Load a fast PR preview and attach its check summary when the lightweight query completes.
---@param repo string
---@param number integer|string
---@param hostname string?
---@param cb fun(obj: table, cached: boolean): nil
---@param on_error? fun(stderr: string): nil
function M.load_pull_preview(repo, number, hostname, cb, on_error)
  local owner, name = utils.split_repo(repo)
  local latest_object ---@type table?
  local latest_is_cached = false
  local checks_requested = false

  M.load_preview(repo, "pull", number, hostname, function(obj, is_cached)
    latest_object = obj
    latest_is_cached = is_cached
    cb(obj, is_cached)
    if checks_requested then
      return
    end
    checks_requested = true
    gh.api.graphql {
      query = queries.pull_request_checks,
      fields = { owner = owner, name = name, number = tonumber(number) },
      jq = ".",
      opts = {
        hostname = hostname,
        cb = gh.create_callback {
          failure = function() end,
          success = function(output)
            local ok, response = pcall(vim.json.decode, output)
            local pull_request = ok and vim.tbl_get(response, "data", "repository", "pullRequest") or nil
            if type(pull_request) ~= "table" or latest_object == nil then
              return
            end
            latest_object.statusCheckRollup = pull_request.statusCheckRollup
            cb(latest_object, latest_is_cached)
          end,
        },
      },
    }
  end, on_error)
end

---@param repo string
---@class octo.LoadOpts
---@field on_skeleton? fun(): nil
---@field on_shell? fun(obj: octo.LoadShell, cached: boolean): nil
---@field on_error? fun(): nil
---@field auth_context? octo.AuthContext

---@param kind octo.NodeKind
---@param id? integer|string pull request, issue, or discussion number or release tag
---@param hostname string|nil optional GitHub Enterprise hostname
---@param cb fun(obj: octo.Issue|octo.PullRequest|octo.Discussion|octo.Release|octo.Repository): nil
---@param opts? octo.LoadOpts
function M.load(repo, kind, id, hostname, cb, opts)
  local owner, name = utils.split_repo(repo)
  local load_completed = false
  local function complete(obj)
    if load_completed then
      return
    end
    load_completed = true
    obj._loadState = "complete"
    cb(obj)
  end
  local function fail(message)
    if load_completed then
      return
    end
    load_completed = true
    if opts and opts.on_error then
      opts.on_error()
    else
      utils.print_err(message)
    end
  end

  if (kind == "pull" or kind == "issue" or kind == "discussion") and id ~= nil then
    local number = tonumber(id)
    if not number or number < 1 or number > 2147483647 or number ~= math.floor(number) then
      fail(string.format("Invalid %s number: %s", kind, id))
      return
    end
    id = number
  end

  ---@type string, string, table<string, string|integer>
  local query, key, fields
  local fast_pull_query ---@type string?
  if kind == "pull" then
    query = graphql("pull_request_query", _G.octo_pv2_fragment)
    fast_pull_query = graphql("pull_request_fast_full_query", _G.octo_pv2_fragment)
    key = "pullRequest"
    fields = { owner = owner, name = name, number = id }
  elseif kind == "issue" then
    query = graphql("issue_query", _G.octo_pv2_fragment)
    key = "issue"
    fields = { owner = owner, name = name, number = id }
  elseif kind == "repo" then
    query = queries.repository
    fields = { owner = owner, name = name }
  elseif kind == "discussion" then
    query = queries.discussion
    fields = {
      owner = owner,
      name = name,
      number = id,
    }
  elseif kind == "release" then
    query = queries.release
    fields = {
      owner = owner,
      name = name,
      tag = id --[[@as string]],
    }
  end

  local function load_buffer(output)
    if kind == "pull" or kind == "issue" then
      local resp = utils.aggregate_pages(output, string.format("data.repository.%s.timelineItems.nodes", key))
      ---@type octo.Issue|octo.PullRequest
      local obj = resp.data.repository[key]
      if kind == "pull" then
        local repo_data = resp.data.repository
        if repo_data.rulesets then
          obj._rulesets = repo_data.rulesets
        end
        if repo_data.defaultBranchRef then
          obj._defaultBranchName = repo_data.defaultBranchRef.name
        end
      end
      complete(obj)
    elseif kind == "repo" then
      local resp = vim.json.decode(output)
      ---@type octo.Repository
      local obj = resp.data.repository
      complete(obj)
    elseif kind == "discussion" then
      local resp = utils.aggregate_pages(output, "data.repository.discussion.comments.nodes")
      ---@type octo.Discussion
      local obj = resp.data.repository.discussion
      complete(obj)
    elseif kind == "release" then
      local resp = vim.json.decode(output)
      ---@type octo.Release
      local obj = resp.data.repository.release
      complete(obj)
    else
      utils.error("Unknown kind: " .. kind)
    end
  end

  local function load_paginated_fallback()
    gh.api.graphql {
      query = query,
      fields = fields,
      paginate = true,
      jq = ".",
      opts = {
        hostname = hostname,
        auth_context = opts and opts.auth_context,
        cb = gh.create_callback {
          failure = fail,
          success = function(output)
            local ok, err = pcall(load_buffer, output)
            if not ok then
              fail(tostring(err))
            end
          end,
        },
      },
    }
  end

  local fallback_started = false
  local function fallback()
    if fallback_started or load_completed then
      return
    end
    fallback_started = true
    load_paginated_fallback()
  end

  if kind == "discussion" then
    if not id then
      fallback()
      return
    end
    if opts and opts.on_skeleton then
      opts.on_skeleton()
    end

    local details_received = false
    local expected_count ---@type integer?
    local segments = {} ---@type table[][]
    local full_response ---@type table?
    local function request_page(before_cursor)
      if fallback_started then
        return
      end
      local page_fields = { owner = owner, name = name, number = id }
      if before_cursor then
        page_fields.beforeCursor = before_cursor
      end
      gh.api.graphql {
        query = queries.discussion_full_recent,
        fields = page_fields,
        jq = ".",
        opts = {
          hostname = hostname,
          auth_context = opts and opts.auth_context,
          cb = gh.create_callback {
            failure = function()
              fallback()
            end,
            success = function(output)
              if fallback_started or load_completed then
                return
              end
              local ok, response = pcall(vim.json.decode, output)
              local discussion = ok and vim.tbl_get(response, "data", "repository", "discussion") or nil
              local connection = type(discussion) == "table" and discussion.comments or nil
              local page_info = type(connection) == "table" and connection.pageInfo or nil
              if
                type(connection) ~= "table"
                or type(connection.totalCount) ~= "number"
                or type(connection.nodes) ~= "table"
                or type(page_info) ~= "table"
              then
                fallback()
                return
              end

              details_received = true
              if expected_count and expected_count ~= connection.totalCount then
                fallback()
                return
              end
              expected_count = connection.totalCount
              table.insert(segments, 1, connection.nodes)
              if not full_response then
                full_response = response
              end
              if page_info.hasPreviousPage then
                if type(page_info.startCursor) ~= "string" then
                  fallback()
                  return
                end
                request_page(page_info.startCursor)
                return
              end

              local nodes = {} ---@type table[]
              local seen = {} ---@type table<string, boolean>
              for _, segment in ipairs(segments) do
                for _, comment in ipairs(segment) do
                  local comment_id = comment ~= vim.NIL and type(comment) == "table" and comment.id or nil
                  if comment_id == nil or not seen[comment_id] then
                    nodes[#nodes + 1] = comment
                    if comment_id then
                      seen[comment_id] = true
                    end
                  end
                end
              end
              if #nodes ~= expected_count or not full_response then
                fallback()
                return
              end
              local full_discussion = vim.tbl_get(full_response, "data", "repository", "discussion")
              if type(full_discussion) ~= "table" then
                fallback()
                return
              end
              full_discussion.comments.nodes = nodes
              full_discussion._timelineIncomplete = nil
              load_buffer(vim.json.encode(full_response))
            end,
          },
        },
      }
    end

    M.load_preview(repo, kind, id, hostname, function(shell, is_cached)
      if fallback_started or load_completed or details_received then
        return
      end
      local load_shell = shell
      load_shell._loadState = "shell"
      local shell_comments = load_shell.comments
      local count = shell_comments and shell_comments.totalCount
      local shell_nodes = shell_comments and shell_comments.nodes or {}
      if type(count) ~= "number" or count < #shell_nodes then
        fallback()
        return
      end

      if not is_cached then
        expected_count = count
      end
      load_shell._timelineIncomplete = is_cached or count > #shell_nodes
      if opts and opts.on_shell then
        opts.on_shell(load_shell, is_cached)
      end
    end, function()
      fallback()
    end, opts and opts.auth_context)

    -- Give the fast paint request the first slot before starting full pagination.
    request_page(nil)
    return
  end

  if kind ~= "pull" and kind ~= "issue" then
    load_paginated_fallback()
    return
  end
  if not id then
    fallback()
    return
  end

  local page_query = kind == "pull" and queries.pull_request_timeline_page or queries.issue_timeline_page
  local phase_two_query = kind == "pull" and fast_pull_query or query
  local details_received = false
  local review_threads_received = kind ~= "pull"
  local ruleset_details_received = kind ~= "pull"
  local checks_received = kind ~= "pull"
  local pull_review_threads ---@type table?
  local pull_rulesets ---@type table?
  local latest_opinionated_reviews ---@type table?
  local pull_status_check_rollup ---@type table?
  local expected_count ---@type integer?
  local page_count = 0
  local pending_pages = 0
  local pages = {} ---@type table<integer, { filteredCount: integer, nodes: table[] }>
  local failed_pages = {} ---@type table<integer, boolean>
  local full_response ---@type table?

  local function finish_if_ready()
    if
      fallback_started
      or load_completed
      or not details_received
      or pending_pages > 0
      or not review_threads_received
      or not ruleset_details_received
      or not checks_received
    then
      return
    end
    local combined_nodes = {} ---@type table[]
    local seen = {} ---@type table<string, boolean>
    for page_index = 0, page_count - 1 do
      local page = pages[page_index]
      local skip = page_index == 0 and 0 or page_index * 99
      local expected_page_size = math.min(100, expected_count - skip)
      if not page or page.filteredCount ~= expected_count or #page.nodes ~= expected_page_size then
        fallback()
        return
      end
      if page_index > 0 then
        local previous_page = pages[page_index - 1]
        local previous_item = previous_page and previous_page.nodes[#previous_page.nodes]
        local boundary_item = page.nodes[1]
        local previous_id = type(previous_item) == "table" and previous_item ~= vim.NIL and previous_item.id or nil
        local boundary_id = type(boundary_item) == "table" and boundary_item ~= vim.NIL and boundary_item.id or nil
        if previous_id == nil or boundary_id == nil or previous_id ~= boundary_id then
          fallback()
          return
        end
      end
      for _, item in ipairs(page.nodes) do
        local node_id = item ~= vim.NIL and type(item) == "table" and item.id or nil
        if node_id == nil or not seen[node_id] then
          table.insert(combined_nodes, item)
          if node_id then
            seen[node_id] = true
          end
        end
      end
    end

    if #combined_nodes ~= expected_count or not full_response then
      fallback()
      return
    end
    local full_obj = vim.tbl_get(full_response, "data", "repository", key)
    if type(full_obj) ~= "table" or type(full_obj.timelineItems) ~= "table" then
      fallback()
      return
    end
    full_obj.timelineItems.nodes = combined_nodes
    if kind == "pull" then
      local repository = vim.tbl_get(full_response, "data", "repository")
      if
        type(repository) ~= "table"
        or not pull_review_threads
        or not pull_rulesets
        or not latest_opinionated_reviews
      then
        fallback()
        return
      end
      full_obj.reviewThreads = pull_review_threads
      full_obj.latestOpinionatedReviews = latest_opinionated_reviews
      if pull_status_check_rollup then
        full_obj.statusCheckRollup = pull_status_check_rollup
      end
      repository.rulesets = pull_rulesets
    end
    full_obj._timelineIncomplete = nil
    load_buffer(vim.json.encode(full_response))
  end

  local start_page_fanout ---@type fun(count: integer): nil
  local request_timeline_page ---@type fun(page_index: integer): nil
  local requested_pages = {} ---@type table<integer, boolean>

  local function receive_timeline_page(page_index, output)
    if fallback_started or load_completed or (expected_count ~= nil and page_index >= page_count) then
      return
    end
    local ok, response = pcall(vim.json.decode, output)
    local connection = ok and vim.tbl_get(response, "data", "repository", key, "timelineItems") or nil
    if
      type(connection) ~= "table"
      or type(connection.filteredCount) ~= "number"
      or type(connection.nodes) ~= "table"
    then
      fallback()
      return
    end
    if expected_count ~= nil and connection.filteredCount ~= expected_count then
      fallback()
      return
    end

    pages[page_index] = { filteredCount = connection.filteredCount, nodes = connection.nodes }
    if expected_count == nil then
      start_page_fanout(connection.filteredCount)
      return
    end
    if page_index < page_count then
      pending_pages = pending_pages - 1
    end
    finish_if_ready()
  end

  request_timeline_page = function(page_index)
    requested_pages[page_index] = true
    gh.api.graphql {
      query = page_query,
      fields = { owner = owner, name = name, number = id, skip = page_index * 99 },
      jq = ".",
      opts = {
        hostname = hostname,
        auth_context = opts and opts.auth_context,
        cb = gh.create_callback {
          failure = function()
            if expected_count == nil then
              failed_pages[page_index] = true
            elseif page_index < page_count then
              fallback()
            end
          end,
          success = function(output)
            receive_timeline_page(page_index, output)
          end,
        },
      },
    }
  end

  start_page_fanout = function(count)
    if expected_count ~= nil then
      if expected_count ~= count then
        fallback()
      end
      return
    end
    expected_count = count
    page_count = count <= 100 and 1 or math.ceil((count - 100) / 99) + 1
    for page_index in pairs(failed_pages) do
      if page_index < page_count then
        fallback()
        return
      end
    end
    local pages_to_request = {} ---@type integer[]
    pending_pages = 0
    for page_index = 1, page_count - 1 do
      if pages[page_index] then
        if pages[page_index].filteredCount ~= count then
          fallback()
          return
        end
      else
        pending_pages = pending_pages + 1
        if not requested_pages[page_index] then
          requested_pages[page_index] = true
          pages_to_request[#pages_to_request + 1] = page_index
        end
      end
    end
    for _, page_index in ipairs(pages_to_request) do
      request_timeline_page(page_index)
    end
    finish_if_ready()
  end

  if opts and opts.on_skeleton then
    opts.on_skeleton()
  end

  M.load_preview(repo, kind, id, hostname, function(shell, is_cached)
    if fallback_started or load_completed or details_received then
      return
    end
    local load_shell = shell
    load_shell._loadState = "shell"
    local shell_timeline = load_shell.timelineItems
    local count = shell_timeline and shell_timeline.filteredCount
    local shell_nodes = shell_timeline and shell_timeline.nodes or {}
    if type(count) ~= "number" or count < #shell_nodes then
      fallback()
      return
    end

    if not is_cached then
      start_page_fanout(count)
    end
    if details_received or fallback_started or load_completed then
      return
    end
    load_shell._timelineIncomplete = is_cached or count > #shell_nodes
    if opts and opts.on_shell then
      opts.on_shell(load_shell, is_cached)
    end
  end, function()
    fallback()
  end, opts and opts.auth_context)

  -- Two overlap pages can reveal the count while shell and details are in flight.
  for page_index = 1, 2 do
    if expected_count == nil then
      request_timeline_page(page_index)
    end
  end

  -- Phase two carries the complete details and page zero. It is independent of
  -- the shell response; either response can reveal the count needed to fan out.
  gh.api.graphql {
    query = phase_two_query,
    fields = fields,
    jq = ".",
    opts = {
      hostname = hostname,
      auth_context = opts and opts.auth_context,
      cb = gh.create_callback {
        failure = function()
          fallback()
        end,
        success = function(output)
          if fallback_started or load_completed then
            return
          end
          local ok, response = pcall(vim.json.decode, output)
          local connection = ok and vim.tbl_get(response, "data", "repository", key, "timelineItems") or nil
          if
            type(connection) ~= "table"
            or type(connection.filteredCount) ~= "number"
            or type(connection.nodes) ~= "table"
          then
            fallback()
            return
          end

          details_received = true
          if expected_count and expected_count ~= connection.filteredCount then
            fallback()
            return
          end
          full_response = response
          pages[0] = { filteredCount = connection.filteredCount, nodes = connection.nodes }
          start_page_fanout(connection.filteredCount)
          finish_if_ready()
        end,
      },
    },
  }

  if kind == "pull" then
    gh.api.graphql {
      query = queries.pull_request_review_threads,
      fields = fields,
      jq = ".",
      opts = {
        hostname = hostname,
        auth_context = opts and opts.auth_context,
        cb = gh.create_callback {
          failure = function()
            fallback()
          end,
          success = function(output)
            if fallback_started or load_completed then
              return
            end
            local ok, response = pcall(vim.json.decode, output)
            local threads = ok and vim.tbl_get(response, "data", "repository", "pullRequest", "reviewThreads") or nil
            if type(threads) ~= "table" or type(threads.nodes) ~= "table" then
              fallback()
              return
            end
            pull_review_threads = threads
            review_threads_received = true
            finish_if_ready()
          end,
        },
      },
    }
    gh.api.graphql {
      query = queries.pull_request_rulesets,
      fields = fields,
      jq = ".",
      opts = {
        hostname = hostname,
        auth_context = opts and opts.auth_context,
        cb = gh.create_callback {
          failure = function()
            fallback()
          end,
          success = function(output)
            if fallback_started or load_completed then
              return
            end
            local ok, response = pcall(vim.json.decode, output)
            local repository = ok and vim.tbl_get(response, "data", "repository") or nil
            local pull_request = type(repository) == "table" and repository.pullRequest or nil
            local rulesets = type(repository) == "table" and repository.rulesets or nil
            local opinionated_reviews = type(pull_request) == "table" and pull_request.latestOpinionatedReviews or nil
            if
              type(rulesets) ~= "table"
              or type(opinionated_reviews) ~= "table"
              or type(opinionated_reviews.nodes) ~= "table"
            then
              fallback()
              return
            end
            pull_rulesets = rulesets
            latest_opinionated_reviews = opinionated_reviews
            ruleset_details_received = true
            finish_if_ready()
          end,
        },
      },
    }
    gh.api.graphql {
      query = queries.pull_request_checks,
      fields = fields,
      jq = ".",
      opts = {
        hostname = hostname,
        auth_context = opts and opts.auth_context,
        cb = gh.create_callback {
          failure = function()
            fallback()
          end,
          success = function(output)
            if fallback_started or load_completed then
              return
            end
            local ok, response = pcall(vim.json.decode, output)
            local pull_request = ok and vim.tbl_get(response, "data", "repository", "pullRequest") or nil
            local checks = type(pull_request) == "table" and pull_request.statusCheckRollup or nil
            if checks == nil or (checks ~= vim.NIL and type(checks) ~= "table") then
              fallback()
              return
            end
            if checks ~= vim.NIL then
              pull_status_check_rollup = checks
            end
            checks_received = true
            finish_if_ready()
          end,
        },
      },
    }
  end
end

function M.render_signs()
  local buffer = utils.get_current_buffer()
  if not buffer then
    return
  end
  buffer:render_signs()
end

function M.on_cursor_hold()
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer = utils.get_current_buffer()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local function is_stale()
    local current_cursor = vim.api.nvim_win_get_cursor(0)
    return bufnr ~= vim.api.nvim_get_current_buf() or cursor[1] ~= current_cursor[1]
  end

  if buffer then
    -- reactions popup
    local id = buffer:get_reactions_at_cursor()
    if id then
      gh.api.graphql {
        query = queries.reactions_for_object,
        F = { id = id },
        opts = {
          cb = function(output, stderr)
            if is_stale() then
              return
            end
            if stderr and not utils.is_blank(stderr) then
              utils.print_err(stderr)
            elseif output then
              ---@type octo.queries.ReactionsForObject
              local resp = vim.json.decode(output)
              local reactions = {} ---@type table<string, string[]>
              local reactionGroups = resp.data.node.reactionGroups
              for _, reactionGroup in ipairs(reactionGroups) do
                local users = reactionGroup.users.nodes
                local logins = {} ---@type string[]
                for _, user in ipairs(users) do
                  table.insert(logins, user.login)
                end
                if #logins > 0 then
                  reactions[reactionGroup.content] = logins
                end
              end
              local popup_bufnr = vim.api.nvim_create_buf(false, true)
              local lines_count, max_length = writers.write_reactions_summary(popup_bufnr, reactions)
              window.create_popup {
                bufnr = popup_bufnr,
                width = 4 + max_length,
                height = 2 + lines_count,
              }
            end
          end,
        },
      }
      return
    end

    -- user popup
    local login = utils.extract_pattern_at_cursor(constants.USER_PATTERN)
    if login then
      if login:lower() == "copilot" then
        return
      end

      gh.api.graphql {
        query = queries.user_profile,
        jq = ".data.user",
        F = {
          login = login --[[@as string]],
        },
        opts = {
          cb = gh.create_callback {
            failure = utils.print_err,
            success = function(data)
              if is_stale() then
                return
              end
              ---@type octo.UserProfile
              local user = vim.json.decode(data)
              local popup_bufnr = vim.api.nvim_create_buf(false, true)
              local lines, max_length = writers.write_user_profile(popup_bufnr, user)
              window.create_popup {
                bufnr = popup_bufnr,
                width = 4 + max_length,
                height = 2 + lines,
              }
            end,
          },
        },
      }
      return
    end
  end

  -- link popup
  local repo, number = utils.extract_issue_at_cursor()
  if not repo or not number then
    number = utils.extract_pattern_at_cursor(constants.SHORT_ISSUE_PATTERN)
      or utils.extract_pattern_at_cursor(constants.SHORT_ISSUE_LINE_BEGINNING_PATTERN)
    if not number then
      return
    end
    repo = utils.get_current_repo()
  end
  if not repo or not number then
    return
  end
  ---@generic TData
  ---@param data TData
  ---@param write_summary fun(bufnr: integer, data: TData, opts: { max_length: integer }): integer
  local function write_popup(data, write_summary)
    local popup_bufnr = vim.api.nvim_create_buf(false, true)
    local max_length = 80
    local lines = write_summary(popup_bufnr, data, { max_length = max_length })
    window.create_popup {
      bufnr = popup_bufnr,
      width = 80,
      height = 2 + lines,
    }
  end
  local owner, name = utils.split_repo(repo)
  gh.api.graphql {
    query = queries.issue_summary,
    F = { owner = owner, name = name, number = number },
    jq = ".data.repository.issueOrPullRequest",
    opts = {
      cb = gh.create_callback {
        success = function(output)
          if is_stale() then
            return
          end
          ---@type octo.IssueOrPullRequestSummary
          local issue = vim.json.decode(output)
          write_popup(issue, writers.write_issue_summary)
        end,
        failure = function(_)
          if is_stale() then
            return
          end
          gh.api.graphql {
            query = queries.discussion_summary,
            F = { owner = owner, name = name, number = number },
            jq = ".data.repository.discussion",
            opts = {
              cb = gh.create_callback {
                failure = utils.print_err,
                success = function(output)
                  if is_stale() then
                    return
                  end
                  ---@type octo.DiscussionSummary
                  local discussion = vim.json.decode(output)
                  write_popup(discussion, writers.write_discussion_summary)
                end,
              },
            },
          }
        end,
      },
    },
  }
end

---@param kind "repo"|"discussion"|"release"|"issue"|"pull_request"
---@param obj octo.Issue|octo.PullRequest|octo.Discussion|octo.LoadShell|octo.Release|octo.Repository the object to render
---@param repo string repository full name like "owner/name"
---@param create boolean whether to create a new buffer
function M.create_buffer(kind, obj, repo, create, hostname)
  if not obj.id then
    utils.error("Cannot find " .. repo)
    return
  end

  local bufnr ---@type integer
  if create then
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(bufnr)
    -- Include hostname in buffer name if provided
    if hostname then
      vim.cmd(string.format("file octo://%s/%s/%s/%d", hostname, repo, kind, obj.number))
    else
      vim.cmd(string.format("file octo://%s/%s/%d", repo, kind, obj.number))
    end
  else
    bufnr = vim.api.nvim_get_current_buf()
  end

  if vim.b[bufnr].octo_loading_skeleton then
    vim.bo[bufnr].modifiable = true
    vim.b[bufnr].octo_loading_skeleton = nil
  end

  local octo_buffer = OctoBuffer:new {
    bufnr = bufnr,
    number = obj.number,
    repo = repo,
    hostname = hostname,
    node = obj,
    kind = kind,
  }

  octo_buffer:configure()
  if kind == "repo" then
    octo_buffer:render_repo()
  elseif kind == "discussion" then
    octo_buffer:render_discussion()
  elseif kind == "release" then
    octo_buffer:render_release()
  else
    octo_buffer:render_issue()
    octo_buffer:async_fetch_taggable_users()
    octo_buffer:async_fetch_issues()
  end
  -- Keep comment boundary signs in sync after any buffer reload,
  -- including polling refreshes while the window is unfocused.
  octo_buffer:render_signs()
  utils.clear_history()
  vim.bo[bufnr].modified = false
  require("octo.polling").track_buffer(bufnr)

  -- Navigate to anchor if one was set by Octo <url>
  local anchor = vim.b[bufnr].octo_pending_anchor
  if anchor then
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].octo_pending_anchor ~= anchor then
        return
      end
      local found = M.navigate_to_anchor(octo_buffer, anchor)
      if found or octo_buffer.node._loadState ~= "shell" then
        vim.b[bufnr].octo_pending_anchor = nil
      end
    end)
  end
end

---@param obj table
---@param repo string repository full name like "owner/name"
---@param create boolean whether to create a new buffer
---@param hostname string|nil optional GitHub Enterprise hostname
function M.create_pull_diff_buffer(obj, repo, create, hostname)
  local bufnr ---@type integer
  if create then
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(bufnr)
    if hostname then
      vim.cmd(string.format("file octo://%s/%s/pull/%d/diff", hostname, repo, obj.number))
    else
      vim.cmd(string.format("file octo://%s/pull/%d/diff", repo, obj.number))
    end
  else
    bufnr = vim.api.nvim_get_current_buf()
  end

  local octo_buffer = OctoBuffer:new {
    bufnr = bufnr,
    number = obj.number,
    repo = repo,
    node = obj,
    kind = "pull_diff",
  }

  octo_buffer:configure()
  octo_buffer:render_pull_diff()
  require("octo.polling").track_buffer(bufnr)
end

--- Navigate to a URL anchor (comment) within an octo buffer
---@param octo_buffer OctoBuffer
---@param anchor integer
function M.navigate_to_anchor(octo_buffer, anchor)
  return octo_buffer:navigate_to_comment { databaseId = anchor }
end

return M
