---@diagnostic disable
local FilePanel = require("octo.reviews.file-panel").FilePanel
local config = require "octo.config"
local renderer = require "octo.reviews.renderer"
local reviews = require "octo.reviews"
local utils = require "octo.utils"
local eq = assert.are.same

---Minimal stand-ins for FileEntry: the panel only reads these fields.
---@param path string
local function file(path, stats)
  return {
    path = path,
    basename = utils.path_basename(path),
    extension = utils.path_extension(path),
    status = "M",
    viewed_state = "UNVIEWED",
    stats = stats or { additions = 1, deletions = 1, changes = 2 },
  }
end

---Build a panel that renders into `render_data` without needing a real buffer.
---@param files table[]
local function panel_for(files)
  local panel = FilePanel:new(files)
  panel.render_data = renderer.RenderData:new "OctoFilePanelSpec"
  panel:render()
  return panel
end

describe("File panel:", function()
  local original_reviews, original_use_icons, original_listing_style

  before_each(function()
    original_reviews = reviews.reviews
    original_use_icons = config.values.file_panel.use_icons
    original_listing_style = config.values.file_panel.listing_style
    -- Icons depend on nvim-web-devicons, which is not a test dependency.
    config.values.file_panel.use_icons = false

    reviews.reviews = {
      [tostring(vim.api.nvim_get_current_tabpage())] = {
        threads = {},
        layout = {
          left = {
            abbrev = function()
              return "aaaaaaa"
            end,
          },
          right = {
            abbrev = function()
              return "bbbbbbb"
            end,
          },
        },
      },
    }
  end)

  after_each(function()
    reviews.reviews = original_reviews
    config.values.file_panel.use_icons = original_use_icons
    config.values.file_panel.listing_style = original_listing_style
  end)

  it("maps only file lines, so the footer is not mistaken for the last file", function()
    config.values.file_panel.listing_style = "list"
    local files = { file "README.md", file "src/core/engine.lua" }
    local panel = panel_for(files)

    -- Line 0 is the "Files changed" header.
    eq(nil, panel.line_to_file[0])
    eq(files[1], panel.line_to_file[1])
    eq(files[2], panel.line_to_file[2])
    eq(1, panel.file_to_line[files[1]])
    eq(2, panel.file_to_line[files[2]])

    -- The trailing "Showing changes for:" block owns no file.
    for line = 3, #panel.render_data.lines - 1 do
      eq(nil, panel.line_to_file[line])
    end
  end)

  it("renders full paths in list style", function()
    config.values.file_panel.listing_style = "list"
    local files = { file "src/core/engine.lua" }
    local panel = panel_for(files)

    assert.is_truthy(panel.render_data.lines[2]:find("src/core/engine.lua", 1, true))
  end)

  it("hoists directories into group lines in tree style", function()
    config.values.file_panel.listing_style = "tree"
    local files = {
      file "README.md",
      file "src/core/engine.lua",
      file "src/core/state.lua",
    }
    local panel = panel_for(files)
    local lines = panel.render_data.lines

    eq(".", lines[2])
    assert.is_truthy(lines[3]:find("README.md", 1, true))
    eq("src/core", lines[4])
    assert.is_truthy(lines[5]:find("engine.lua", 1, true))
    assert.is_truthy(lines[6]:find("state.lua", 1, true))

    -- Basenames only: the directory is not repeated on the file's own line.
    assert.is_nil(lines[5]:find("src/core/engine.lua", 1, true))

    -- Group lines are not selectable.
    eq(nil, panel.line_to_file[1])
    eq(nil, panel.line_to_file[3])
    eq(files[2], panel.line_to_file[4])
    eq(files[3], panel.line_to_file[5])
  end)

  it("emits one group line per directory", function()
    config.values.file_panel.listing_style = "tree"
    local files = {
      file "docs/a.md",
      file "docs/b.md",
      file "src/c.lua",
    }
    local lines = panel_for(files).render_data.lines

    local groups = 0
    for _, line in ipairs(lines) do
      if line == "docs" or line == "src" then
        groups = groups + 1
      end
    end
    eq(2, groups)
  end)
end)
