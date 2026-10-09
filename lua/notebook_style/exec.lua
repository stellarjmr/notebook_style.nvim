local cells = require('notebook_style.cells')
local config = require('notebook_style.config')
local image = require('notebook_style.image')
local output_view = require('notebook_style.output_view')
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

--- What happens after the kernel is gone: with auto_start_kernel (the
--- default) the next run starts a new one, otherwise the user does.
local function next_run_hint()
  if config.options.auto_start_kernel then
    return 'the next run starts a new kernel'
  end
  return 'start a new one with :NotebookStyleKernelStart'
end

--- Forget every session of a backend that exited. Its kernels are gone (or at
--- least unreachable), so buffers start a new session on their next run
--- instead of sending requests for session ids the next backend never issued.
local function on_backend_exit(exited_client, code, signal)
  if client == exited_client then
    client = nil
  end

  local affected = {}
  for session_id, bufnr in pairs(session_to_buf) do
    session_to_buf[session_id] = nil
    affected[bufnr] = true
  end
  -- A start still waiting for open_py has no session yet.
  for bufnr, buffer_state in state.each() do
    if buffer_state.starting and buffer_state.starting.client == exited_client then
      affected[bufnr] = true
    end
  end
  for bufnr in pairs(affected) do
    state.reset_kernel(bufnr)
    refresh(bufnr, { preserve_visibility = true })
  end

  vim.notify(
    string.format(
      'NotebookStyle: the execution backend exited (code=%s, signal=%s); %s',
      tostring(code),
      tostring(signal),
      next_run_hint()
    ),
    vim.log.levels.WARN
  )
end

--- The kernel process exited by itself (a crash, an out-of-memory kill,
--- `os._exit`): cells it was running will never finish. The backend has
--- dropped it, so mark it stopped (the next run starts a new kernel in the
--- same session) and drop the runs that were waiting for it.
local function on_kernel_exit(bufnr, payload)
  local buffer_state = state.get(bufnr)
  buffer_state.kernel_started = false
  buffer_state.run_queue = nil
  state.clear_statuses(bufnr)
  refresh(bufnr, { preserve_visibility = true })
  vim.notify(
    string.format(
      'NotebookStyle: the kernel exited (%s); %s%s',
      tostring(payload.status),
      next_run_hint(),
      payload.stderr or ''
    ),
    vim.log.levels.WARN
  )
end

--- Report a failed backend request, except when the backend itself is gone:
--- on_backend_exit reports that once for every request in flight.
local function notify_failure(message, err)
  if rpc.is_backend_gone(err) then
    return
  end
  vim.notify(message .. tostring(err), vim.log.levels.ERROR)
end

local function ensure_client()
  if client and client.job then
    return client
  end

  local cmd = config.options.backend_cmd or default_backend_cmd()
  local spawned
  spawned = rpc.spawn({
    cmd = cmd,
    on_exit = function(code, signal)
      on_backend_exit(spawned, code, signal)
    end,
  })
  client = spawned

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

  client:on('kernel_exited', function(args)
    local payload = args[1] or args
    local bufnr = payload and payload.session_id and session_to_buf[payload.session_id]
    if bufnr then
      on_kernel_exit(bufnr, payload)
    end
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
  local cell_list = cells.get_cells(bufnr, delimiters, total_lines)
  state.sync_cells(bufnr, cell_list)
  return cell_list
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
  local start_line = cell.implicit and 0 or cell.start_line + 1
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, cell.end_line + 1, false)
  local source = table.concat(lines, '\n')
  if cell.implicit then
    local path = vim.api.nvim_buf_get_name(bufnr)
    -- Script compilation suppresses implicit expression results, but keeps
    -- stdout, display_data and matplotlib's normal post-execution hook.
    return string.format(
      'exec(compile(%s, %s, "exec"), globals())',
      vim.fn.json_encode(source),
      vim.fn.json_encode(path ~= '' and path or '<notebook_style>')
    )
  end
  return source
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

--- ensure_client(), dropping the buffer's queued runs if the backend cannot
--- be spawned: otherwise they would all run much later, once one exists.
local function client_for(buffer_state)
  local ok, cl = pcall(ensure_client)
  if not ok then
    buffer_state.run_queue = nil
    error(cl, 0)
  end
  return cl
end

--- Queue a cell for execution. Its identity and source are captured now,
--- because the buffer may change before the kernel is ready.
local function enqueue_run(bufnr, cell)
  local buffer_state = state.get(bufnr)
  buffer_state.run_queue = buffer_state.run_queue or {}
  table.insert(buffer_state.run_queue, {
    cell_id = state.cell_id(bufnr, cell),
    source = cell_source(bufnr, cell),
  })
end

--- Send the buffer's queued runs to the kernel one at a time, in the order
--- they were issued. The backend handles every request on its own task, so
--- requests in flight together can reach the kernel in any order; the
--- `execute` reply arrives once the request is queued for the kernel, so the
--- next run is sent only after it. A buffer has at most one run in flight,
--- even after its queue was dropped. Nothing is sent while a kernel start or
--- stop is in flight; finishing it pumps again.
local function pump(bufnr)
  local buffer_state = state.get(bufnr)
  local queue = buffer_state.run_queue
  if not queue or #queue == 0 or buffer_state.in_flight or buffer_state.starting then
    return
  end

  local cl = client_for(buffer_state)
  local run = table.remove(queue, 1)
  local flight = { waiters = {} }
  buffer_state.in_flight = flight

  -- Dropped meanwhile: kernel stopped, buffer reset or shut down, or the
  -- backend exited (on_backend_exit has told the user).
  local function discarded()
    return buffer_state.run_queue ~= queue or cl ~= client
  end

  local function done(err)
    if buffer_state.in_flight == flight then
      buffer_state.in_flight = nil
    end
    if err and not discarded() then
      -- The remaining runs would fail the same way; report it only once.
      buffer_state.run_queue = nil
    end
    for _, waiter in ipairs(flight.waiters) do
      waiter()
    end
    if buffer_state.run_queue then
      pump(bufnr)
    end
  end

  cl:call('update_cell_source', {
    session_id = buffer_state.session_id,
    cell_id = run.cell_id,
    source = run.source,
  }, function(err)
    if discarded() then
      done()
      return
    end
    if err then
      notify_failure('NotebookStyle update_cell_source failed: ', err)
      done(err)
      return
    end

    cl:call('execute', {
      session_id = buffer_state.session_id,
      cell_id = run.cell_id,
    }, function(exec_err)
      if exec_err and not discarded() then
        notify_failure('NotebookStyle execute failed: ', exec_err)
      end
      done(exec_err)
    end)
  end)
end

--- Call `fn` once the buffer's run in flight, if any, has finished: a kernel
--- stop sent earlier could overtake that run's `execute` in the backend.
local function after_run_in_flight(buffer_state, fn)
  if buffer_state.in_flight then
    table.insert(buffer_state.in_flight.waiters, fn)
  else
    fn()
  end
end

local function run_callbacks(callbacks)
  for _, callback in ipairs(callbacks) do
    callback()
  end
end

local function clear_output_images(outputs)
  for _, output in ipairs(outputs or {}) do
    image.clear(output, client)
  end
end

-- Release transmitted images when a cell's identity is garbage-collected
-- after its delimiter was deleted.
state.set_on_outputs_dropped(clear_output_images)

local function clear_output_map_images(outputs_by_cell)
  for _, outputs in pairs(outputs_by_cell or {}) do
    clear_output_images(outputs)
  end
end

local function sync_clear_with_backend(method, params)
  if not client or not client.job then
    return
  end

  client:call(method, params, function(err)
    if err then
      notify_failure('NotebookStyle ' .. method .. ' failed: ', err)
    end
  end)
end

local function kernel_label(spec)
  local label = spec.display_name or spec.name or 'unknown kernel'
  if spec.name and spec.name ~= label then
    label = label .. ' (' .. spec.name .. ')'
  end
  if spec.language and spec.language ~= '' then
    label = label .. ' [' .. spec.language .. ']'
  end
  return label
end

function M.list_kernels(callback)
  -- No check for a backend that exited meanwhile: the list comes from the
  -- kernelspecs on disk, so a late reply is still a correct answer to the
  -- user's request. A kernel picked from it applies to the buffer's current
  -- session, like any selection.
  ensure_client():call('list_kernels', {}, function(err, result)
    if err then
      notify_failure('NotebookStyle list_kernels failed: ', err)
      if callback then callback(err) end
      return
    end

    if callback then
      callback(nil, result or {})
    end
  end)
end

function M.select_kernel(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  M.list_kernels(function(err, kernels)
    if err then
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if type(kernels) ~= 'table' or #kernels == 0 then
      vim.notify('NotebookStyle: no Jupyter kernels found', vim.log.levels.WARN)
      return
    end

    vim.ui.select(kernels, {
      prompt = 'Select NotebookStyle kernel:',
      format_item = kernel_label,
    }, function(choice)
      if not choice then
        return
      end
      if not choice.name or choice.name == '' then
        vim.notify('NotebookStyle: selected kernel has no name', vim.log.levels.ERROR)
        return
      end

      state.set_kernel_name(bufnr, choice.name)
      vim.notify('NotebookStyle kernel selected: ' .. kernel_label(choice), vim.log.levels.INFO)

      local buffer_state = state.get(bufnr)
      if buffer_state.kernel_started then
        M.restart_kernel(bufnr)
      end
    end)
  end)
end

--- Ask the backend to drop a session and kill its kernel. Errors are ignored:
--- the session is being discarded either way.
local function close_session(cl, session_id)
  if session_id then
    cl:call('close', { session_id = session_id }, function() end)
  end
end

--- Complete the buffer's in-flight kernel start: on success run the callbacks
--- that waited for it and send the queued runs; on failure drop them.
local function finish_start(bufnr, buffer_state, start, ok)
  if buffer_state.starting ~= start then
    return -- superseded: the backend exited and the buffer was reset
  end
  buffer_state.starting = nil
  if not ok then
    buffer_state.run_queue = nil
    return
  end
  run_callbacks(start.callbacks)
  pump(bufnr)
end

--- Start the buffer's kernel, then call `callback`. While a start is in
--- flight, later calls wait for it instead of opening another session and
--- kernel for the same buffer; while a kernel stops, they wait for the stop
--- and then start a kernel.
function M.start_kernel(bufnr, callback, quiet)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buffer_state = state.get(bufnr)

  if buffer_state.starting then
    -- Recorded even without a callback: a kernel stop in flight then starts
    -- a kernel once it is done.
    table.insert(buffer_state.starting.callbacks, callback or function() end)
    return
  end

  if buffer_state.kernel_started and buffer_state.session_id then
    if callback then
      callback()
    end
    return
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local cwd = path ~= '' and vim.fn.fnamemodify(path, ':p:h') or vim.loop.cwd()
  local cl = client_for(buffer_state)
  local python_path, auto_venv_warning
  local kernel_name = state.kernel_name(bufnr) or config.options.kernel_name
  if not state.kernel_name(bufnr) and config.options.auto_venv ~= false then
    python_path, auto_venv_warning = find_local_venv_python(cwd)
    if auto_venv_warning then
      vim.notify('NotebookStyle auto_venv skipped: ' .. auto_venv_warning, vim.log.levels.WARN)
    end
  end

  local start = { callbacks = {}, client = cl }
  if callback then
    table.insert(start.callbacks, callback)
  end
  buffer_state.starting = start

  local function start_session(session_id)
    start.launching = true
    cl:call('start_kernel', {
      session_id = session_id,
      kernel_name = kernel_name,
      python_path = python_path,
      cwd = cwd,
    }, function(start_err, start_result)
      start.launching = false
      if cl ~= client then
        -- The backend exited meanwhile: end this start quietly so the buffer
        -- does not wait for it (a no-op if the exit already reset the buffer).
        finish_start(bufnr, buffer_state, start, false)
        return
      end
      if buffer_state.starting ~= start then
        -- The buffer was shut down meanwhile; nobody can reach this session any
        -- more, so release it and its kernel.
        close_session(cl, session_id)
        return
      end
      if start_err then
        notify_failure('NotebookStyle start_kernel failed: ', start_err)
        finish_start(bufnr, buffer_state, start, false)
        return
      end

      buffer_state.kernel_started = true
      local started_kernel_name = start_result and start_result.kernel_name or kernel_name
      if not quiet then
        vim.notify("NotebookStyle kernel '" .. tostring(started_kernel_name) .. "' started", vim.log.levels.INFO)
      end

      -- Hold queued runs until this setup code has reached the kernel. A
      -- failure of the setup itself is ignored, but not a backend that is
      -- gone: then no kernel serves the waiting callers and runs.
      cl:call('execute_silent', {
        session_id = session_id,
        code = "try:\n    get_ipython().run_line_magic('matplotlib', 'inline')\nexcept Exception:\n    pass\n",
      }, function(err)
        finish_start(bufnr, buffer_state, start, cl == client and not rpc.is_backend_gone(err))
      end)
    end)
  end

  if buffer_state.session_id then
    start_session(buffer_state.session_id)
    return
  end

  cl:call('open_py', { path = path ~= '' and path or (cwd .. '/untitled.py') }, function(err, result)
    if cl ~= client then
      -- The backend exited meanwhile: end this start quietly (a no-op once
      -- the exit reset the buffer, which also covers starts without session).
      finish_start(bufnr, buffer_state, start, false)
      return
    end
    if buffer_state.starting ~= start then
      -- The buffer was shut down meanwhile: release the session it got, and
      -- do not report a failure nobody is waiting for.
      if not err then
        close_session(cl, result.session_id)
      end
      return
    end
    if err then
      notify_failure('NotebookStyle open_py failed: ', err)
      finish_start(bufnr, buffer_state, start, false)
      return
    end

    buffer_state.session_id = result.session_id
    session_to_buf[result.session_id] = bufnr

    start_session(result.session_id)
  end)
end

--- Release the buffer's backend session and kernel before its state is
--- discarded (buffer deleted, or the plugin disabled for it): nothing could
--- reach that kernel afterwards.
function M.shutdown(bufnr)
  local buffer_state = state.get(bufnr)
  local session_id = buffer_state.session_id
  local start = buffer_state.starting
  buffer_state.starting = nil
  buffer_state.run_queue = nil
  buffer_state.session_id = nil
  buffer_state.kernel_started = false
  if not session_id then
    return -- an open_py in flight closes its session when it completes
  end

  session_to_buf[session_id] = nil
  -- A kernel launch in flight closes the session when it completes; closing
  -- now could let the launch install its kernel into the dropped session.
  if not (start and start.launching) and client and client.job then
    close_session(client, session_id)
  end
end

function M.clear_cell_output(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cell = current_cell(bufnr)
  if not cell then
    vim.notify('NotebookStyle: cursor is not inside a cell', vim.log.levels.WARN)
    return
  end

  local buffer_state = state.get(bufnr)
  local outputs, cell_id = state.clear_cell_output(bufnr, cell)
  clear_output_images(outputs)
  output_view.close(bufnr)

  if buffer_state.session_id then
    sync_clear_with_backend('clear_cell_output', {
      session_id = buffer_state.session_id,
      cell_id = cell_id,
    })
  end

  refresh(bufnr, { preserve_visibility = true })
end

function M.clear_outputs(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buffer_state = state.get(bufnr)
  local outputs_by_cell = state.clear_outputs(bufnr)
  clear_output_map_images(outputs_by_cell)
  output_view.close(bufnr)

  if buffer_state.session_id then
    sync_clear_with_backend('clear_outputs', {
      session_id = buffer_state.session_id,
    })
  end

  refresh(bufnr, { preserve_visibility = true })
end

--- Stop the buffer's kernel once its run in flight, if any, has finished.
--- Until the stop completes, runs and start_kernel callers wait as during a
--- start; `after_stop(callbacks)` then gets the waiting callers. If the stop
--- fails, the kernel keeps running and serves them. `kind` is 'stop' or
--- 'restart'.
local function stop_held(bufnr, buffer_state, kind, failure_message, after_stop)
  local session_id = buffer_state.session_id
  local cl = ensure_client()
  local hold = { callbacks = {}, client = cl, kind = kind }
  buffer_state.starting = hold

  after_run_in_flight(buffer_state, function()
    if buffer_state.starting ~= hold then
      return -- reset or shut down meanwhile
    end
    cl:call('stop_kernel', { session_id = session_id }, function(err)
      if buffer_state.starting ~= hold then
        return
      end
      buffer_state.starting = nil
      if cl ~= client then
        buffer_state.run_queue = nil
        return
      end
      if err then
        if rpc.is_backend_gone(err) then
          -- No kernel serves the waiting callers: drop them as a failed
          -- start would (on_backend_exit reports the exit).
          buffer_state.run_queue = nil
          return
        end
        notify_failure(failure_message, err)
        run_callbacks(hold.callbacks)
        pump(bufnr)
        return
      end
      buffer_state.kernel_started = false
      state.clear_statuses(bufnr)
      after_stop(hold.callbacks)
    end)
  end)
end

function M.stop_kernel(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buffer_state = state.get(bufnr)
  -- Runs that have not reached the kernel yet are dropped with it.
  buffer_state.run_queue = nil
  local starting = buffer_state.starting
  if starting and starting.kind == 'stop' then
    -- A stop is already in flight: kernel starts requested since then are
    -- dropped too, so the kernel stays stopped.
    starting.callbacks = {}
    return
  end
  if starting then
    -- A start or restart in flight is not cancelled.
    vim.notify('NotebookStyle: the kernel is still starting or restarting, so it was not stopped; queued runs were discarded', vim.log.levels.INFO)
    return
  end
  if not buffer_state.session_id then
    return
  end

  stop_held(bufnr, buffer_state, 'stop', 'NotebookStyle stop_kernel failed: ', function(callbacks)
    vim.notify('NotebookStyle kernel stopped', vim.log.levels.INFO)
    refresh(bufnr)
    if #callbacks > 0 then
      -- Runs or a start were requested while the kernel stopped.
      M.start_kernel(bufnr, function()
        run_callbacks(callbacks)
      end)
    else
      pump(bufnr)
    end
  end)
end

function M.interrupt_kernel(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buffer_state = state.get(bufnr)
  if not buffer_state.session_id or not buffer_state.kernel_started then
    vim.notify('NotebookStyle: no running kernel to interrupt', vim.log.levels.WARN)
    return
  end

  local cl = ensure_client()
  cl:call('interrupt_kernel', { session_id = buffer_state.session_id }, function(err)
    if cl ~= client then
      return
    end
    if err then
      notify_failure('NotebookStyle interrupt_kernel failed: ', err)
      return
    end
    vim.notify('NotebookStyle kernel interrupted', vim.log.levels.INFO)
  end)
end

function M.restart_kernel(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local buffer_state = state.get(bufnr)
  if buffer_state.starting or not buffer_state.session_id or not buffer_state.kernel_started then
    M.start_kernel(bufnr)
    return
  end

  -- Runs issued from now on wait for the new kernel.
  stop_held(bufnr, buffer_state, 'restart', 'NotebookStyle restart failed to stop kernel: ', function(callbacks)
    refresh(bufnr)
    M.start_kernel(bufnr, function()
      run_callbacks(callbacks)
    end)
  end)
end

function M.run_cell(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cell = current_cell(bufnr)
  if not cell then
    vim.notify('NotebookStyle: cursor is not inside a cell', vim.log.levels.WARN)
    return
  end
  if cell.kind == 'markdown' then
    vim.notify('NotebookStyle: markdown cells are not executable', vim.log.levels.INFO)
    return
  end

  enqueue_run(bufnr, cell)
  if config.options.auto_start_kernel then
    M.start_kernel(bufnr, function()
      pump(bufnr)
    end, cell.implicit)
  else
    pump(bufnr)
  end
end

function M.run_file(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local runnable = {}
  for _, cell in ipairs(current_cells(bufnr)) do
    if cell.kind ~= 'markdown' and cells.is_valid_cell(cell) then
      table.insert(runnable, cell)
    end
  end

  if #runnable == 0 then
    vim.notify('NotebookStyle: no runnable cells found', vim.log.levels.WARN)
    return
  end

  for _, cell in ipairs(runnable) do
    enqueue_run(bufnr, cell)
  end
  if config.options.auto_start_kernel then
    M.start_kernel(bufnr, function()
      pump(bufnr)
    end, runnable[1].implicit)
  else
    pump(bufnr)
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

  if cell.implicit then
    return
  end

  local next_cell = cell_list[index + 1]
  if next_cell then
    move_to_cell(bufnr, next_cell)
  else
    vim.notify('NotebookStyle: no next cell', vim.log.levels.INFO)
  end
end

-- Internal helpers shared with health.lua
M._default_backend_cmd = default_backend_cmd
M._find_local_venv_python = find_local_venv_python

return M
