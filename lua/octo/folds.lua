local config = require "octo.config"

local M = {}

---@alias octo.DetailsBlock {open_line: integer, close_line: integer, summary: string, is_open: boolean, tag_lines: integer[]}
---@alias octo.DetailsBlockPartial {open_line: integer, summary_parts: string[], in_summary: boolean, is_open: boolean, tag_lines: integer[]}

function M.setup() end

-- Deferred fold state: when a buffer has no visible window, fold commands
-- are queued here and replayed on the next BufWinEnter.
---@type table<integer, fun()[]>
local pending_folds = {}

---@type table<integer, integer>  bufnr → augroup id
local deferred_augroups = {}

---Find a window displaying the given buffer.
---Folds are per-window, so fold commands must run in a window that shows the buffer.
---@param bufnr integer
---@return integer|nil
local function find_win_for_buf(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

---Replay all queued fold commands for a buffer in the given window.
---@param bufnr integer
---@param win integer
local function flush_pending_folds(bufnr, win)
  local fns = pending_folds[bufnr]
  pending_folds[bufnr] = nil
  if not fns or #fns == 0 then
    return
  end
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end
  vim.api.nvim_win_call(win, function()
    for _, fn in ipairs(fns) do
      pcall(fn)
    end
  end)
end

---Ensure BufWinEnter/BufWipeout autocmds exist for deferred fold replay.
---Idempotent per buffer.
---@param bufnr integer
local function ensure_deferred_autocmds(bufnr)
  if deferred_augroups[bufnr] then
    return
  end
  local group = vim.api.nvim_create_augroup("octo_deferred_folds_" .. bufnr, { clear = true })
  deferred_augroups[bufnr] = group

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      flush_pending_folds(bufnr, win)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      pending_folds[bufnr] = nil
      deferred_augroups[bufnr] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

---Execute a fold-related function in a window that displays the buffer.
---If no window currently shows the buffer, the function is deferred until
---BufWinEnter fires.
---@param bufnr integer
---@param fn fun()
local function in_buf_win(bufnr, fn)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local win = find_win_for_buf(bufnr)
  if win then
    vim.api.nvim_win_call(win, fn)
  else
    if not pending_folds[bufnr] then
      pending_folds[bufnr] = {}
    end
    table.insert(pending_folds[bufnr], fn)
    ensure_deferred_autocmds(bufnr)
  end
end

---Discard any queued fold operations for a buffer.
---Call this before re-rendering so stale line numbers are never replayed.
---@param bufnr integer
function M.clear_pending(bufnr)
  pending_folds[bufnr] = nil
end

---@param bufnr integer
---@param start_line integer
---@param end_line integer
---@param is_opened boolean
function M.create(bufnr, start_line, end_line, is_opened)
  if config.values.ui.use_foldtext then
    start_line = start_line - 1
  end
  in_buf_win(bufnr, function()
    vim.cmd [[setlocal foldmethod=manual]]
    vim.cmd(string.format("%d,%dfold", start_line, end_line))
    if is_opened then
      vim.cmd(string.format("%d,%dfoldopen", start_line, end_line))
    end
  end)
end

--- Parse lines for <details>...</details> HTML blocks.
--- Returns a list of block descriptors without touching the buffer.
---@param lines string[] buffer lines
---@param start_line integer 1-based buffer line of the first element in `lines`
---@return octo.DetailsBlock[]
function M.parse_details_blocks(lines, start_line)
  local stack = {} ---@type octo.DetailsBlockPartial[]
  local blocks = {} ---@type octo.DetailsBlock[]

  for i, line in ipairs(lines) do
    local buf_line = start_line + i - 1
    local lower = line:lower()

    if lower:match "%s*<details[^>]*>" then
      local is_open = lower:match "<details[^>]*%f[%a]open[%s=>]" ~= nil
      table.insert(
        stack,
        { open_line = buf_line, summary_parts = {}, in_summary = false, is_open = is_open, tag_lines = { buf_line } }
      )
    end

    if #stack > 0 then
      local top = stack[#stack]

      if #top.summary_parts == 0 and not top.in_summary then
        local s1, e1 = lower:find "<summary>"
        local s2, e2 = lower:find "</summary>"
        if s1 and s2 then
          -- Inline <summary>...</summary> on the same line
          top.summary_parts[1] = vim.trim(line:sub(e1 + 1, s2 - 1))
          if buf_line ~= top.open_line then
            table.insert(top.tag_lines, buf_line)
          end
        elseif s1 then
          -- Multi-line summary: start collecting
          top.in_summary = true
          if buf_line ~= top.open_line then
            table.insert(top.tag_lines, buf_line)
          end
          local after = line:sub(e1 + 1)
          if vim.trim(after) ~= "" then
            table.insert(top.summary_parts, vim.trim(after))
          end
        end
      elseif top.in_summary then
        -- All lines inside <summary>...</summary> are tag lines
        table.insert(top.tag_lines, buf_line)
        local close_start = lower:find "</summary>"
        if close_start then
          local before = line:sub(1, close_start - 1)
          if vim.trim(before) ~= "" then
            table.insert(top.summary_parts, vim.trim(before))
          end
          top.in_summary = false
        else
          local trimmed = vim.trim(line)
          if trimmed ~= "" then
            table.insert(top.summary_parts, trimmed)
          end
        end
      end

      -- Only match </details> when it's the entire line (ignore inline occurrences)
      if lower:match "^%s*</details>%s*$" then
        local block = table.remove(stack)
        if not block then
          goto continue
        end
        table.insert(block.tag_lines, buf_line)
        local summary = table.concat(block.summary_parts, " ")
        ---@type octo.DetailsBlock
        local finished = {
          open_line = block.open_line,
          close_line = buf_line,
          summary = (summary ~= "") and summary or "Details",
          is_open = block.is_open or false,
          tag_lines = block.tag_lines,
        }
        table.insert(blocks, finished)
      end
    end
    ::continue::
  end

  return blocks
end

--- Scan buffer lines for <details>...</details> HTML blocks and create
--- closed folds for each one. The <summary> text is shown as the fold line
--- via virtual text. All HTML tag lines are hidden with overlay extmarks.
---@param bufnr integer
---@param start_line integer first buffer line to scan (1-based)
---@param end_line integer last buffer line to scan (1-based)
function M.create_details_folds(bufnr, start_line, end_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  if #lines == 0 then
    return
  end
  local details_ns = vim.api.nvim_create_namespace "octo_details_folds"
  vim.api.nvim_buf_clear_namespace(bufnr, details_ns, start_line - 1, end_line)
  local blocks = M.parse_details_blocks(lines, start_line)

  for _, block in ipairs(blocks) do
    local fold_start = block.open_line
    local fold_end = block.close_line

    -- Summary overlay on the <details> line, padded to cover the underlying HTML
    local arrow = block.is_open and "▼" or "▶"
    local summary_text = arrow .. " " .. block.summary .. " …"
    local details_line_text = lines[fold_start - start_line + 1]
    local line_width = vim.api.nvim_strwidth(details_line_text)
    local overlay_width = vim.api.nvim_strwidth(summary_text)
    local virt_chunks = { { summary_text, "OctoDetailsBlock" } }
    if line_width > overlay_width then
      table.insert(virt_chunks, { string.rep(" ", line_width - overlay_width), "OctoDetailsBlock" })
    end

    -- Track which lines already get an extmark with an overlay
    local has_extmark = {} ---@type table<integer, boolean>

    vim.api.nvim_buf_set_extmark(bufnr, details_ns, fold_start - 1, 0, {
      virt_text = virt_chunks,
      virt_text_pos = "overlay",
      line_hl_group = "OctoDetailsBlock",
    })
    has_extmark[fold_start] = true

    -- Hide all other tag lines (summary tags, </details>) with blank overlays
    for _, tag_line in ipairs(block.tag_lines) do
      if tag_line ~= fold_start then
        local tag_text = lines[tag_line - start_line + 1]
        local tag_width = vim.api.nvim_strwidth(tag_text)
        vim.api.nvim_buf_set_extmark(bufnr, details_ns, tag_line - 1, 0, {
          virt_text = tag_width > 0 and { { string.rep(" ", tag_width), "OctoDetailsBlock" } } or nil,
          virt_text_pos = tag_width > 0 and "overlay" or nil,
          line_hl_group = "OctoDetailsBlock",
        })
        has_extmark[tag_line] = true
      end
    end

    -- Highlight remaining content lines with a subtle background
    for row = fold_start, fold_end do
      if not has_extmark[row] then
        vim.api.nvim_buf_set_extmark(bufnr, details_ns, row - 1, 0, {
          line_hl_group = "OctoDetailsBlock",
        })
      end
    end

    -- Create fold directly (not via M.create which applies use_foldtext offset)
    in_buf_win(bufnr, function()
      vim.cmd [[setlocal foldmethod=manual]]
      vim.cmd(string.format("%d,%dfold", fold_start, fold_end))
      if block.is_open then
        vim.cmd(string.format("%d,%dfoldopen", fold_start, fold_end))
      end
    end)
  end

  -- Attach fold arrow updaters (once per buffer)
  if #blocks > 0 and not vim.b[bufnr].octo_details_arrow_autocmd then
    vim.b[bufnr].octo_details_arrow_autocmd = true

    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = bufnr,
      callback = function()
        M.update_details_arrows(bufnr)
      end,
    })

    -- vim.on_key catches fold toggles that don't trigger CursorMoved
    local pending = false
    local on_key_ns = vim.api.nvim_create_namespace("octo_details_on_key_" .. bufnr)
    vim.on_key(function(_, typed)
      if not typed or typed == "" then
        return
      end
      if not vim.api.nvim_buf_is_valid(bufnr) then
        vim.on_key(nil, on_key_ns) -- removes the callback
        return
      end
      if vim.api.nvim_get_current_buf() ~= bufnr then
        return
      end
      if not pending then
        pending = true
        vim.schedule(function()
          pending = false
          if vim.api.nvim_buf_is_valid(bufnr) then
            M.update_details_arrows(bufnr)
          end
        end)
      end
    end, on_key_ns)
  end
end

--- Update arrow indicators on details fold summary lines based on fold state.
--- ▶ = closed, ▼ = open.
---@param bufnr integer
function M.update_details_arrows(bufnr)
  local details_ns = vim.api.nvim_create_namespace "octo_details_folds"
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, details_ns, 0, -1, { details = true })
  local arrow_closed = "▶"
  local arrow_open = "▼"
  local arrow_byte_len = #arrow_closed -- both are 3 bytes in UTF-8

  for _, extmark in ipairs(extmarks) do
    local id = extmark[1]
    local row = extmark[2]
    local details = extmark[4] ---@type vim.api.keyset.extmark_details?
    if not details then
      goto continue
    end
    local virt_text = details.virt_text
    if not virt_text or #virt_text == 0 then
      goto continue
    end

    local text = virt_text[1][1]
    local starts_closed = vim.startswith(text, arrow_closed)
    local starts_open = vim.startswith(text, arrow_open)
    if not starts_closed and not starts_open then
      goto continue
    end

    local is_folded = vim.fn.foldclosed(row + 1) ~= -1
    local want_arrow = is_folded and arrow_closed or arrow_open
    local have_arrow = starts_closed and arrow_closed or arrow_open

    if have_arrow ~= want_arrow then
      local rest = text:sub(arrow_byte_len + 1)
      virt_text[1][1] = want_arrow .. rest
      vim.api.nvim_buf_set_extmark(bufnr, details_ns, row, 0, {
        id = id,
        virt_text = virt_text,
        virt_text_pos = "overlay",
        line_hl_group = details.line_hl_group,
      })
    end

    ::continue::
  end
end

--- Custom foldtext for Octo buffers. For comment header folds, ensures the
--- whitespace before the fold icon has no background. For <details> folds,
--- displays the summary text from the overlay extmark.
function M.foldtext()
  local buf = vim.api.nvim_get_current_buf()
  local lnum = vim.v.foldstart
  local details_ns = vim.api.nvim_create_namespace "octo_details_folds"

  -- Check for <details> fold extmarks first
  local details_extmark =
    vim.api.nvim_buf_get_extmarks(buf, details_ns, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })[1]
  if details_extmark then
    local virt_text = vim.tbl_get(details_extmark, 4, "virt_text")
    if virt_text then
      return { virt_text[1] }
    end
  end

  -- Default behavior for other folds (comment headers, etc.)
  local extmark =
    vim.api.nvim_buf_get_extmarks(buf, -1, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true, type = "virt_text" })[1]

  local text = vim.tbl_get(extmark, 4, "virt_text", 1, 1)
  if text then
    return { { text:match "^%s+", "Normal" } }
  end
end

return M
