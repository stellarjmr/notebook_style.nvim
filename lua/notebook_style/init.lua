local M = {}

local config = require('notebook_style.config')
local cells = require('notebook_style.cells')
local render = require('notebook_style.render')
local exec = require('notebook_style.exec')
local install = require('notebook_style.install')
local output_view = require('notebook_style.output_view')
local state = require('notebook_style.state')

-- State management
M.enabled_buffers = {}
M.render_visible = {}  -- Track if rendering is currently visible per buffer
M.pending_updates = {}
M.active_keymaps = {}  -- Track buffer-local keymaps per buffer

local function clear_keymaps(bufnr)
  local function clear_buffer_keymaps(target_bufnr)
    local keymaps = M.active_keymaps[target_bufnr]
    if not keymaps then
      return
    end

    if vim.api.nvim_buf_is_valid(target_bufnr) then
      for _, lhs in pairs(keymaps) do
        pcall(vim.keymap.del, 'n', lhs, { buffer = target_bufnr })
      end
    end

    M.active_keymaps[target_bufnr] = nil
  end

  if bufnr then
    clear_buffer_keymaps(bufnr)
    return
  end

  for active_bufnr, _ in pairs(M.active_keymaps) do
    clear_buffer_keymaps(active_bufnr)
  end
end

local function set_keymap(bufnr, name, rhs, desc)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local keymaps = config.options.keymaps
  if keymaps == false then
    return
  end

  local lhs = keymaps and keymaps[name]
  if lhs == nil or lhs == false or lhs == '' then
    return
  end

  vim.keymap.set('n', lhs, rhs, { buffer = bufnr, desc = desc, silent = true })
  M.active_keymaps[bufnr] = M.active_keymaps[bufnr] or {}
  M.active_keymaps[bufnr][name] = lhs
end

local function set_keymaps(bufnr)
  clear_keymaps(bufnr)

  set_keymap(bufnr, 'toggle_render', function()
    M.toggle_render(bufnr)
  end, 'Toggle notebook cell rendering')

  set_keymap(bufnr, 'run_cell', function()
    exec.run_cell(bufnr)
  end, 'Run notebook cell')

  set_keymap(bufnr, 'run_file', function()
    exec.run_file(bufnr)
  end, 'Run notebook file')

  set_keymap(bufnr, 'run_cell_and_move', function()
    exec.run_cell_and_move(bufnr)
  end, 'Run notebook cell and move to next')

  set_keymap(bufnr, 'open_output', function()
    M.open_output(bufnr)
  end, 'Open notebook cell output')

  set_keymap(bufnr, 'interrupt_kernel', function()
    exec.interrupt_kernel(bufnr)
  end, 'Interrupt notebook kernel')

  set_keymap(bufnr, 'restart_kernel', function()
    exec.restart_kernel(bufnr)
  end, 'Restart notebook kernel')
end

--- Resolve a usable window for a buffer
--- @param bufnr number Buffer number
--- @param winid number|nil Preferred window id
--- @return number|nil Window id
local function resolve_winid(bufnr, winid)
  if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
    return winid
  end

  local wins = vim.fn.win_findbuf(bufnr)
  return wins and wins[1] or nil
end

--- Update cell rendering for a buffer
--- @param bufnr number Buffer number
--- @param winid number|nil Window id
local function update_cells(bufnr, winid)
  if not M.enabled_buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  winid = resolve_winid(bufnr, winid)
  if not winid then
    return
  end

  -- Rendering can be hidden independently of whether the plugin is enabled.
  if not M.render_visible[bufnr] then
    render.clear(bufnr)
    return
  end

  -- Set window-local conceal options for proper delimiter hiding
  -- These are window-local, so we set them each time. breakindent keeps the
  -- repeated left border from covering text on wrapped continuation lines.
  vim.api.nvim_set_option_value('conceallevel', 2, { scope = 'local', win = winid })
  vim.api.nvim_set_option_value('concealcursor', 'nc', { scope = 'local', win = winid })
  vim.api.nvim_set_option_value('breakindent', true, { scope = 'local', win = winid })
  vim.api.nvim_set_option_value('breakindentopt', 'min:1', { scope = 'local', win = winid })

  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local delimiters = cells.find_delimiters(bufnr, config.options.cell_delimiter)
  local cell_list = cells.get_cells(bufnr, delimiters, total_lines)

  -- Get current mode
  local mode = vim.api.nvim_get_mode().mode

  render.render_all(bufnr, cell_list, mode, winid)
end

--- Schedule a coalesced rendering update for a buffer
--- @param bufnr number Buffer number
--- @param winid number|nil Window id
local function request_update(bufnr, winid)
  if not M.enabled_buffers[bufnr] or M.pending_updates[bufnr] then
    return
  end

  M.pending_updates[bufnr] = true

  vim.schedule(function()
    M.pending_updates[bufnr] = nil
    update_cells(bufnr, winid)
  end)
end

--- Enable the plugin for a buffer
--- @param bufnr number Buffer number
function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if M.enabled_buffers[bufnr] then
    return
  end

  M.enabled_buffers[bufnr] = true
  M.render_visible[bufnr] = not config.options.manual_render
  set_keymaps(bufnr)

  -- Set up autocommands for this buffer
  local group = vim.api.nvim_create_augroup('NotebookStyle_' .. bufnr, { clear = true })

  -- Always handle mode changes to show/hide borders appropriately
  vim.api.nvim_create_autocmd('ModeChanged', {
    group = group,
    buffer = bufnr,
    callback = function()
      request_update(bufnr, vim.api.nvim_get_current_win())
    end,
  })

  -- Only set up auto-update autocommands if manual_render is disabled
  if not config.options.manual_render then
    -- Update on text changes
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
      group = group,
      buffer = bufnr,
      callback = function()
        request_update(bufnr, vim.api.nvim_get_current_win())
      end,
    })

    -- Update when entering the buffer
    vim.api.nvim_create_autocmd('BufEnter', {
      group = group,
      buffer = bufnr,
      callback = function()
        request_update(bufnr, vim.api.nvim_get_current_win())
      end,
    })

    -- Update when window is resized
    vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
      group = group,
      buffer = bufnr,
      callback = function()
        request_update(bufnr, vim.api.nvim_get_current_win())
      end,
    })
  end

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
    request_update(bufnr, vim.api.nvim_get_current_win())
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
  M.render_visible[bufnr] = nil
  M.pending_updates[bufnr] = nil
  clear_keymaps(bufnr)
  output_view.close(bufnr)
  state.clear(bufnr)
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

--- Show and render cells for the current buffer
--- @param bufnr number Buffer number
function M.render(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Enable the buffer if not already enabled
  if not M.enabled_buffers[bufnr] then
    M.enable(bufnr)
  end

  -- Mark as visible and render cells
  M.render_visible[bufnr] = true
  request_update(bufnr, vim.api.nvim_get_current_win())
end

--- Toggle rendering visibility for the current buffer
--- @param bufnr number Buffer number
function M.toggle_render(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Enable the buffer if not already enabled
  if not M.enabled_buffers[bufnr] then
    M.enable(bufnr)
    if M.render_visible[bufnr] then
      request_update(bufnr, vim.api.nvim_get_current_win())
      return
    end
  end

  -- Toggle visibility state
  M.render_visible[bufnr] = not M.render_visible[bufnr]

  if M.render_visible[bufnr] then
    -- Show rendering
    request_update(bufnr, vim.api.nvim_get_current_win())
  else
    -- Hide rendering
    render.clear(bufnr)
  end
end

--- Open the current cell output in a navigable floating scratch buffer
--- @param bufnr number Buffer number
function M.open_output(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return output_view.open(bufnr)
end

--- Setup the plugin
--- @param opts table Configuration options
function M.setup(opts)
  config.setup(opts)
  exec.set_refresh(function(bufnr, refresh_opts)
    if config.options.manual_render and not (refresh_opts and refresh_opts.preserve_visibility) then
      M.render_visible[bufnr] = true
    end
    request_update(bufnr, vim.fn.bufwinid(bufnr))
  end)

  local setup_group = vim.api.nvim_create_augroup('NotebookStyle', { clear = true })

  -- Auto-enable for configured filetypes
  vim.api.nvim_create_autocmd('FileType', {
    group = setup_group,
    pattern = config.options.filetypes,
    callback = function(args)
      M.enable(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd('ColorScheme', {
    group = setup_group,
    callback = function()
      config.apply_highlights()
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

  vim.api.nvim_create_user_command('NotebookStyleRunCell', function()
    exec.run_cell(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command('NotebookStyleOpenOutput', function()
    M.open_output(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command('NotebookStyleClearOutput', function()
    exec.clear_cell_output(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command('NotebookStyleClearCellOutput', function()
    exec.clear_cell_output(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command('NotebookStyleClearAllOutputs', function()
    exec.clear_outputs(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command('NotebookStyleRunFile', function()
    exec.run_file(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command('NotebookStyleRunCellAndMove', function()
    exec.run_cell_and_move(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command('NotebookStyleKernelStart', function()
    exec.start_kernel(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command('NotebookStyleKernelStop', function()
    exec.stop_kernel(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command('NotebookStyleKernelInterrupt', function()
    exec.interrupt_kernel(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command('NotebookStyleKernelRestart', function()
    exec.restart_kernel(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command('NotebookStyleSelectKernel', function()
    exec.select_kernel(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command('NotebookStyleDownloadBackend', function()
    install.run()
  end, {})

  clear_keymaps()
  for bufnr, enabled in pairs(M.enabled_buffers) do
    if enabled and vim.api.nvim_buf_is_valid(bufnr) then
      set_keymaps(bufnr)
    else
      M.enabled_buffers[bufnr] = nil
      M.render_visible[bufnr] = nil
      M.pending_updates[bufnr] = nil
      M.active_keymaps[bufnr] = nil
    end
  end
end

return M
