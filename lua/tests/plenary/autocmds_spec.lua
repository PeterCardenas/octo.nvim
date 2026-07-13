describe("Octo autocommands:", function()
  local autocmds
  local octo
  local original_save_buffer
  local bufnr

  before_each(function()
    autocmds = require "octo.autocmds"
    octo = require "octo"
    original_save_buffer = octo.save_buffer
    vim.api.nvim_create_augroup("octo_autocmds", { clear = true })
  end)

  after_each(function()
    octo.save_buffer = original_save_buffer
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    vim.api.nvim_create_augroup("octo_autocmds", { clear = true })
    autocmds.setup()
  end)

  it("dispatches one save when setup runs more than once", function()
    local save_count = 0
    octo.save_buffer = function()
      save_count = save_count + 1
      vim.bo.modified = false
    end

    autocmds.setup()
    autocmds.setup()

    bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(bufnr, "octo://owner/repo/issue/1")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })

    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd.write()
    end)

    assert.are.equal(1, save_count)
  end)
end)
