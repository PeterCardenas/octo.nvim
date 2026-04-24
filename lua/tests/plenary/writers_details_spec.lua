---@diagnostic disable

local constants = require "octo.constants"

local function chunks_to_text(chunks)
  local text = ""
  for _, chunk in ipairs(chunks or {}) do
    text = text .. chunk[1]
  end
  return text
end

local function get_detail_lines(bufnr)
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_DETAILS_VT_NS, 0, -1, { details = true })
  local lines = {}
  for _, extmark in ipairs(extmarks) do
    table.insert(lines, chunks_to_text(vim.tbl_get(extmark, 4, "virt_text")))
  end
  return lines
end

local function get_detail_chunks(bufnr, text)
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_DETAILS_VT_NS, 0, -1, { details = true })
  for _, extmark in ipairs(extmarks) do
    local chunks = vim.tbl_get(extmark, 4, "virt_text")
    if chunks_to_text(chunks) == text then
      return chunks
    end
  end
end

local function make_pull_request()
  return {
    url = "https://github.com/octo-org/octo-repo/pull/42",
    state = "OPEN",
    stateReason = vim.NIL,
    isDraft = false,
    author = { login = "author" },
    viewerDidAuthor = false,
    authorAssociation = "NONE",
    createdAt = "2026-04-23T10:00:00Z",
    updatedAt = "2026-04-23T11:00:00Z",
    assignees = { nodes = {} },
    projectItems = { nodes = {} },
    labels = { nodes = {} },
    commits = { totalCount = 1 },
    timelineItems = { nodes = {} },
    reviewRequests = { totalCount = 0, nodes = {} },
    closingIssuesReferences = { totalCount = 0, nodes = {} },
    merged = false,
    headRefName = "feature/unstable-checks",
    baseRefName = "main",
    statusCheckRollup = {
      state = "FAILURE",
      contexts = {
        nodes = {
          {
            __typename = "CheckRun",
            isRequired = true,
            status = "COMPLETED",
            conclusion = "SUCCESS",
          },
          {
            __typename = "CheckRun",
            isRequired = false,
            status = "COMPLETED",
            conclusion = "FAILURE",
          },
        },
      },
    },
    mergeable = "MERGEABLE",
    mergeStateStatus = "UNSTABLE",
    changedFiles = 1,
    additions = 3,
    deletions = 1,
    viewerSubscription = "UNSUBSCRIBED",
  }
end

describe("PR details merge diagnostics", function()
  local writers

  before_each(function()
    package.loaded["octo.config"] = {
      values = {
        use_timeline_icons = false,
      },
    }
    package.loaded["octo.logins"] = {
      format_author = function(author)
        return author
      end,
      get_user_icon = function()
        return "@"
      end,
    }
    package.loaded["octo.ui.bubbles"] = {
      make_user_bubble = function(name)
        return { { name, "OctoUser" } }
      end,
      make_label_bubble = function(name)
        return { { name, "OctoLabel" } }
      end,
    }

    package.loaded["octo.ui.writers"] = nil
    writers = require "octo.ui.writers"
  end)

  it("shows unstable merge diagnostics from the shared checks breakdown helper", function()
    local bufnr = vim.api.nvim_create_buf(false, true)

    writers.write_details(bufnr, make_pull_request(), false, true)

    local lines = get_detail_lines(bufnr)
    assert.is_true(vim.tbl_contains(lines, "Merge: ! UNSTABLE"))
    assert.is_true(vim.tbl_contains(lines, "  ✓ 1 required check(s) passing"))
    assert.is_true(vim.tbl_contains(lines, "  × 1 optional check(s) failing"))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("does not highlight diagnostic indentation before the merge check icon", function()
    local bufnr = vim.api.nvim_create_buf(false, true)

    writers.write_details(bufnr, make_pull_request(), false, true)

    local chunks = get_detail_chunks(bufnr, "  × 1 optional check(s) failing")
    assert.is_not_nil(chunks)
    assert.are.same("  ", chunks[1][1])
    assert.are.same("", chunks[1][2])
    assert.are.same("× ", chunks[2][1])
    assert.are.same("OctoStateDismissed", chunks[2][2])

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
