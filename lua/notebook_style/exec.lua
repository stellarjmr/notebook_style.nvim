local cells = require('notebook_style.cells')
local config = require('notebook_style.config')
local image = require('notebook_style.image')
local rpc = require('notebook_style.rpc')
local state = require('notebook_style.state')

local M = {}

local client = nil
local session_to_buf = {}
local refresh = function() end
local image_inner_width

function M.set_refresh(fn)
  refresh = fn or refresh
end

local function plugin_root()
  local source = debug.getinfo(1, 'S').source:sub(2)
  return vim.fn.fnamemodify(source, ':p:h:h:h')
end

local function default_backend_cmd()
  local root = plugin_root()
  local candidates = {
    root .. '/core/target/release/notebook-style-core',
    root .. '/core/target/debug/notebook-style-core',
  }

  for _, candidate in ipairs(candidates) do
    if vim.fn.executable(candidate) == 1 then
      return { candidate }
    end
  end

  return { root .. '/core/target/release/notebook-style-core' }
end

local function compact_message(value)
  return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' '):sub(1, 200)
end

local function find_local_venv_python(start_dir)
  if type(start_dir) ~= 'string' or start_dir == '' then
    return nil
  end

  local dir = vim.fn.fnamemodify(start_dir, ':p'):gsub('/+$', '')
  if dir == '' then
    dir = '/'
  end
  local rel_python = package.config:sub(1, 1) == '\\' and '.venv/Scripts/python.exe' or '.venv/bin/python'

  while dir ~= '' do
    local venv_dir = dir .. '/.venv'
    if vim.fn.isdirectory(venv_dir) == 1 then
      local python_path = dir .. '/' .. rel_python
      if vim.fn.executable(python_path) ~= 1 then
        return nil, '.venv found at ' .. venv_dir .. ', but its Python is not executable'
      end

      local output = vim.fn.system({ python_path, '-c', 'import ipykernel' })
      if vim.v.shell_error == 0 then
        return python_path
      end

      local detail = compact_message(output)
      if detail ~= '' then
        detail = ': ' .. detail
      end
      return nil, python_path .. ' cannot import ipykernel' .. detail
    end

    local parent = vim.fn.fnamemodify(dir, ':h')
    if parent == dir or parent == '' then
      break
    end
    dir = parent:gsub('/+$', '')
    if dir == '' then
      dir = '/'
    end
  end

  return nil
end

local function ensure_client()
  if client and client.job then
    return client
  end

  local cmd = config.options.backend_cmd or default_backend_cmd()
  client = rpc.spawn({
    cmd = cmd,
    on_exit = function()
      client = nil
    end,
  })

  client:on('cell_event', function(args)
    local payload = args[1] or args
    if not payload or not payload.session_id then
      return
    end
    local bufnr = session_to_buf[payload.session_id]
    if not bufnr then
      return
    end
    local output = state.apply_event(bufnr, payload.cell_id, payload.event or {})
    if output and output.data and output.data['image/png'] then
      image.ensure_transmitted(output, client, image_inner_width(bufnr), function()
        refresh(bufnr)
      end)
    end
    refresh(bufnr)
  end)

  return client
end

local function output_inner_width(winid)
  if not winid or winid <= 0 or not vim.api.nvim_win_is_valid(winid) then
    return nil
  end

  local info = vim.fn.getwininfo(winid)[1]
  local text_offset = info and info.textoff or 0
  local frame_width = math.max(vim.api.nvim_win_get_width(winid) - text_offset, 2)
  return math.max(frame_width - 2, 1)
end

image_inner_width = function(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  return output_inner_width(winid) or 80
end

local function current_cells(bufnr)
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local delimiters = cells.find_delimiters(bufnr, config.options.cell_delimiter)
  return cells.get_cells(bufnr, delimiters, total_lines)
end

local function current_cell_with_index(bufnr)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cell_list = current_cells(bufnr)
  for index, cell in ipairs(cell_list) do
    if cursor_line >= cell.start_line and cursor_line <= cell.end_line then
      return cell, index, cell_list
    end
  end
  return nil, nil, cell_list
end

local function current_cell(bufnr)
  local cell = current_cell_with_index(bufnr)
  return cell
end

local function cell_source(bufnr, cell)
  if not cells.is_valid_cell(cell) then
    return ''
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, cell.start_line + 1, cell.end_line + 1, false)
  return table.concat(lines, '\n')
end

local function move_to_cell(bufnr, cell)
  if not cell then
    return false
  end

  local winid = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(winid) ~= bufnr then
    winid = vim.fn.bufwinid(bufnr)
  end
  if not winid or winid <= 0 then
    return false
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local target = cell.end_line > cell.start_line and (cell.start_line + 1) or cell.start_line
  target = math.max(0, math.min(target, line_count - 1))
  vim.api.nvim_win_set_cursor(winid, { target + 1, 0 })
  return true
end

local function execute_cell(bufnr, cell, callback)
  local buffer_state = state.get(bufnr)
  local cell_id = state.cell_id(bufnr, cell)
  local source = cell_source(bufnr, cell)

  ensure_client():call('update_cell_source', {
    session_id = buffer_state.session_id,
    cell_id = cell_id,
    source = source,
  }, function(err)
    if err then
      vim.notify('NotebookStyle update_cell_source failed: ' .. tostring(err), vim.log.levels.ERROR)
      if callback then callback(err) end
      return
    end

    ensure_client():call('execute', {
      session_id = buffer_state.session_id,
      cell_id = cell_id,
    }, function(exec_err)
      if exec_err then
        vim.notify('NotebookStyle execute failed: ' .. tostring(exec_err), vim.log.levels.ERROR)
      end
      if callback then callback(exec_err) end
    end)
  end)
end

function M.start_kernel(bufnr, callback)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buffer_state = state.get(bufnr)

  if buffer_state.kernel_started and buffer_state.session_id then
    if callback then
      callback()
    end
    return
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local cwd = path ~= '' and vim.fn.fnamemodify(path, ':p:h') or vim.loop.cwd()
  local cl = ensure_client()
  local python_path, auto_venv_warning
  if config.options.auto_venv ~= false then
    python_path, auto_venv_warning = find_local_venv_python(cwd)
    if auto_venv_warning then
      vim.notify('NotebookStyle auto_venv skipped: ' .. auto_venv_warning, vim.log.levels.WARN)
    end
  end

  local function start_session(session_id)
    cl:call('start_kernel', {
      session_id = session_id,
      kernel_name = config.options.kernel_name,
      python_path = python_path,
      cwd = cwd,
    }, function(start_err, start_result)
      if start_err then
        vim.notify('NotebookStyle start_kernel failed: ' .. tostring(start_err), vim.log.levels.ERROR)
        return
      end

      buffer_state.kernel_started = true
      local kernel_name = start_result and start_result.kernel_name or config.options.kernel_name
      vim.notify("NotebookStyle kernel '" .. tostring(kernel_name) .. "' started", vim.log.levels.INFO)

      cl:call('execute_silent', {
        session_id = session_id,
        code = "try:\n    get_ipython().run_line_magic('matplotlib', 'inline')\nexcept Exception:\n    pass\n",
      }, function() end)

      if callback then
        callback()
      end
    end)
  end

  if buffer_state.session_id then
    start_session(buffer_state.session_id)
    return
  end

  cl:call('open_py', { path = path ~= '' and path or (cwd .. '/untitled.py') }, function(err, result)
    if err then
      vim.notify('NotebookStyle open_py failed: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end

    buffer_state.session_id = result.session_id
    session_to_buf[result.session_id] = bufnr

    start_session(result.session_id)
  end)
end

function M.stop_kernel(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buffer_state = state.get(bufnr)
  if not buffer_state.session_id then
    return
  end

  ensure_client():call('stop_kernel', { session_id = buffer_state.session_id }, function()
    buffer_state.kernel_started = false
    vim.notify('NotebookStyle kernel stopped', vim.log.levels.INFO)
    refresh(bufnr)
  end)
end

function M.run_cell(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cell = current_cell(bufnr)
  if not cell then
    vim.notify('NotebookStyle: cursor is not inside a cell', vim.log.levels.WARN)
    return
  end

  local function execute()
    execute_cell(bufnr, cell)
  end

  if config.options.auto_start_kernel then
    M.start_kernel(bufnr, execute)
  else
    execute()
  end
end

function M.run_file(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local runnable = {}
  for _, cell in ipairs(current_cells(bufnr)) do
    if cells.is_valid_cell(cell) then
      table.insert(runnable, cell)
    end
  end

  if #runnable == 0 then
    vim.notify('NotebookStyle: no runnable cells found', vim.log.levels.WARN)
    return
  end

  local function execute_all()
    local index = 1
    local function step()
      local cell = runnable[index]
      if not cell then
        return
      end
      index = index + 1
      execute_cell(bufnr, cell, function(err)
        if not err then
          step()
        end
      end)
    end
    step()
  end

  if config.options.auto_start_kernel then
    M.start_kernel(bufnr, execute_all)
  else
    execute_all()
  end
end

function M.run_cell_and_move(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cell, index, cell_list = current_cell_with_index(bufnr)
  if not cell then
    vim.notify('NotebookStyle: cursor is not inside a cell', vim.log.levels.WARN)
    return
  end

  M.run_cell(bufnr)

  local next_cell = cell_list[index + 1]
  if next_cell then
    move_to_cell(bufnr, next_cell)
  else
    vim.notify('NotebookStyle: no next cell', vim.log.levels.INFO)
  end
end

return M
