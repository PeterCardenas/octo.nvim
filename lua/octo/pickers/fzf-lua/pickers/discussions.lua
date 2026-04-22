---@diagnostic disable
local fzf_actions = require "octo.pickers.fzf-lua.pickers.fzf_actions"
local entry_maker = require "octo.pickers.fzf-lua.entry_maker"
local fzf = require "fzf-lua"
local gh = require "octo.gh"
local queries = require "octo.gh.queries"
local octo_config = require "octo.config"
local picker_utils = require "octo.pickers.fzf-lua.pickers.utils"
local previewers = require "octo.pickers.fzf-lua.previewers"
local utils = require "octo.utils"

return function(opts)
  opts = opts or {}

  local repo = utils.pop_key(opts, "repo")
  if utils.is_blank(repo) then
    repo = utils.get_remote_name()
  end
  if not repo then
    utils.error "Cannot find repo"
    return
  end

  local owner, name = utils.split_repo(repo)
  local cfg = octo_config.values

  local window_title = utils.pop_key(opts, "window_title") or "Discussions"
  local prompt_title = utils.pop_key(opts, "prompt_title")

  local formatted_discussions = {} ---@type table<string, table> entry.ordinal -> entry

  local function get_contents(fzf_cb)
    gh.api.graphql {
      query = queries.discussions,
      fields = {
        owner = owner,
        name = name,
        states = { "OPEN" },
        orderBy = cfg.discussions.order_by.field,
        direction = cfg.discussions.order_by.direction,
      },
      paginate = true,
      jq = ".",
      opts = {
        stream_cb = function(data, err)
          if err and not utils.is_blank(err) then
            utils.error(err)
            fzf_cb()
          elseif data then
            local resp = utils.aggregate_pages(data, "data.repository.discussions.nodes")
            local discussions = resp.data.repository.discussions.nodes

            for _, discussion in ipairs(discussions) do
              local entry = entry_maker.gen_from_issue(discussion)

              if entry ~= nil then
                formatted_discussions[entry.ordinal] = entry
                local prefix = fzf.utils.ansi_from_hl("Comment", entry.value)
                fzf_cb(prefix .. " " .. entry.obj.title)
              end
            end
          end
        end,
        cb = function()
          fzf_cb()
        end,
      },
    }
  end

  local actions = fzf_actions.common_open_actions(formatted_discussions)
  if opts.cb ~= nil then
    actions.default = function(selected)
      local entry = formatted_discussions[selected[1]]
      if entry then
        opts.cb(entry)
      end
    end
  end

  fzf.fzf_exec(get_contents, {
    prompt = picker_utils.get_prompt(prompt_title),
    previewer = previewers.issue(formatted_discussions, "Discussions"),
    fzf_opts = {
      ["--no-multi"] = "",
      ["--info"] = "default",
    },
    winopts = {
      title = window_title,
      title_pos = "center",
    },
    actions = actions,
  })
end
