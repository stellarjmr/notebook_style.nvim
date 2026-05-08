local cells = require('notebook_style.cells')
local config = require('notebook_style.config')
local image = require('notebook_style.image')
local rpc = require('notebook_style.rpc')
local state = require('notebook_style.state')

local M = {}

local client = nil
local session_to_buf = {}
local refresh = function() end

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
      local winid = vim.fn.bufwinid(bufnr)
      local width = 80
      if winid and winid > 0 then
        width = math.max(vim.api.nvim_win_get_width(winid) - 4, 20)
      end
      image.ensure_transmitted(output, client, width, function()
        refresh(bufnr)
      end)
    end
    refresh(bufnr)
  end)

  return client
end

local function current_cells(bufnr)
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local delimiters = cells.find_delimiters(bufnr, config.options.cell_delimiter)
  return cells.get_cells(bufnr, delimiters, total_lines)
end

local function current_cell(bufnr)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  return cells.cell_at_line(current_cells(bufnr), cursor_line)
end

local function cell_source(bufnr, cell)
  if not cells.is_valid_cell(cell) then
    return ''
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, cell.start_line + 1, cell.end_line + 1, false)
  return table.concat(lines, '\n')
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

  local function start_session(session_id)
    cl:call('start_kernel', {
      session_id = session_id,
      kernel_name = config.options.kernel_name,
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
        return
      end

      ensure_client():call('execute', {
        session_id = buffer_state.session_id,
        cell_id = cell_id,
      }, function(exec_err)
        if exec_err then
          vim.notify('NotebookStyle execute failed: ' .. tostring(exec_err), vim.log.levels.ERROR)
        end
      end)
    end)
  end

  if config.options.auto_start_kernel then
    M.start_kernel(bufnr, execute)
  else
    execute()
  end
end

return M
