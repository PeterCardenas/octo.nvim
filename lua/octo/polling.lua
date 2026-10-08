local config = require "octo.config"
local date = require "octo.date"
local gh = require "octo.gh"
local queries = require "octo.gh.queries"
local uri = require "octo.uri"
local utils = require "octo.utils"
local vim = vim

local M = {}

---@class OctoPollingEntry
---@field owner string
---@field name string
---@field number integer
---@field kind string
---@field hostname string|nil
---@field last_updated_at string
---@field last_merge_state string
---@field last_check_fingerprint string
---@field last_diff_fingerprint string
---@field remote_changed boolean
---@field loading boolean
---@field last_polled_at number|nil

---@type table<integer, OctoPollingEntry>
local tracked_buffers = {}

---@type uv.uv_timer_t|nil
local timer = nil

---@class OctoPollingBudget
---@field remaining? number
---@field limit? number
---@field reset_at? number
---@field blocked_until number
---@field backoff number

-- Keep budgets across visibility-driven timer restarts, but separate GitHub hosts.
---@type table<string, OctoPollingBudget>
local budgets = {}

---@param tracking OctoPollingEntry
---@return OctoPollingBudget
local function budget_for(tracking)
  local hostname = tracking.hostname
  if utils.is_blank(hostname) then
    hostname = config.values.github_hostname
  end
  if utils.is_blank(hostname) then
    hostname = "github.com"
  end
  budgets[hostname] = budgets[hostname] or { blocked_until = 0, backoff = 0 }
  return budgets[hostname]
end

---@param tracking OctoPollingEntry
---@return boolean
local function poll_due(tracking)
  local budget = budget_for(tracking)
  local now = os.time()
  if now < budget.blocked_until then
    return false
  end
  local interval = config.values.poll.interval
  if budget.reset_at and now >= budget.reset_at then
    budget.remaining = nil
    budget.limit = nil
    budget.reset_at = nil
  end
  if budget.remaining and budget.limit then
    local fraction = budget.remaining / budget.limit
    local multiplier = fraction <= 0.05 and 12 or fraction <= 0.1 and 6 or fraction <= 0.2 and 3 or 1
    interval = interval * multiplier
  end
  return not tracking.last_polled_at or vim.uv.now() - tracking.last_polled_at >= interval
end

---@param tracking OctoPollingEntry
---@param response table|nil
---@param stderr string|nil
local function update_budget(tracking, response, stderr)
  local budget = budget_for(tracking)
  local rate = response and vim.tbl_get(response, "data", "rateLimit")
  if
    type(rate) == "table"
    and type(rate.limit) == "number"
    and rate.limit > 0
    and type(rate.remaining) == "number"
    and rate.remaining >= 0
    and type(rate.resetAt) == "string"
  then
    -- The existing date library interprets GitHub's UTC reset time independently of local timezone.
    local ok, seconds_until_reset = pcall(function()
      return date.diff(rate.resetAt, os.time()):spanseconds()
    end)
    if ok and seconds_until_reset > 0 then
      budget.limit = rate.limit
      budget.remaining = rate.remaining
      budget.reset_at = os.time() + seconds_until_reset
      -- Leave the final 1% available for opening, editing and refreshing manually.
      if rate.remaining <= rate.limit * 0.01 then
        budget.blocked_until = math.max(budget.blocked_until, budget.reset_at)
      end
    end
  end

  local errors = response and response.errors
  local message = ((stderr or "") .. (errors and vim.json.encode(errors) or "")):lower()
  if message:find("rate limit", 1, true) or message:find("rate_limit", 1, true) then
    -- An exhausted query may contain only errors. Reuse its last known reset;
    -- secondary limits (or unknown resets) instead get bounded exponential backoff.
    if budget.reset_at and message:find("secondary", 1, true) == nil then
      budget.blocked_until = math.max(budget.blocked_until, budget.reset_at)
    else
      budget.backoff = math.min(math.max(60, budget.backoff * 2), 900)
      budget.blocked_until = math.max(budget.blocked_until, os.time() + budget.backoff)
    end
  elseif utils.is_blank(stderr) and not errors then
    budget.backoff = 0
  end
end

---Compute a fingerprint from statusCheckRollup for change detection.
---Includes the overall state plus each individual check's status, so the
---fingerprint changes when any single check transitions (not just when the
---aggregate rollup flips).
---@param rollup table|nil  statusCheckRollup node
---@return string
local function check_fingerprint(rollup)
  if utils.is_blank(rollup) then
    return ""
  end
  local parts = { rollup.state or "" }
  local nodes = vim.tbl_get(rollup, "contexts", "nodes")
  if type(nodes) == "table" then
    for _, node in ipairs(nodes) do
      -- CheckRun has status+conclusion; StatusContext has state
      -- conclusion is null (vim.NIL) while a check is still in progress
      local status = utils.is_blank(node.status) and "" or node.status
      local conclusion = utils.is_blank(node.conclusion) and "" or node.conclusion
      local state = utils.is_blank(node.state) and "" or node.state
      parts[#parts + 1] = status .. conclusion .. state
    end
  end
  return table.concat(parts, ",")
end

---@param node table|nil
---@return string
local function diff_fingerprint(node)
  if utils.is_blank(node) then
    return ""
  end
  local base_ref_oid = utils.is_blank(node.baseRefOid) and "" or node.baseRefOid
  local head_ref_oid = utils.is_blank(node.headRefOid) and "" or node.headRefOid
  if base_ref_oid == "" and head_ref_oid == "" then
    return ""
  end
  return base_ref_oid .. "..." .. head_ref_oid
end

---Start the timer loop
---@param interval number
local function start_timer(interval)
  timer = vim.uv.new_timer()
  if not timer then
    return
  end
  timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      for bufnr, tracking in pairs(tracked_buffers) do
        if not vim.api.nvim_buf_is_valid(bufnr) then
          tracked_buffers[bufnr] = nil
        elseif
          (tracking.kind == "issue" or tracking.kind == "pull" or tracking.kind == "pull_diff")
          and not tracking.loading
          and (not config.values.poll.should_poll_buffer or config.values.poll.should_poll_buffer(bufnr))
          and poll_due(tracking)
        then
          tracking.loading = true
          tracking.last_polled_at = vim.uv.now()
          local query = tracking.kind == "pull_diff" and queries.pull_diff_fingerprint or queries.updated_at
          gh.api.graphql {
            query = query,
            F = {
              owner = tracking.owner,
              name = tracking.name,
              number = tracking.number,
            },
            jq = ".",
            opts = {
              hostname = tracking.hostname,
              cb = function(output, stderr)
                local function finish()
                  if tracked_buffers[bufnr] == tracking then
                    tracking.loading = false
                  end
                end

                local ok, resp = pcall(vim.json.decode, output or "")
                if not ok or type(resp) ~= "table" then
                  resp = nil
                end
                -- Read partial rate-limit data before handling errors: GraphQL can
                -- report exhaustion with HTTP 200 and no repository result.
                update_budget(tracking, resp, stderr)
                if (stderr and not utils.is_blank(stderr)) or not resp or resp.errors then
                  finish()
                  return
                end
                local node
                if tracking.kind == "pull_diff" then
                  node = vim.tbl_get(resp, "data", "repository", "pullRequest")
                else
                  node = vim.tbl_get(resp, "data", "repository", "issueOrPullRequest")
                end
                if not node then
                  finish()
                  return
                end

                local current_tracking = tracked_buffers[bufnr]

                if current_tracking ~= tracking then
                  finish()
                  return
                end

                local remote_updated_at = node.updatedAt or ""
                local remote_merge_state = node.mergeStateStatus or ""
                local remote_diff_fp = diff_fingerprint(node)
                local remote_rollup = vim.tbl_get(node, "commits", "nodes", 1, "commit", "statusCheckRollup")
                local remote_check_fp = check_fingerprint(remote_rollup)

                if tracking.kind == "pull_diff" and remote_diff_fp == current_tracking.last_diff_fingerprint then
                  finish()
                  return
                end

                if
                  tracking.kind ~= "pull_diff"
                  and remote_updated_at == current_tracking.last_updated_at
                  and remote_merge_state == current_tracking.last_merge_state
                  and remote_check_fp == current_tracking.last_check_fingerprint
                then
                  finish()
                  return
                end

                local octo_buf = octo_buffers[bufnr]
                if not octo_buf then
                  finish()
                  return
                end

                local conf = config.values.poll
                local function mark_remote_changed()
                  local latest_tracking = tracked_buffers[bufnr]
                  if latest_tracking ~= tracking then
                    finish()
                    return
                  end
                  latest_tracking.remote_changed = true
                  latest_tracking.loading = false
                  if conf.notify_on_change then
                    utils.info(
                      string.format(
                        "Remote changes detected for %s/%s #%d (buffer has local edits, skipping reload)",
                        tracking.owner,
                        tracking.name,
                        tracking.number
                      )
                    )
                  end
                end

                if octo_buf:has_local_changes() then
                  mark_remote_changed()
                else
                  require("octo").load_buffer {
                    bufnr = bufnr,
                    respect_local_changes = true,
                    on_local_changes = mark_remote_changed,
                    on_error = finish,
                    on_reload = function()
                      local latest_tracking = tracked_buffers[bufnr]
                      if latest_tracking ~= tracking then
                        finish()
                        return
                      end
                      latest_tracking.last_updated_at = remote_updated_at
                      latest_tracking.last_merge_state = remote_merge_state
                      latest_tracking.last_check_fingerprint = remote_check_fp
                      latest_tracking.last_diff_fingerprint = remote_diff_fp
                      latest_tracking.remote_changed = false
                      latest_tracking.loading = false
                      if conf.notify_on_refresh then
                        utils.info(
                          string.format("Auto-refreshed %s/%s #%d", tracking.owner, tracking.name, tracking.number)
                        )
                      end
                    end,
                  }
                end
              end,
            },
          }
        end
      end
    end)
  )
end

---Stop and clean up the timer
local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

---Start the polling timer
function M.start()
  if timer then
    return
  end

  local conf = config.values.poll
  if not conf then
    return
  end

  if vim.tbl_count(tracked_buffers) == 0 then
    utils.info "No octo buffers to poll"
    return
  end

  start_timer(conf.interval)
  utils.info "Octo polling started"
end

---Stop the polling timer
function M.stop()
  if timer then
    stop_timer()
    utils.info "Octo polling stopped"
  end
end

---Enable or disable polling, including future auto-starts when buffers are tracked.
---@param enabled boolean
function M.set_enabled(enabled)
  config.values.poll.enabled = enabled
  if enabled then
    M.start()
  else
    M.stop()
  end
end

---Toggle polling on/off (also updates the runtime config)
function M.toggle()
  M.set_enabled(timer == nil)
end

---Register a buffer for polling
---@param bufnr integer
function M.track_buffer(bufnr)
  local conf = config.values.poll
  if not conf then
    return
  end

  local octo_buf = octo_buffers[bufnr]
  if not octo_buf then
    return
  end

  -- Only track issues, pull requests, and pull request diffs
  if octo_buf.kind ~= "issue" and octo_buf.kind ~= "pull" and octo_buf.kind ~= "pull_diff" then
    return
  end

  local owner, name = utils.split_repo(octo_buf.repo)
  local bufname = vim.fn.bufname(bufnr)
  local buffer_info = uri.parse(bufname)
  local hostname = buffer_info and buffer_info.hostname or nil

  local node = octo_buf.node
  local merge_state = (node and node.mergeStateStatus) or ""
  local check_fp = check_fingerprint(node and node.statusCheckRollup)

  tracked_buffers[bufnr] = {
    owner = owner,
    name = name,
    number = octo_buf.number,
    kind = octo_buf.kind,
    hostname = hostname,
    last_updated_at = octo_buf:get_updated_at() or "",
    last_merge_state = merge_state,
    last_check_fingerprint = check_fp,
    last_diff_fingerprint = octo_buf:get_diff_fingerprint(),
    remote_changed = false,
    loading = false,
    last_polled_at = tracked_buffers[bufnr] and tracked_buffers[bufnr].last_polled_at,
  }

  -- Auto-start timer if enabled and this is the first tracked buffer
  if conf.enabled and not timer and vim.tbl_count(tracked_buffers) > 0 then
    start_timer(conf.interval)
  end
end

---Unregister a buffer from polling
---@param bufnr integer
function M.untrack_buffer(bufnr)
  tracked_buffers[bufnr] = nil

  -- Auto-stop timer if no tracked buffers remain
  if vim.tbl_count(tracked_buffers) == 0 then
    stop_timer()
  end
end

---Get polling status
---@return { enabled: boolean, running: boolean, tracked_count: integer, buffers: table<integer, OctoPollingEntry> }
function M.status()
  local conf = config.values.poll
  return {
    enabled = conf and conf.enabled or false,
    running = timer ~= nil,
    tracked_count = vim.tbl_count(tracked_buffers),
    buffers = tracked_buffers,
  }
end

---Force-reload a dirty buffer that has pending remote changes
---@param bufnr? integer defaults to current buffer
function M.apply_pending(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local tracking = tracked_buffers[bufnr]
  if not tracking then
    utils.info "Buffer is not tracked for polling"
    return
  end
  if not tracking.remote_changed then
    utils.info "No pending remote changes for this buffer"
    return
  end

  require("octo").load_buffer { bufnr = bufnr }
  tracking.remote_changed = false
  utils.info(
    string.format("Applied pending remote changes for %s/%s #%d", tracking.owner, tracking.name, tracking.number)
  )
end

return M
