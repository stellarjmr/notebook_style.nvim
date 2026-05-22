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
  assert_eq(vim.fn.exists(':NotebookStyleRunCell'), 2, 'run command should exist')
  assert_eq(vim.fn.exists(':NotebookStyleDownloadBackend'), 2, 'backend installer command should exist')
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
