local root = vim.env.NOTEBOOK_STYLE_TEST_ROOT
  or vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

vim.opt.runtimepath:append(root)
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local failures = {}
local passed = 0
local skipped = 0

local function assert_true(value, message)
  if not value then
    error(message or 'expected truthy value', 2)
  end
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'values differ') .. ': expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual), 2)
  end
end

local function skip_now(reason)
  error({ skip = true, reason = reason }, 0)
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print('[PASS] ' .. name)
    return
  end

  if type(err) == 'table' and err.skip then
    skipped = skipped + 1
    print('[SKIP] ' .. name .. ': ' .. tostring(err.reason))
    return
  end

  table.insert(failures, name .. ': ' .. tostring(err))
  print('[FAIL] ' .. name .. ': ' .. tostring(err))
end

local function backend_path()
  return vim.env.NOTEBOOK_STYLE_TEST_BACKEND or (root .. '/core/target/release/notebook-style-core')
end

local function python_imports_ipykernel(python)
  vim.fn.system({ python, '-c', 'import ipykernel' })
  return vim.v.shell_error == 0
end

test('setup registers commands and defaults', function()
  local notebook = require('notebook_style')
  notebook.setup({ keymaps = false })

  local config = require('notebook_style.config')
  assert_eq(config.options.auto_venv, true, 'auto_venv should default to true')
  assert_eq(config.options.output_view.width, 0.85, 'output viewer width should default to 85%')
  assert_eq(config.options.output_view.height, 0.75, 'output viewer height should default to 75%')
  assert_eq(vim.fn.exists(':NotebookStyleRunCell'), 2, 'run command should exist')
  assert_eq(vim.fn.exists(':NotebookStyleOpenOutput'), 2, 'output viewer command should exist')
  assert_eq(vim.fn.exists(':NotebookStyleDownloadBackend'), 2, 'backend installer command should exist')
end)

test('setup registers configurable output viewer keymap', function()
  local notebook = require('notebook_style')
  notebook.setup({
    keymaps = {
      toggle_render = false,
      run_cell = false,
      run_file = false,
      run_cell_and_move = false,
      open_output = '<F12>',
    },
  })

  assert_true(vim.fn.maparg('<F12>', 'n') ~= '', 'open output keymap should be registered')

  pcall(vim.keymap.del, 'n', '<F12>')
end)

test('default delimiter ignores IPython magic comments', function()
  local config = require('notebook_style.config')
  local cells = require('notebook_style.cells')
  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %% First',
    'x = 1',
    '# %%time',
    'print(x)',
    '# %% Second',
    'y = 2',
  })

  local delimiters = cells.find_delimiters(buf, config.options.cell_delimiter)
  assert_eq(#delimiters, 2, 'only real cell delimiters should match')
  assert_eq(delimiters[1], 0)
  assert_eq(delimiters[2], 4)

  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('render creates and clears cell extmarks', function()
  local notebook = require('notebook_style')
  local render = require('notebook_style.render')
  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %% Alpha',
    'a = 1',
    '# %% Beta',
    'b = a + 1',
  })
  vim.api.nvim_set_current_buf(buf)

  notebook.enable(buf)
  notebook.render(buf)
  assert_true(vim.wait(1000, function()
    return #vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, {}) > 0
  end, 20), 'render should create extmarks')

  notebook.toggle_render(buf)
  assert_eq(#vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, {}), 0, 'toggle_render should clear extmarks')

  notebook.disable(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('hidden delimiters render labels in top borders', function()
  local notebook = require('notebook_style')
  local render = require('notebook_style.render')
  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %% Top',
    'value = 1',
    '# %% Second',
    'value = 2',
  })
  vim.api.nvim_set_current_buf(buf)

  local function has_titled_border(line, label)
    local marks = vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })
    for _, mark in ipairs(marks) do
      if mark[2] == line then
        local details = mark[4] or {}
        for _, chunk in ipairs(details.virt_text or {}) do
          local text = chunk[1] or ''
          if text:find('^┌') and text:find(label, 1, true) then
            return true
          end
        end
      end
    end
    return false
  end

  notebook.enable(buf)
  notebook.render(buf)
  assert_true(vim.wait(1000, function()
    return has_titled_border(0, '#1 Top') and has_titled_border(2, '#2 Second')
  end, 20), 'cell labels should be rendered in top borders')

  notebook.disable(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('open output creates readonly focusable floating buffer', function()
  local notebook = require('notebook_style')
  local cells_mod = require('notebook_style.cells')
  local config = require('notebook_style.config')
  local state = require('notebook_style.state')
  local buf = vim.api.nvim_create_buf(false, true)
  local old_columns = vim.o.columns
  local old_lines = vim.o.lines

  vim.o.columns = 120
  vim.o.lines = 40
  notebook.setup({
    keymaps = false,
    output_view = {
      width = 0.5,
      height = 0.5,
    },
  })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %% Alpha',
    'print("hello")',
    '# %% Beta',
    'print("bye")',
  })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local delimiters = cells_mod.find_delimiters(buf, config.options.cell_delimiter)
  local cell_list = cells_mod.get_cells(buf, delimiters, vim.api.nvim_buf_line_count(buf))
  local cell_id = state.cell_id(buf, cell_list[1])
  state.apply_event(buf, cell_id, { kind = 'execute_input', execution_count = 3 })
  state.apply_event(buf, cell_id, { kind = 'stream', name = 'stdout', text = 'hello\nline two\n' })
  state.apply_event(buf, cell_id, {
    kind = 'execute_result',
    execution_count = 3,
    data = { ['text/plain'] = '42' },
  })

  local winid, output_buf = notebook.open_output(buf)
  assert_true(winid and vim.api.nvim_win_is_valid(winid), 'output viewer window should be valid')
  assert_true(output_buf and vim.api.nvim_buf_is_valid(output_buf), 'output viewer buffer should be valid')
  assert_eq(vim.api.nvim_get_current_win(), winid, 'output viewer should receive focus')
  assert_eq(vim.api.nvim_win_get_config(winid).relative, 'editor', 'output viewer should be floating')
  assert_eq(vim.api.nvim_win_get_config(winid).focusable, true, 'output viewer should be focusable')
  assert_eq(vim.api.nvim_win_get_config(winid).width, 60, 'output viewer width should follow config')
  assert_eq(vim.api.nvim_win_get_config(winid).height, 19, 'output viewer height should follow config')
  assert_eq(vim.bo[output_buf].buftype, 'nofile', 'output viewer should be scratch')
  assert_eq(vim.bo[output_buf].readonly, true, 'output viewer should be readonly')
  assert_eq(vim.bo[output_buf].modifiable, false, 'output viewer should not be modifiable')
  assert_eq(vim.wo[winid].wrap, false, 'output viewer should not wrap long lines')
  assert_eq(table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), '\n'), 'hello\nline two\n42')

  pcall(vim.api.nvim_win_close, winid, true)
  notebook.disable(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.o.columns = old_columns
  vim.o.lines = old_lines
end)

test('auto_venv starts a local venv kernel when available', function()
  local backend = backend_path()
  if vim.fn.executable(backend) ~= 1 then
    skip_now('backend binary not executable: ' .. backend)
  end

  local python = vim.fn.exepath('python3')
  if python == '' then
    skip_now('python3 not found')
  end
  if not python_imports_ipykernel(python) then
    skip_now('python3 cannot import ipykernel')
  end

  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local project = vim.fn.tempname()
  local old_notify = vim.notify
  local messages = {}
  local buf

  local function cleanup()
    vim.notify = old_notify
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(exec.stop_kernel, buf)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    vim.fn.delete(project, 'rf')
  end

  local ok, err = pcall(function()
    assert_eq(vim.fn.mkdir(project .. '/.venv/bin', 'p'), 1, 'failed to create temporary .venv')
    local symlink_ok, symlink_err = pcall(vim.loop.fs_symlink, python, project .. '/.venv/bin/python')
    if not symlink_ok then
      skip_now('could not create python symlink: ' .. tostring(symlink_err))
    end
    vim.fn.writefile({ '# %%', "print('hello from auto_venv')" }, project .. '/sample.py')

    vim.notify = function(message)
      table.insert(messages, tostring(message))
    end

    notebook.setup({
      backend_cmd = { backend },
      auto_venv = true,
      keymaps = false,
    })
    vim.cmd('edit ' .. vim.fn.fnameescape(project .. '/sample.py'))
    buf = vim.api.nvim_get_current_buf()

    local started = false
    exec.start_kernel(buf, function()
      started = true
    end)

    assert_true(vim.wait(20000, function()
      return started
    end, 100), 'kernel did not start; messages=' .. vim.inspect(messages))

    local saw_local_venv = false
    for _, message in ipairs(messages) do
      if message:find("kernel 'local%-venv' started") then
        saw_local_venv = true
        break
      end
    end
    assert_true(saw_local_venv, 'kernel did not use local-venv; messages=' .. vim.inspect(messages))
  end)

  cleanup()
  if not ok then
    error(err, 0)
  end
end)

print(string.format('notebook_style Lua smoke tests: %d passed, %d skipped, %d failed', passed, skipped, #failures))

if #failures > 0 then
  error(table.concat(failures, '\n'))
end
