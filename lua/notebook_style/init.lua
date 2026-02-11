local M = {}

local config = require('notebook_style.config')
local cells = require('notebook_style.cells')
local render = require('notebook_style.render')

-- State management
M.enabled_buffers = {}
M.manual_render_visible = {}  -- Track if manual rendering is currently visible
M._saved_virtualedit = {}  -- Track original virtualedit per window

--- Enable virtualedit for a window, saving the original value
--- @param winid number Window ID
local function enable_virtualedit(winid)
  if not M._saved_virtualedit[winid] then
    M._saved_virtualedit[winid] = vim.api.nvim_get_option_value('virtualedit', { win = winid })
  end
  vim.api.nvim_set_option_value('virtualedit', 'all', { win = winid })
end

--- Restore virtualedit for a window
--- @param winid number Window ID
local function restore_virtualedit(winid)
  local saved = M._saved_virtualedit[winid]
  if saved then
    vim.api.nvim_set_option_value('virtualedit', saved, { win = winid })
    M._saved_virtualedit[winid] = nil
  end
end

--- Nudge cursor off the left border on empty lines inside cells
--- @param bufnr number Buffer number
local function adjust_cursor_on_empty_line(bufnr)
  if not M.enabled_buffers[bufnr] then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row0 = cursor[1] - 1
  local col = cursor[2]
  if col > 0 then
    return
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1] or ''
  if #line == 0 then
    vim.api.nvim_win_set_cursor(win, { cursor[1], 1 })
  end
end

--- Update cell rendering for a buffer
--- @param bufnr number Buffer number
local function update_cells(bufnr)
  if not M.enabled_buffers[bufnr] then
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

  -- Enable virtualedit so the cursor can sit after the inline border on empty lines
  local winid = vim.api.nvim_get_current_win()
  enable_virtualedit(winid)

  -- Set up autocommands for this buffer
  local group = vim.api.nvim_create_augroup('NotebookStyle_' .. bufnr, { clear = true })

  -- Nudge cursor past the left border on empty lines
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    buffer = bufnr,
    callback = function()
      adjust_cursor_on_empty_line(bufnr)
    end,
  })

  -- Ensure virtualedit is set when entering a window showing this buffer
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    buffer = bufnr,
    callback = function()
      enable_virtualedit(vim.api.nvim_get_current_win())
      update_cells(bufnr)
    end,
  })

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

    -- Update when window is resized
    vim.api.nvim_create_autocmd('VimResized', {
      group = group,
      buffer = bufnr,
      callback = function()
        update_cells(bufnr)
      end,
    })
  end

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

  -- Restore virtualedit for all windows showing this buffer
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      restore_virtualedit(winid)
    end
  end

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
