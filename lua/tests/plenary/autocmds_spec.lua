describe("Octo autocommands:", function()
  local autocmds
  local octo
  local original_save_buffer
  local original_invalidate_load
  local original_octo_buffers
  local bufnr

  before_each(function()
    autocmds = require "octo.autocmds"
    octo = require "octo"
    original_save_buffer = octo.save_buffer
    original_invalidate_load = octo.invalidate_load
    original_octo_buffers = _G.octo_buffers
    vim.api.nvim_create_augroup("octo_autocmds", { clear = true })
  end)

  after_each(function()
    octo.save_buffer = original_save_buffer
    octo.invalidate_load = original_invalidate_load
    _G.octo_buffers = original_octo_buffers
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

  it("invalidates loads when an Octo buffer unloads or changes its URI", function()
    autocmds.setup()
    local invalidated = {}
    octo.invalidate_load = function(buf)
      invalidated[buf] = (invalidated[buf] or 0) + 1
    end
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, "octo://owner/repo/issue/3")
    invalidated[bufnr] = 0

    vim.api.nvim_exec_autocmds("BufUnload", { buffer = bufnr })
    vim.api.nvim_exec_autocmds("BufFilePost", { buffer = bufnr })

    assert.are.same(2, invalidated[bufnr])
  end)

  it("evicts the global buffer cache entry on BufDelete and BufWipeout", function()
    autocmds.setup()

    -- octo buffers are created listed (see octo.create_buffer), so deleting
    -- one fires both BufDelete and BufWipeout; use the same listedness here
    -- so this test exercises both events, not just BufWipeout.
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, "octo://owner/repo/issue/2")
    _G.octo_buffers = _G.octo_buffers or {}
    _G.octo_buffers[bufnr] = { bufnr = bufnr }

    vim.api.nvim_buf_delete(bufnr, { force = true })

    assert.is_nil(_G.octo_buffers[bufnr])
    bufnr = nil
  end)
end)
