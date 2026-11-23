local config = require "octo.config"
local writers = require "octo.ui.writers"

local function render_timeline(nodes, order)
  local original_order = config.values.timeline_order
  local patched = {}
  local rendered = {}
  config.values.timeline_order = order

  local function patch(name, fn)
    patched[name] = writers[name]
    writers[name] = fn
  end

  patch("write_block", function() end)
  patch("write_closed_event", function(_, item)
    rendered[#rendered + 1] = "closed:" .. item.id
  end)
  patch("write_reopened_event", function(_, item)
    rendered[#rendered + 1] = "reopened:" .. item.id
  end)
  patch("write_commits", function(_, items)
    local ids = {}
    for _, item in ipairs(items) do
      ids[#ids + 1] = item.id
    end
    rendered[#rendered + 1] = "commits:" .. table.concat(ids, ",")
  end)
  patch("write_label_events", function(_, items)
    local names = {}
    for _, item in ipairs(items) do
      names[#names + 1] = item.label.name
    end
    rendered[#rendered + 1] = "labels:" .. table.concat(names, ",")
  end)

  writers.write_timeline_items(1, {
    timelineItems = { nodes = nodes },
    reviewThreads = { nodes = {} },
  })

  for name, fn in pairs(patched) do
    writers[name] = fn
  end
  config.values.timeline_order = original_order
  return rendered
end

describe("timeline order", function()
  local fixture

  before_each(function()
    fixture = vim.json.decode(table.concat(vim.fn.readfile "lua/tests/fixtures/timeline_order.json", "\n"))
  end)

  it("keeps chronological group contents and reverses only the groups", function()
    local nodes = fixture.timelineItems.nodes
    assert.same({
      "closed:closed-old",
      "commits:commit-1,commit-2",
      "closed:closed-middle",
      "labels:alpha,beta",
      "reopened:reopened",
      "commits:commit-3",
    }, render_timeline(nodes, "oldest_first"))

    assert.same({
      "commits:commit-3",
      "reopened:reopened",
      "labels:alpha,beta",
      "closed:closed-middle",
      "commits:commit-1,commit-2",
      "closed:closed-old",
    }, render_timeline(nodes, "newest_first"))
  end)

  it("renders an empty timeline without emitting items", function()
    assert.same({}, render_timeline({}, "newest_first"))
  end)

  it("ignores deleted timeline nodes when ordering groups", function()
    local nodes = {
      { __typename = "ClosedEvent", id = "first" },
      vim.NIL,
      { __typename = "ReopenedEvent", id = "last" },
    }
    assert.same({ "reopened:last", "closed:first" }, render_timeline(nodes, "newest_first"))
  end)
end)
