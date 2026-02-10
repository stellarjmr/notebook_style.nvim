local M = {}

local config = require('notebook_style.config')
local cells = require('notebook_style.cells')
local render = require('notebook_style.render')

-- State management
M.enabled_buffers = {}
M.manual_render_visible = {}  -- Track if manual rendering is currently visible

--- Update cell rendering for a buffer
--- @param bufnr number Buffer number
local function update_cells(bufnr)
  if not M.enabled_buffers[bufnr] then
    return
  end

  -- Skip if render module is doing an internal buffer edit (placeholder management)
  if render._internal_edit then
    return
  end

  -- In manual render mode, only render if explicitly visible
  if config.options.manual_render and not M.manual_render_visible[bufnr] then
    render.clear(bufnr)
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

  -- Always handle mode changes to show/hide borders appropriately
  vim.api.nvim_create_autocmd('ModeChanged', {
    group = group,
    buffer = bufnr,
    callback = function()
      update_cells(bufnr)
    end,
  })

  -- Only set up auto-update autocommands if manual_render is disabled
  if not config.options.manual_render then
    -- Update on text changes
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
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
  end

  -- Remove placeholder spaces before writing so the file on disk stays clean
  vim.api.nvim_create_autocmd('BufWritePre', {
    group = group,
    buffer = bufnr,
    callback = function()
      render.clear(bufnr)
    end,
  })

  -- Re-render after writing
  vim.api.nvim_create_autocmd('BufWritePost', {
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

  -- Initial render only if manual_render is disabled
  if not config.options.manual_render then
    update_cells(bufnr)
  end
end

--- Disable the plugin for a buffer
--- @param bufnr number Buffer number
function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not M.enabled_buffers[bufnr] then
    return
  end

  M.enabled_buffers[bufnr] = nil
  M.manual_render_visible[bufnr] = nil
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

--- Manually render cells for the current buffer
--- Useful when manual_render is enabled
--- @param bufnr number Buffer number
function M.render(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Enable the buffer if not already enabled
  if not M.enabled_buffers[bufnr] then
    M.enable(bufnr)
  end

  -- Mark as visible and render cells
  M.manual_render_visible[bufnr] = true
  update_cells(bufnr)
end

--- Toggle manual rendering for the current buffer
--- @param bufnr number Buffer number
function M.toggle_render(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Enable the buffer if not already enabled
  if not M.enabled_buffers[bufnr] then
    M.enable(bufnr)
  end

  -- Toggle visibility state
  M.manual_render_visible[bufnr] = not M.manual_render_visible[bufnr]

  if M.manual_render_visible[bufnr] then
    -- Show rendering
    update_cells(bufnr)
  else
    -- Hide rendering
    render.clear(bufnr)
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

  vim.api.nvim_create_user_command('NotebookStyleRender', function()
    M.render()
  end, {})

  vim.api.nvim_create_user_command('NotebookStyleToggleRender', function()
    M.toggle_render()
  end, {})

  -- Set up keybinding for manual render toggle
  vim.keymap.set('n', '<leader>rs', function()
    M.toggle_render()
  end, { desc = 'Toggle notebook cell rendering', silent = true })
end

return M
