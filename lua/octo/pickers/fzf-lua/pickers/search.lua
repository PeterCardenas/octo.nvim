---@diagnostic disable
local fzf_actions = require "octo.pickers.fzf-lua.pickers.fzf_actions"
local entry_maker = require "octo.pickers.fzf-lua.entry_maker"
local fzf = require "fzf-lua"
local gh = require "octo.gh"
local queries = require "octo.gh.queries"
local picker_utils = require "octo.pickers.fzf-lua.pickers.utils"
local utils = require "octo.utils"
local previewers = require "octo.pickers.fzf-lua.previewers"

---@param fzf_cb fzf-lua.fzfCb
---@param issue table
---@param max_id_length integer
---@param formatted_issues table<string, table> entry.ordinal -> entry
local function handle_issue_entry(fzf_cb, issue, max_id_length, formatted_issues)
  local entry = entry_maker.gen_from_issue(issue)
  if entry ~= nil then
    local owner, name = utils.split_repo(entry.repo)
    local raw_number = picker_utils.pad_string(entry.obj.number, max_id_length)
    local number = fzf.utils.ansi_from_hl("Comment", raw_number)
    local ordinal_entry = string.format("%s %s %s %s %s", entry.kind, owner, name, raw_number, entry.obj.title)
    local string_entry = string.format("%s %s %s %s %s", entry.kind, owner, name, number, entry.obj.title)
    formatted_issues[ordinal_entry] = entry
    fzf_cb(string_entry)
  end
end

---@param fzf_cb fzf-lua.fzfCb
---@param repo table
---@param formatted_repos table<string, table> stripped_entry_str -> entry
local function handle_repo_entry(fzf_cb, repo, formatted_repos)
  local entry, entry_str = entry_maker.gen_from_repo(repo)
  if entry ~= nil and entry_str ~= nil then
    formatted_repos[fzf.utils.strip_ansi_coloring(entry_str)] = entry
    fzf_cb(entry_str)
  end
end

return function(opts)
  opts = opts or {}
  opts.type = opts.type or "ISSUE"

  local is_repo_search = opts.type == "REPOSITORY"
  local formatted_items = {} ---@type table<string, table> entry.ordinal -> entry

  ---@type fzf-lua.shell.data2
  local function contents(args)
    local query = args[1] or ""

    return coroutine.wrap(
      ---@param fzf_cb fzf-lua.fzfCb
      function(fzf_cb)
        local co = coroutine.running()

        if not opts.prompt and utils.is_blank(query) then
          fzf_cb()
          return
        end

        if type(opts.prompt) == "string" then
          opts.prompt = { opts.prompt }
        end

        for _, val in ipairs(opts.prompt) do
          local _prompt = query
          if val then
            _prompt = string.format("%s %s", val, _prompt)
          end
          local output ---@type string
          gh.api.graphql {
            query = queries.search,
            jq = ".data.search.nodes",
            fields = { prompt = _prompt, type = opts.type },
            opts = {
              cb = gh.create_callback {
                success = function(stdout)
                  output = stdout
                  coroutine.resume(co)
                end,
                failure = function(stderr)
                  utils.error(stderr)
                  coroutine.resume(co)
                end,
              },
            },
          }
          coroutine.yield()

          if utils.is_blank(output) then
            fzf_cb()
            return
          end

          local results = vim.json.decode(output)

          if is_repo_search then
            for _, repo in ipairs(results) do
              handle_repo_entry(fzf_cb, repo, formatted_items)
            end
          else
            local max_id_length = 1
            for _, issue in ipairs(results) do
              local s = tostring(issue.number)
              if #s > max_id_length then
                max_id_length = #s
              end
            end

            for _, issue in ipairs(results) do
              handle_issue_entry(fzf_cb, issue, max_id_length, formatted_items)
            end
          end
        end

        fzf_cb()
      end
    )
  end

  local fzf_opts = {
    ["--info"] = "default",
  }
  if not is_repo_search then
    fzf_opts["--delimiter"] = " "
    fzf_opts["--with-nth"] = "4.."
  end

  fzf.fzf_live(contents, {
    prompt = picker_utils.get_prompt(opts.prompt_title),
    exec_empty_query = true,
    previewer = is_repo_search and previewers.repo(formatted_items) or previewers.search(),
    query_delay = 500,
    fzf_opts = fzf_opts,
    actions = fzf_actions.common_open_actions(formatted_items),
  })
end
