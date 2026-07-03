local config = require "octo.config"
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

---@type table<integer, OctoPollingEntry>
local tracked_buffers = {}

---@type uv.uv_timer_t|nil
local timer = nil

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
          (tracking.kind == "issue" or tracking.kind == "pull" or tracking.kind == "pull_diff") and not tracking.loading
        then
          tracking.loading = true
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
                  local current_tracking = tracked_buffers[bufnr]
                  if current_tracking then
                    current_tracking.loading = false
                  end
                end

                if stderr and not utils.is_blank(stderr) then
                  finish()
                  return
                end
                if not output or utils.is_blank(output) then
                  finish()
                  return
                end

                local ok, resp = pcall(vim.json.decode, output)
                if not ok or not resp then
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

                local current_tracking = tracked_buffers[bufnr] or tracking
                local function tracking_matches(candidate)
                  return candidate
                    and candidate.owner == tracking.owner
                    and candidate.name == tracking.name
                    and candidate.number == tracking.number
                    and candidate.kind == tracking.kind
                    and candidate.hostname == tracking.hostname
                end

                if not tracking_matches(current_tracking) then
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
                  local latest_tracking = tracked_buffers[bufnr] or current_tracking
                  if not tracking_matches(latest_tracking) then
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
                      local latest_tracking = tracked_buffers[bufnr] or current_tracking
                      if not tracking_matches(latest_tracking) then
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

---Toggle polling on/off (also updates the runtime config)
function M.toggle()
  if timer then
    config.values.poll.enabled = false
    M.stop()
  else
    config.values.poll.enabled = true
    M.start()
  end
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
