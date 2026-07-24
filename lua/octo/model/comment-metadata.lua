local M = {}

---@class CommentMetadata
---@field id string
---@field databaseId integer
---@field author string
---@field savedBody string
---@field body string
---@field dirty boolean
---@field extmark? integer
---@field startLine? integer
---@field endLine? integer
---@field vtExtmark? integer
---@field reactionGroups table[]
---@field reactionLine? integer
---@field viewerCanUpdate boolean
---@field viewerCanDelete boolean
---@field viewerDidAuthor boolean
---@field state? string
---@field kind string
---@field replyTo string|{ id: string, url?: string }
---@field replyToRest? string
---@field reviewId string
---@field path string
---@field diffSide string
---@field snippetStartLine integer
---@field snippetEndLine integer
---@field bufferStartLine? integer
---@field bufferEndLine? integer
---@field lastEditedAt? string
---@field includesCreatedEdit? boolean
---@field subjectType? octo.SubjectType
local CommentMetadata = {}
CommentMetadata.__index = CommentMetadata

---CommentMetadata constructor.
---@param opts CommentMetadata
---@return CommentMetadata
function CommentMetadata:new(opts)
  ---@type CommentMetadata
  local this = {
    author = opts.author,
    id = opts.id,
    databaseId = opts.databaseId,
    dirty = opts.dirty or false,
    savedBody = opts.savedBody,
    body = opts.body,
    extmark = opts.extmark,
    vtExtmark = opts.vtExtmark,
    viewerCanUpdate = opts.viewerCanUpdate,
    viewerCanDelete = opts.viewerCanDelete,
    viewerDidAuthor = opts.viewerDidAuthor,
    state = opts.state,
    reactionLine = opts.reactionLine,
    reactionGroups = opts.reactionGroups,
    kind = opts.kind,
    replyTo = opts.replyTo,
    replyToRest = opts.replyToRest,
    reviewId = opts.reviewId,
    path = opts.path,
    diffSide = opts.diffSide,
    startLine = opts.startLine,
    endLine = opts.endLine,
    snippetStartLine = opts.snippetStartLine,
    snippetEndLine = opts.snippetEndLine,
    lastEditedAt = opts.lastEditedAt,
    includesCreatedEdit = opts.includesCreatedEdit,
    subjectType = opts.subjectType,
  }
  setmetatable(this, self)
  return this
end

M.CommentMetadata = CommentMetadata

return M
