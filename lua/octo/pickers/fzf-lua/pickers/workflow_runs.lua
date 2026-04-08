local fzf = require "fzf-lua"
local octo_config = require "octo.config"
local utils = require "octo.utils"
local previewers = require "octo.pickers.fzf-lua.previewers"
local picker_utils = require "octo.pickers.fzf-lua.pickers.utils"

---@param workflow_runs table[]
---@param title string?
---@param on_select_cb function
return function(workflow_runs, title, on_select_cb)
  local formatted_runs = {} ---@type table<string, table>
  local entries = {} ---@type string[]

  for _, wf_run in ipairs(workflow_runs) do
    local status_text = fzf.utils.ansi_from_hl("Comment", wf_run.status)
    local title_text = wf_run.title
    local display_text = fzf.utils.ansi_from_hl("Directory", wf_run.display)
    local age_text = fzf.utils.ansi_from_hl("Comment", wf_run.age)

    local content = table.concat({ status_text, display_text, title_text, age_text }, " ")
    local entry_id = table.concat({ wf_run.status, wf_run.display, wf_run.title, wf_run.age }, " ")

    formatted_runs[entry_id] = wf_run
    table.insert(entries, content)
  end

  local cfg = octo_config.values
  local run_mappings = cfg.mappings.runs

  local actions = {
    ["default"] = function(selected)
      local wf_run = formatted_runs[selected[1]]
      on_select_cb(wf_run)
    end,
  }

  if not run_mappings.rerun.lhs:match "leader>" then
    actions[utils.convert_vim_mapping_to_fzf(run_mappings.rerun.lhs)] = function(selected)
      local wf_run = formatted_runs[selected[1]]
      require("octo.workflow_runs").rerun { db_id = wf_run.id }
    end
  end

  if not run_mappings.rerun_failed.lhs:match "leader>" then
    actions[utils.convert_vim_mapping_to_fzf(run_mappings.rerun_failed.lhs)] = function(selected)
      local wf_run = formatted_runs[selected[1]]
      require("octo.workflow_runs").rerun { db_id = wf_run.id, failed = true }
    end
  end

  if not run_mappings.cancel.lhs:match "leader>" then
    actions[utils.convert_vim_mapping_to_fzf(run_mappings.cancel.lhs)] = function(selected)
      local wf_run = formatted_runs[selected[1]]
      require("octo.workflow_runs").cancel(wf_run.id)
    end
  end

  fzf.fzf_exec(entries, {
    prompt = picker_utils.get_prompt(title or "Workflow runs"),
    previewer = previewers.workflow_run(formatted_runs),
    fzf_opts = {
      ["--no-multi"] = "",
      ["--info"] = "default",
    },
    winopts = {
      title = title or "Workflow runs",
      title_pos = "center",
    },
    actions = actions,
  })
end
