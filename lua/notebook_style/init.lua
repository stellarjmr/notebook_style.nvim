local M = {}

local config = require('notebook_style.config')
local cells = require('notebook_style.cells')
local render = require('notebook_style.render')

-- State management
M.enabled_buffers = {}

--- Update cell rendering for a buffer
--- @param bufnr number Buffer number
local function update_cells(bufnr)
  if not M.enabled_buffers[bufnr] then
    return
  end

  -- Set window-local conceal options for proper delimiter hiding
  -- These are window-local, so we set them each time
  vim.wo.conceallevel = 2
  vim.wo.concealcursor = 'nc'

  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local delimiters = cells.find_delimiters(bufnr, config.options.cell_delimiter)
  local cell_list = cells.get_cells(bufnr, delimiters, total_lines)

  -- Get current mode
  local mode = vim.api.nvim_get_mode().mode

  render.render_all(bufnr, cell_list, mode)
end

--- Enable the plugin for a buffer
--- @param bufnr number Buffer number
function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if M.enabled_buffers[bufnr] then
    return
  end

  M.enabled_buffers[bufnr] = true

  -- Set up autocommands for this buffer
  local group = vim.api.nvim_create_augroup('NotebookStyle_' .. bufnr, { clear = true })

  -- Update on text changes
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
    group = group,
    buffer = bufnr,
    callback = function()
      update_cells(bufnr)
    end,
  })

  -- Update on mode changes
  vim.api.nvim_create_autocmd('ModeChanged', {
    group = group,
    buffer = bufnr,
    callback = function()
      update_cells(bufnr)
    end,
  })

  -- Update when entering the buffer
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    buffer = bufnr,
    callback = function()
      update_cells(bufnr)
    end,
  })

  -- Update when window is resized
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    buffer = bufnr,
    callback = function()
      update_cells(bufnr)
    end,
  })

  -- Clean up on buffer delete
  vim.api.nvim_create_autocmd('BufDelete', {
    group = group,
    buffer = bufnr,
    callback = function()
      M.disable(bufnr)
    end,
  })

  -- Initial render
  update_cells(bufnr)
end

--- Disable the plugin for a buffer
--- @param bufnr number Buffer number
function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not M.enabled_buffers[bufnr] then
    return
  end

  M.enabled_buffers[bufnr] = nil
  render.clear(bufnr)

  -- Clear autocommands
  local ok, _ = pcall(vim.api.nvim_del_augroup_by_name, 'NotebookStyle_' .. bufnr)
  if not ok then
    -- Autogroup doesn't exist, ignore
  end
end

--- Toggle the plugin for a buffer
--- @param bufnr number Buffer number
function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if M.enabled_buffers[bufnr] then
    M.disable(bufnr)
  else
    M.enable(bufnr)
  end
end

--- Setup the plugin
--- @param opts table Configuration options
function M.setup(opts)
  config.setup(opts)

  -- Auto-enable for configured filetypes
  vim.api.nvim_create_autocmd('FileType', {
    pattern = config.options.filetypes,
    callback = function(args)
      M.enable(args.buf)
    end,
  })

  -- Create user commands
  vim.api.nvim_create_user_command('NotebookStyleEnable', function()
    M.enable()
  end, {})

  vim.api.nvim_create_user_command('NotebookStyleDisable', function()
    M.disable()
  end, {})

  vim.api.nvim_create_user_command('NotebookStyleToggle', function()
    M.toggle()
  end, {})
end

return M
