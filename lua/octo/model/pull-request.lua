local FileEntry = require("octo.reviews.file-entry").FileEntry
local gh = require "octo.gh"
local headers = require "octo.gh.headers"
local utils = require "octo.utils"

local M = {}

---https://docs.github.com/en/graphql/reference/enums#fileviewedstate
---@alias octo.FileViewedState "DISMISSED" | "VIEWED" | "UNVIEWED"

---@class PullRequest
---@field repo string
---@field head_repo string
---@field head_ref_name string
---@field hostname string?
---@field base_oid string
---@field head_oid string
---@field owner string
---@field name string
---@field number integer
---@field id string
---@field bufnr integer
---@field left Rev
---@field right Rev
---@field local_right boolean
---@field local_left boolean
---@field files {[string]: octo.FileViewedState}
---@field changed_files_count integer?
---@field left_ready boolean
---@field right_ready boolean
---@field file_metadata_waiters fun(pr: PullRequest)[]
---@field diff string
local PullRequest = {}
PullRequest.__index = PullRequest

---@class PullRequestOpts
---@field repo string
---@field head_repo string
---@field head_ref_name string
---@field hostname? string
---@field base_oid string
---@field head_oid string
---@field number integer
---@field id string
---@field left Rev
---@field right Rev
---@field bufnr? integer
---@field files { path: string, viewerViewedState: octo.FileViewedState }[]
---@field changed_files_count? integer
---@field left_commit_known? boolean

---PullRequest constructor.
---@param pull_request PullRequest
local function notify_file_metadata_ready(pull_request)
  if not pull_request.left_ready or not pull_request.right_ready then
    return
  end
  local waiters = pull_request.file_metadata_waiters
  pull_request.file_metadata_waiters = {}
  for _, callback in ipairs(waiters) do
    callback(pull_request)
  end
end

---@param callback fun(pr: PullRequest): nil
function PullRequest:when_file_metadata_ready(callback)
  if self.left_ready and self.right_ready then
    callback(self)
  else
    table.insert(self.file_metadata_waiters, callback)
  end
end

---@param opts PullRequestOpts
---@return PullRequest
function PullRequest:new(opts)
  ---@type PullRequest
  local this = {
    repo = opts.repo,
    head_repo = opts.head_repo,
    head_ref_name = opts.head_ref_name,
    hostname = opts.hostname,
    base_oid = opts.base_oid,
    head_oid = opts.head_oid,
    number = opts.number,
    owner = "",
    name = "",
    id = opts.id,
    left = opts.left,
    right = opts.right,
    local_right = false,
    local_left = false,
    bufnr = opts.bufnr,
    diff = "",
    files = {},
    changed_files_count = opts.changed_files_count,
    left_ready = false,
    right_ready = false,
    file_metadata_waiters = {},
  }
  for _, file in ipairs(opts.files) do
    this.files[file.path] = file.viewerViewedState
  end
  this.owner, this.name = utils.split_repo(this.repo)
  utils.commit_exists(this.right.commit, function(exists)
    this.local_right = exists
    this.right_ready = true
    notify_file_metadata_ready(this)
  end)
  if opts.left_commit_known ~= false then
    utils.commit_exists(this.left.commit, function(exists)
      this.local_left = exists
      this.left_ready = true
      notify_file_metadata_ready(this)
    end)
  end

  setmetatable(this, self)

  self:get_diff(this)

  return this
end

M.PullRequest = PullRequest

--- Fetch the diff of the PR
--- @param pr PullRequest
function PullRequest:get_diff(pr)
  gh.api.get {
    "/repos/{repo}/pulls/{number}",
    format = { repo = pr.repo, number = pr.number },
    paginate = true,
    opts = {
      hostname = pr.hostname,
      headers = { headers.diff },
      cb = gh.create_callback {
        success = function(diff)
          pr.diff = diff
        end,
      },
    },
  }
end

---Fetch changed files for the immutable PR base/head revision pair.
---@param callback fun(files: FileEntry[]): nil
---@param on_page? fun(files: FileEntry[]): nil
---@param on_error? fun(message: string): nil
function PullRequest:get_changed_files(callback, on_page, on_error)
  local head_oid = self.head_oid or self.right.commit
  if not head_oid or head_oid == "" then
    local message = "Cannot load review files without an immutable head commit"
    if on_error then
      on_error(message)
    else
      utils.error(message)
    end
    return
  end

  local function report_error(message)
    if on_error then
      on_error(message)
    else
      utils.error(message)
    end
  end

  local function check_pinned_head(then_load_files)
    gh.api.get {
      "/repos/{repo}/pulls/{number}",
      format = { repo = self.repo, number = self.number },
      jq = ".head.sha",
      opts = {
        hostname = self.hostname,
        cb = function(output, stderr, status)
          if status ~= nil and status ~= 0 then
            report_error(stderr or "Failed to verify pull request head revision")
            return
          end
          if not output then
            report_error(stderr or "Failed to verify pull request head revision")
            return
          end

          local head = vim.trim(output)
          local ok, decoded = pcall(vim.json.decode, head)
          if ok and type(decoded) == "string" then
            head = decoded
          end
          if head ~= head_oid then
            report_error "Pull request head changed while loading review; reopen the review"
            return
          end
          then_load_files()
        end,
      },
    }
  end

  local function load_files()
    gh.api.get {
      "/repos/{repo}/pulls/{number}/files",
      format = { repo = self.repo, number = self.number },
      paginate = true,
      slurp = true,
      opts = {
        hostname = self.hostname,
        cb = function(output, stderr, status)
          if status ~= nil and status ~= 0 then
            report_error(stderr or "Failed to load pull request files")
            return
          end
          if not output then
            report_error(stderr or "Pull request files response is empty")
            return
          end

          local ok, pages = pcall(vim.json.decode, output)
          if not ok or type(pages) ~= "table" then
            report_error "Pull request files response is invalid"
            return
          end

          local results = {}
          for _, page in ipairs(pages) do
            if type(page) ~= "table" then
              report_error "Pull request files response contains an invalid page"
              return
            end
            if page.filename then
              results[#results + 1] = page
            else
              for _, result in ipairs(page) do
                results[#results + 1] = result
              end
            end
          end

          if self.changed_files_count and #results ~= self.changed_files_count then
            report_error(
              string.format(
                "Changed file count changed while loading (expected %d, received %d)",
                self.changed_files_count,
                #results
              )
            )
            return
          end

          local files = {} ---@type FileEntry[]
          for _, result in ipairs(results) do
            files[#files + 1] = FileEntry:new {
              path = result.filename,
              previous_path = result.previous_filename,
              patch = result.patch,
              pull_request = self,
              status = utils.file_status_map[result.status],
              stats = {
                additions = result.additions,
                deletions = result.deletions,
                changes = result.changes,
              },
            }
          end
          check_pinned_head(function()
            if on_page then
              on_page(files)
            end
            callback(files)
          end)
        end,
      },
    }
  end

  check_pinned_head(load_files)
end

---Fetch the changed files at a given commit
---@param rev Rev
---@param callback fun(files: FileEntry[]): nil
function PullRequest:get_commit_changed_files(rev, callback)
  local files = {}
  local function fetch_page(page)
    -- `gh api --paginate` concatenates commit objects; native slurp expects
    -- individually decodable JSON pages, so fetch this endpoint explicitly.
    gh.api.get {
      "/repos/{repo}/commits/{commit_sha}?per_page=100&page={page}",
      format = { repo = self.repo, commit_sha = rev.commit, page = page },
      opts = {
        hostname = self.hostname,
        cb = gh.create_callback {
          success = function(output)
            ---@type {
            ---  files: {
            ---    filename: string,
            ---    previous_filename: string,
            ---    patch: string,
            ---    status: string,
            ---    additions: integer,
            ---    deletions: integer,
            ---    changes: integer,
            ---  }[],
            ---}
            local result = vim.json.decode(output)
            if type(result.files) ~= "table" then
              utils.error "Commit response has no file list"
              return
            end
            for _, file in ipairs(result.files) do
              files[#files + 1] = FileEntry:new {
                path = file.filename,
                previous_path = file.previous_filename,
                patch = file.patch,
                pull_request = self,
                status = utils.file_status_map[file.status],
                stats = {
                  additions = file.additions,
                  deletions = file.deletions,
                  changes = file.changes,
                },
              }
            end
            if #result.files == 100 then
              fetch_page(page + 1)
            else
              callback(files)
            end
          end,
        },
      },
    }
  end
  fetch_page(1)
end

---Helper function to create a PullRequest with merge base
---@param opts { repo: string, head_repo: string, head_ref_name: string, hostname?: string, number: integer, id: string, bufnr?: integer }
---@param obj octo.PullRequest
---@param cb fun(pull_request: PullRequest)
---@param on_early? fun(pull_request: PullRequest): nil
---@param on_error? fun(message: string): nil
function M.create_with_merge_base(opts, obj, cb, on_early, on_error)
  if obj._loadState == "shell" then
    local message = "Cannot start a review while pull request details are still loading"
    if on_error then
      on_error(message)
    else
      utils.error(message)
    end
    return
  end

  if type(obj.files) ~= "table" or type(obj.files.nodes) ~= "table" then
    local owner, name = utils.split_repo(opts.repo)
    gh.api.graphql {
      query = require("octo.gh.queries").pull_request_review_metadata,
      F = { owner = owner, name = name, number = opts.number },
      opts = {
        hostname = opts.hostname,
        cb = gh.create_callback {
          failure = function(message)
            if on_error then
              on_error("Failed to fetch complete pull request review data: " .. message)
            else
              utils.error("Failed to fetch complete pull request review data: " .. message)
            end
          end,
          success = function(output)
            local ok, response = pcall(vim.json.decode, output)
            local metadata = ok
                and type(response) == "table"
                and vim.tbl_get(response, "data", "repository", "pullRequest")
              or nil
            if
              type(metadata) ~= "table"
              or type(metadata.files) ~= "table"
              or type(metadata.files.nodes) ~= "table"
              or type(metadata.baseRefOid) ~= "string"
              or type(metadata.headRefOid) ~= "string"
            then
              local message = "Pull request review metadata is incomplete"
              if on_error then
                on_error(message)
              else
                utils.error(message)
              end
              return
            end
            if
              (type(obj.baseRefOid) == "string" and obj.baseRefOid ~= metadata.baseRefOid)
              or (type(obj.headRefOid) == "string" and obj.headRefOid ~= metadata.headRefOid)
            then
              local message = "Pull request revision changed while loading review; reopen the review"
              if on_error then
                on_error(message)
              else
                utils.error(message)
              end
              return
            end
            local hydrated = vim.tbl_extend("force", obj, {
              baseRefOid = metadata.baseRefOid,
              headRefOid = metadata.headRefOid,
              changedFiles = metadata.changedFiles,
              files = metadata.files,
            })
            M.create_with_merge_base(opts, hydrated, cb, on_early, on_error)
          end,
        },
      },
    }
    return
  end

  if
    type(obj.baseRefOid) ~= "string"
    or obj.baseRefOid == ""
    or type(obj.headRefOid) ~= "string"
    or obj.headRefOid == ""
  then
    local message = "Cannot start review without immutable base and head commits"
    if on_error then
      on_error(message)
    else
      utils.error(message)
    end
    return
  end

  local Rev = require("octo.reviews.rev").Rev
  local owner, name = utils.split_repo(opts.repo)
  local pr ---@type PullRequest?

  ---@param left_commit string
  ---@param left_commit_known boolean
  ---@return PullRequest
  local function create_pull_request(left_commit, left_commit_known)
    ---@type PullRequestOpts
    local pr_opts = vim.tbl_extend("force", opts, {
      left = Rev:new(left_commit),
      right = Rev:new(obj.headRefOid),
      files = obj.files.nodes,
      changed_files_count = obj.changedFiles,
      left_commit_known = left_commit_known,
      hostname = opts.hostname,
      base_oid = obj.baseRefOid,
      head_oid = obj.headRefOid,
    })
    return PullRequest:new(pr_opts)
  end

  local function finish_when_file_metadata_ready(pull_request)
    if not on_early then
      cb(pull_request)
      return
    end
    pull_request:when_file_metadata_ready(function(ready_pr)
      cb(ready_pr)
    end)
  end

  if on_early then
    pr = create_pull_request(obj.baseRefOid, false)
    on_early(pr)
  end

  local endpoint = string.format("repos/%s/%s/compare/%s...%s", owner, name, obj.baseRefOid, obj.headRefOid)

  local function use_base_oid_fallback(message)
    utils.error(message)
    if not pr then
      finish_when_file_metadata_ready(create_pull_request(obj.baseRefOid, true))
      return
    end
    pr.left = Rev:new(obj.baseRefOid)
    utils.commit_exists(obj.baseRefOid, function(exists)
      pr.local_left = exists
      pr.left_ready = true
      finish_when_file_metadata_ready(pr)
      notify_file_metadata_ready(pr)
    end)
  end

  local callback = gh.create_callback {
    success = function(merge_base_sha)
      if type(merge_base_sha) ~= "string" or merge_base_sha == "" or merge_base_sha == "null" then
        use_base_oid_fallback "Failed to resolve merge base: compare response did not include a merge-base SHA"
        return
      end

      if not pr then
        finish_when_file_metadata_ready(create_pull_request(merge_base_sha, true))
        return
      end

      pr.left = Rev:new(merge_base_sha)
      finish_when_file_metadata_ready(pr)
      utils.commit_exists(merge_base_sha, function(exists)
        pr.local_left = exists
        pr.left_ready = true
        notify_file_metadata_ready(pr)
      end)
    end,
    failure = function(stderr)
      use_base_oid_fallback("Failed to fetch merge base: " .. stderr)
    end,
  }

  gh.api.get {
    endpoint,
    jq = ".merge_base_commit.sha",
    opts = {
      hostname = opts.hostname,
      cb = callback,
    },
  }
end

return M
