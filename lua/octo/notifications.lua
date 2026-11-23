local gh = require "octo.gh"
local headers = require "octo.gh.headers"
local utils = require "octo.utils"
local writers = require "octo.ui.writers"
local queries = require "octo.gh.queries"
local release = require "octo.release"

local M = {}

---@param thread_id string
function M.request_read_notification(thread_id)
  gh.api.patch {
    "/notifications/threads/{id}",
    format = { id = thread_id },
    opts = {
      cb = gh.create_callback { success = function() end },
      headers = { headers.json },
    },
  }
end

---@param thread_id string
function M.delete_notification(thread_id)
  local opts = {
    cb = gh.create_callback { success = function() end },
    headers = { headers.diff },
  }
  gh.api.delete {
    "/notifications/threads/{id}",
    format = { id = thread_id },
    opts = opts,
  }
end

---@param thread_id string
function M.unsubscribe_notification(thread_id)
  gh.api.delete {
    "/notifications/threads/{id}/subscription",
    format = { id = thread_id },
    opts = {
      cb = gh.create_callback {
        success = function()
          M.request_read_notification(thread_id)
        end,
      },
      headers = { headers.json },
    },
  }
end

---@param notification octo.NotificationFromREST
function M.copy_notification_url(notification)
  local subject = notification.subject
  local url = not utils.is_blank(subject.latest_comment_url) and subject.latest_comment_url or subject.url

  gh.api.get {
    url,
    jq = ".html_url",
    opts = {
      cb = gh.create_callback { success = utils.copy_url },
    },
  }
end

---@param owner string
---@param name string
---@param number string
---@param kind string
---@param on_success fun(obj: table, cached?: boolean): nil
function M.fetch_preview(owner, name, number, kind, on_success)
  ---@param query string
  ---@param fields table<string, string>
  ---@param jq string
  local function inner_fetch(query, fields, jq)
    gh.api.graphql {
      query = query,
      fields = fields,
      jq = jq,
      opts = {
        cb = gh.create_callback {
          failure = utils.print_err,
          success = function(output)
            local ok, obj = pcall(vim.json.decode, output)
            if not ok then
              utils.error("Failed to parse preview data: " .. vim.inspect(output))
              return
            end
            on_success(obj, false)
          end,
        },
      },
    }
  end

  if kind == "release" then
    -- GraphQL only accepts tags and release notifications give back IDs
    release.get_tag_from_release_id({ owner = owner, repo = name, release_id = number }, function(tag_name)
      inner_fetch(queries.release, { owner = owner, name = name, tag = tag_name }, ".data.repository.release")
    end)
    return
  end

  if kind == "issue" or kind == "pull_request" or kind == "discussion" then
    local octo = require "octo"
    local repo = owner .. "/" .. name
    local on_error = function(stderr)
      utils.print_err(stderr)
    end
    if kind == "pull_request" then
      octo.load_pull_preview(repo, number, nil, on_success, on_error)
    else
      octo.load_preview(repo, kind, number, nil, on_success, on_error)
    end
  end
end

---@param kind string
---@return fun(obj: any, bufnr: integer): nil
function M.get_preview_fn(kind)
  ---@type fun(obj: any, bufnr: integer): nil
  local preview
  if kind == "issue" then
    preview = writers.issue_preview
  elseif kind == "pull_request" then
    preview = writers.issue_preview
  elseif kind == "discussion" then
    preview = writers.discussion_preview
  elseif kind == "release" then
    preview = writers.release_preview
  end

  return preview
end

return M
