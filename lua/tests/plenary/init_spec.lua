---@diagnostic disable

describe("Octo module:", function()
  local octo

  before_each(function()
    package.loaded["octo"] = nil
    octo = require "octo"
  end)

  it("navigates to numeric URL anchors", function()
    local received
    local octo_buffer = {
      navigate_to_comment = function(_, opts)
        received = opts
      end,
    }

    assert.has_no.errors(function()
      octo.navigate_to_anchor(octo_buffer, 3185672857)
    end)
    assert.are.same({ databaseId = 3185672857 }, received)
  end)
end)
