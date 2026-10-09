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

-- Single-quote a string for /bin/sh. Unlike shellescape(), this does not
-- depend on Neovim's 'shell' option, which may name csh or fish.
local function sh_quote(text)
  return "'" .. text:gsub("'", [['\'']]) .. "'"
end

-- An error raised in an asynchronous callback (vim.schedule, libuv, jobs) does
-- not reach the test's pcall: Neovim only prints it and records the message in
-- v:errmsg. The harness checks v:errmsg after every test and fails the test if
-- it was set. Consequences and limits:
-- * Any error message counts, including vim.notify(..., ERROR) and
--   nvim_echo(..., { err = true }): a test that expects error notifications
--   must capture vim.notify.
-- * An error is reported by the first test that checks after it happened,
--   which can be a later test; for an exception raised in a callback, the
--   message's traceback names its source.
-- * A later empty error message, or code resetting v:errmsg, erases it.
-- * After the last test only callbacks that come due within 50 ms are run and
--   checked; later timers are neither run nor checked.
local function take_error_message()
  local message = vim.v.errmsg
  if message == '' then
    return nil
  end
  vim.v.errmsg = ''
  return message
end
vim.v.errmsg = ''

local function test(name, fn)
  local ok, err = pcall(fn)
  local error_message = take_error_message()
  if error_message then
    local detail = 'error message recorded while the test ran (v:errmsg): ' .. error_message
    if ok or (type(err) == 'table' and err.skip) then
      ok, err = false, detail
    else
      err = tostring(err) .. '\n' .. detail
    end
  end

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

local function has_keymap(maps, lhs)
  for _, map in ipairs(maps) do
    if map.lhs == lhs then
      return true
    end
  end
  return false
end

local function has_buffer_keymap(bufnr, lhs)
  return has_keymap(vim.api.nvim_buf_get_keymap(bufnr, 'n'), lhs)
end

local function has_global_keymap(lhs)
  return has_keymap(vim.api.nvim_get_keymap('n'), lhs)
end

local function highlight_fg(name)
  local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
  if not hl.fg then
    return ''
  end
  return string.format('#%06x', hl.fg)
end

test('errors raised in asynchronous callbacks are detected', function()
  -- Guards the v:errmsg check in test(): if Neovim stops recording callback
  -- errors there, async failures would pass silently again.
  vim.schedule(function()
    error('expected error: vim.schedule detection canary')
  end)
  vim.wait(50)
  local message = take_error_message()
  assert_true(message and message:find('vim.schedule detection canary', 1, true) ~= nil,
    'a vim.schedule callback error was not recorded: ' .. vim.inspect(message))

  local timer = (vim.uv or vim.loop).new_timer()
  timer:start(0, 0, function()
    timer:close()
    error('expected error: libuv detection canary')
  end)
  vim.wait(50)
  message = take_error_message()
  assert_true(message and message:find('libuv detection canary', 1, true) ~= nil,
    'a libuv callback error was not recorded: ' .. vim.inspect(message))
end)

-- Replace rpc.spawn with an in-process fake backend, so execution logic can be
-- tested without the Rust binary or a Jupyter kernel. Requests are recorded
-- and answered by the test with fake.reply(); fake.exit() behaves like the
-- backend process exiting. Always call fake.restore() afterwards.
local function fake_backend()
  local rpc = require('notebook_style.rpc')
  local original_spawn = rpc.spawn
  local fake = { calls = {}, clients = {}, calls_after_exit = {} }

  rpc.spawn = function(opts)
    local client = { job = 1000 + #fake.clients, handlers = {}, opts = opts }
    function client:call(method, params, cb)
      cb = cb or function() end
      if self.exited then
        table.insert(fake.calls_after_exit, method)
        cb('notebook-style-core is not running', nil)
        return
      end
      table.insert(fake.calls, { client = self, method = method, params = params, cb = cb })
    end
    function client:on(method, handler)
      self.handlers[method] = handler
    end
    table.insert(fake.clients, client)
    fake.client = client
    return client
  end

  function fake.methods()
    return vim.tbl_map(function(call)
      return call.method
    end, fake.calls)
  end

  function fake.count(method)
    return #vim.tbl_filter(function(call)
      return call.method == method
    end, fake.calls)
  end

  -- Answer the oldest unanswered request for `method`; returns that request.
  function fake.reply(method, err, result)
    for _, call in ipairs(fake.calls) do
      if call.method == method and not call.answered then
        call.answered = true
        call.cb(err, result)
        return call
      end
    end
    error('no unanswered ' .. method .. ' request; calls=' .. vim.inspect(fake.methods()), 2)
  end

  -- Like rpc.lua when the process exits: outstanding requests fail, then the
  -- client's on_exit handler runs. With { replies_after_exit = true } the
  -- outstanding requests stay open instead, so a test can deliver replies that
  -- were read only after the exit had been handled.
  function fake.exit(code, signal, opts)
    local client = fake.client
    client.exited = true
    if not (opts and opts.replies_after_exit) then
      for _, call in ipairs(fake.calls) do
        if call.client == client and not call.answered then
          call.answered = true
          call.cb('notebook-style-core exited', nil)
        end
      end
    end
    client.opts.on_exit(code, signal)
  end

  function fake.restore()
    rpc.spawn = original_spawn
    -- Make exec.lua drop its fake client so later tests spawn a real backend.
    for _, client in ipairs(fake.clients) do
      if not client.exited then
        client.exited = true
        client.opts.on_exit(0, 0)
      end
    end
  end

  return fake
end

-- Every real backend the suite spawns, so tests can find its pid and shut it
-- down. A backend inherits JUPYTER_PATH when it is spawned: a test that sets
-- up its own kernelspecs must start from a fresh backend, or kernelspec lookup
-- silently falls back to whatever kernels the user has installed.
local backends = {}
do
  local rpc = require('notebook_style.rpc')
  local spawn = rpc.spawn
  rpc.spawn = function(opts)
    local client
    client = spawn(vim.tbl_extend('force', opts, {
      on_exit = function(...)
        if opts.on_exit then
          opts.on_exit(...)
        end
        client.exit_handled = true
      end,
    }))
    table.insert(backends, client)
    return client
  end
end

-- Whether a process exists (`kill -0`). A process that exited but was not
-- reaped by its parent still exists.
local function process_alive(pid)
  vim.fn.system({ 'kill', '-0', tostring(pid) })
  return vim.v.shell_error == 0
end

-- Whether a process has exited, counting a zombie (state Z) as exited: an
-- orphan is reaped by init or a subreaper, which may happen late (for
-- example in a container), so only its state shows that it has exited.
local function process_exited(pid)
  local stat = vim.trim(vim.fn.system({ 'ps', '-o', 'stat=', '-p', tostring(pid) }))
  return stat == '' or stat:sub(1, 1) == 'Z'
end

-- Shut down every live backend the way Neovim does on exit (stdin EOF, so it
-- kills its kernels) and wait until exec.lua has handled the exit.
local function close_backends()
  local old_notify = vim.notify
  vim.notify = function() end
  local live = vim.tbl_filter(function(client)
    return not client.exit_handled
  end, backends)
  for _, client in ipairs(live) do
    if not client.stdin:is_closing() then
      client.stdin:close()
    end
  end
  local closed = vim.wait(10000, function()
    for _, client in ipairs(live) do
      if not client.exit_handled then
        return false
      end
    end
    return true
  end, 10)
  vim.notify = old_notify
  assert_true(closed, 'backend did not exit after stdin EOF')
end

test('sh_quote round-trips awkward paths through /bin/sh', function()
  for _, text in ipairs({ 'plain', 'with space', "it's", 'bang!', [[back\slash]], '$HOME', [["double"]] }) do
    local out = vim.fn.system({ '/bin/sh', '-c', 'printf %s ' .. sh_quote(text) })
    assert_eq(out, text, 'quoting must survive /bin/sh unchanged')
  end
end)

test('setup registers commands and defaults', function()
  local notebook = require('notebook_style')
  notebook.setup({ keymaps = false })

  local config = require('notebook_style.config')
  assert_eq(config.options.auto_venv, true, 'auto_venv should default to true')
  assert_eq(config.options.output_view.width, 0.5, 'output viewer width should default to 50%')
  assert_eq(config.options.output_view.height, 0.5, 'output viewer height should default to 50%')
  assert_eq(vim.fn.exists(':NotebookStyleRunCell'), 2, 'run command should exist')
  assert_eq(vim.fn.exists(':NotebookStyleOpenOutput'), 2, 'output viewer command should exist')
  assert_eq(vim.fn.exists(':NotebookStyleDownloadBackend'), 2, 'backend installer command should exist')
  assert_eq(vim.fn.exists(':NotebookStyleKernelInterrupt'), 2, 'kernel interrupt command should exist')
  assert_eq(vim.fn.exists(':NotebookStyleKernelRestart'), 2, 'kernel restart command should exist')
  assert_eq(vim.fn.exists(':NotebookStyleSelectKernel'), 2, 'kernel selector command should exist')
  assert_eq(vim.fn.exists(':NotebookStyleClearOutput'), 2, 'clear current output command should exist')
  assert_eq(vim.fn.exists(':NotebookStyleClearCellOutput'), 2, 'clear current cell output alias should exist')
  assert_eq(vim.fn.exists(':NotebookStyleClearAllOutputs'), 2, 'clear all outputs command should exist')
end)

test('colorscheme reapplies configured highlights', function()
  local notebook = require('notebook_style')
  notebook.setup({
    keymaps = false,
    colors = {
      border = '#123456',
      delimiter = '#abcdef',
      output = '#111111',
      result = '#222222',
      error = '#333333',
    },
  })

  vim.api.nvim_set_hl(0, 'NotebookCellBorder', { fg = '#000000' })
  vim.api.nvim_set_hl(0, 'NotebookCellOutput', { fg = '#000000' })
  vim.cmd('doautocmd ColorScheme')

  assert_eq(highlight_fg('NotebookCellBorder'), '#123456', 'border highlight should be restored')
  assert_eq(highlight_fg('NotebookCellOutput'), '#111111', 'output highlight should be restored')
end)

test('select kernel stores a buffer-local kernel override', function()
  local exec = require('notebook_style.exec')
  local state = require('notebook_style.state')
  local buf = vim.api.nvim_create_buf(false, true)
  local old_select = vim.ui.select
  local old_list_kernels = exec.list_kernels

  local ok, err = pcall(function()
    exec.list_kernels = function(callback)
      callback(nil, {
        { name = 'python3', display_name = 'Python 3', language = 'python' },
        { name = 'analysis', display_name = 'Analysis Env', language = 'python' },
      })
    end

    vim.ui.select = function(items, opts, callback)
      assert_eq(#items, 2, 'kernel selector should receive discovered kernels')
      assert_eq(opts.format_item(items[1]), 'Python 3 (python3) [python]', 'kernel label should include display, name, and language')
      callback(items[2])
    end

    exec.select_kernel(buf)
    assert_eq(state.kernel_name(buf), 'analysis', 'selected kernel should be stored for the buffer')
  end)

  vim.ui.select = old_select
  exec.list_kernels = old_list_kernels
  state.clear(buf)
  vim.api.nvim_buf_delete(buf, { force = true })

  if not ok then
    error(err, 0)
  end
end)

test('keymaps=false skips buffer-local keymaps', function()
  local notebook = require('notebook_style')
  local buf = vim.api.nvim_create_buf(false, true)

  notebook.setup({ keymaps = false })
  vim.api.nvim_set_current_buf(buf)
  notebook.enable(buf)

  assert_true(not has_buffer_keymap(buf, '<leader>rs'), 'toggle keymap should not be registered')
  assert_true(not has_global_keymap('<leader>rs'), 'toggle keymap should not be global')

  notebook.disable(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('setup registers configurable output viewer keymap as buffer-local', function()
  local notebook = require('notebook_style')
  local buf = vim.api.nvim_create_buf(false, true)
  local other = vim.api.nvim_create_buf(false, true)

  notebook.setup({
    keymaps = {
      toggle_render = false,
      run_cell = false,
      run_file = false,
      run_cell_and_move = false,
      open_output = '<F12>',
    },
  })
  vim.api.nvim_set_current_buf(buf)
  notebook.enable(buf)

  assert_true(has_buffer_keymap(buf, '<F12>'), 'open output keymap should be registered for enabled buffer')
  assert_true(not has_buffer_keymap(other, '<F12>'), 'open output keymap should not leak to other buffers')
  assert_true(not has_global_keymap('<F12>'), 'open output keymap should not be global')

  notebook.disable(buf)
  assert_true(not has_buffer_keymap(buf, '<F12>'), 'open output keymap should be cleared when disabled')

  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_buf_delete(other, { force = true })
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

test('cell detection classifies Jupytext markdown markers', function()
  local config = require('notebook_style.config')
  local cells = require('notebook_style.cells')
  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %% [markdown]',
    '# # Heading',
    '# %% [MD] Notes',
    '# More text',
    '# %% Analysis',
    'value = 1',
  })

  local delimiters = cells.find_delimiters(buf, config.options.cell_delimiter)
  local cell_list = cells.get_cells(buf, delimiters, vim.api.nvim_buf_line_count(buf))
  assert_eq(cell_list[1].kind, 'markdown')
  assert_eq(cell_list[1].name, 'Markdown', 'bare markdown marker should get a readable label')
  assert_eq(cell_list[2].kind, 'markdown')
  assert_eq(cell_list[2].name, 'Notes', 'text after markdown marker should be used as the label')
  assert_eq(cell_list[3].kind, 'code')
  assert_eq(cell_list[3].name, 'Analysis')

  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('markdown parser returns source-aligned conceal and highlight ranges', function()
  local markdown = require('notebook_style.markdown')
  local decorations = markdown.parse({
    '# **bold**',
    '# # Heading with [link](https://example.com/a_(b))',
    '# - [x] finished',
    '# > quoted',
    '# | Name | Value |',
    '# | :--- | ---: |',
    '# | alpha | 1 |',
    '# ```python',
    '# **literal code**',
    '# ```',
    'not_a_comment = true',
  })

  local function marks_at(line)
    for _, decoration in ipairs(decorations) do
      if decoration.line == line then
        return decoration.marks
      end
    end
    return {}
  end

  local function has_mark(line, expected)
    for _, mark in ipairs(marks_at(line)) do
      local matches = true
      for key, value in pairs(expected) do
        if mark[key] ~= value then
          matches = false
          break
        end
      end
      if matches then
        return true
      end
    end
    return false
  end

  assert_true(has_mark(0, { kind = 'conceal', col = 0, end_col = 2 }), 'Jupytext prefix should be concealed')
  assert_true(has_mark(0, { kind = 'conceal', col = 2, end_col = 4 }), 'bold opener should be concealed')
  assert_true(
    has_mark(0, { kind = 'hl', col = 4, end_col = 8, hl = 'NotebookMarkdownBold' }),
    'bold content should keep source byte columns'
  )
  assert_true(has_mark(0, { kind = 'conceal', col = 8, end_col = 10 }), 'bold closer should be concealed')
  assert_true(has_mark(1, { kind = 'virt', col = 2 }), 'heading should receive an inline marker')
  assert_true(has_mark(1, { kind = 'hl', hl = 'NotebookMarkdownLink' }), 'balanced links should be highlighted')
  assert_true(has_mark(2, { kind = 'virt', col = 2 }), 'task list should receive an inline checkbox')
  assert_true(has_mark(3, { kind = 'virt', col = 2 }), 'quote should receive an inline marker')
  assert_true(
    has_mark(4, { kind = 'hl', hl = 'NotebookMarkdownTableHeader' }),
    'only the table header should receive header styling'
  )
  assert_true(
    not has_mark(6, { kind = 'hl', hl = 'NotebookMarkdownTableHeader' }),
    'table body should not receive header styling'
  )
  assert_true(has_mark(5, { kind = 'hl', hl = 'NotebookMarkdownTableBorder' }), 'table pipes should be highlighted')
  assert_true(
    has_mark(8, { kind = 'hl', hl = 'NotebookMarkdownCodeBlock' }),
    'fenced code should be highlighted without parsing inline markers'
  )
  assert_true(
    not has_mark(8, { kind = 'hl', hl = 'NotebookMarkdownBold' }),
    'inline emphasis should stay literal inside fenced code'
  )
  assert_eq(#marks_at(10), 0, 'non-comment lines should be left unchanged')

  for _, decoration in ipairs(decorations) do
    for _, mark in ipairs(decoration.marks) do
      assert_true(mark.kind ~= 'overlay', 'markdown rendering should never replace a complete source line')
    end
  end
end)

test('markdown decorations render only outside insert mode', function()
  local notebook = require('notebook_style')
  local render = require('notebook_style.render')
  local cells_mod = require('notebook_style.cells')
  local config = require('notebook_style.config')
  local buf = vim.api.nvim_create_buf(false, true)

  notebook.setup({ keymaps = false, markdown = { enabled = true } })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %% [markdown]',
    '# # Rendered heading',
    '# A long paragraph with **bold** text and a [link](https://example.com).',
    '# %% Code',
    'value = 1',
  })
  vim.api.nvim_set_current_buf(buf)

  local delimiters = cells_mod.find_delimiters(buf, config.options.cell_delimiter)
  local cell_list = cells_mod.get_cells(buf, delimiters, vim.api.nvim_buf_line_count(buf))
  render.render_all(buf, cell_list, 'n', vim.api.nvim_get_current_win())

  local marks = vim.api.nvim_buf_get_extmarks(buf, render.markdown_ns, 0, -1, { details = true })
  assert_true(#marks > 0, 'normal mode should render markdown decorations')
  for _, mark in ipairs(marks) do
    assert_true(mark[2] < 3, 'code cells should not receive markdown decorations')
    assert_true((mark[4] or {}).virt_text_pos ~= 'overlay', 'markdown should not use whole-line overlays')
  end

  render.render_all(buf, cell_list, 'i', vim.api.nvim_get_current_win())
  assert_eq(
    #vim.api.nvim_buf_get_extmarks(buf, render.markdown_ns, 0, -1, {}),
    0,
    'insert mode should reveal raw Jupytext comments'
  )

  local original_markdown_config = config.options.markdown
  config.options.markdown = false
  render.render_all(buf, cell_list, 'n', vim.api.nvim_get_current_win())
  assert_eq(
    #vim.api.nvim_buf_get_extmarks(buf, render.markdown_ns, 0, -1, {}),
    0,
    'markdown=false should leave source comments unrendered'
  )
  config.options.markdown = original_markdown_config

  notebook.disable(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('markdown cells do not start the execution kernel', function()
  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local buf = vim.api.nvim_create_buf(false, true)
  local old_notify = vim.notify
  local old_start_kernel = exec.start_kernel
  local messages = {}
  local starts = 0

  local ok, err = pcall(function()
    notebook.setup({ keymaps = false, auto_start_kernel = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      '# %% [markdown]',
      '# This is documentation, not Python.',
    })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    vim.notify = function(message)
      table.insert(messages, tostring(message))
    end
    exec.start_kernel = function()
      starts = starts + 1
    end

    exec.run_cell(buf)
    exec.run_file(buf)
    assert_eq(starts, 0, 'markdown cells should not start a kernel')
    assert_true(
      table.concat(messages, '\n'):find('markdown cells are not executable', 1, true) ~= nil,
      'running a markdown cell should explain why it was skipped'
    )
    assert_true(
      table.concat(messages, '\n'):find('no runnable cells found', 1, true) ~= nil,
      'running a markdown-only file should report that there is nothing to execute'
    )
  end)

  vim.notify = old_notify
  exec.start_kernel = old_start_kernel
  notebook.disable(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  if not ok then
    error(err, 0)
  end
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

  notebook.setup({
    keymaps = false,
    cell_marker = 'CODE ',
    markdown = { cell_marker = 'MD ' },
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %% [markdown] Top',
    '# Markdown text',
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
    return has_titled_border(0, 'MD #1 Top') and has_titled_border(2, 'CODE #2 Second')
  end, 20), 'markdown and code markers should be rendered independently in top borders')

  notebook.disable(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('busy cells render an Out[*] running indicator', function()
  local notebook = require('notebook_style')
  local render = require('notebook_style.render')
  local cells_mod = require('notebook_style.cells')
  local config = require('notebook_style.config')
  local state = require('notebook_style.state')
  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %% Busy',
    'import time; time.sleep(60)',
  })
  vim.api.nvim_set_current_buf(buf)

  local delimiters = cells_mod.find_delimiters(buf, config.options.cell_delimiter)
  local cell_list = cells_mod.get_cells(buf, delimiters, vim.api.nvim_buf_line_count(buf))
  local cell_id = state.cell_id(buf, cell_list[1])
  state.apply_event(buf, cell_id, { kind = 'execute_input', execution_count = 1 })

  local function virt_lines_text()
    local out = {}
    local marks = vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })
    for _, mark in ipairs(marks) do
      for _, line in ipairs((mark[4] or {}).virt_lines or {}) do
        for _, chunk in ipairs(line) do
          table.insert(out, chunk[1] or '')
        end
      end
    end
    return table.concat(out, '\n')
  end

  notebook.enable(buf)
  notebook.render(buf)
  assert_true(vim.wait(1000, function()
    local text = virt_lines_text()
    return text:find('Out[*]', 1, true) ~= nil and text:find('running…', 1, true) ~= nil
  end, 20), 'busy cell should render Out[*] divider and running indicator')

  state.apply_event(buf, cell_id, { kind = 'execute_reply', status = 'ok', execution_count = 1 })
  notebook.render(buf)
  assert_true(vim.wait(1000, function()
    return virt_lines_text():find('Out[*]', 1, true) == nil
  end, 20), 'idle cell should not render the busy indicator')

  notebook.disable(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('long output lines wrap at the frame width and stop at output_max_lines', function()
  local notebook = require('notebook_style')
  local state = require('notebook_style.state')
  local render = require('notebook_style.render')
  local cells = require('notebook_style.cells')
  local config = require('notebook_style.config')
  local buf = vim.api.nvim_create_buf(false, true)
  local first_win = vim.api.nvim_get_current_win()
  local windows_before = vim.api.nvim_list_wins()

  local ok, err = pcall(function()
    notebook.setup({ keymaps = false, output_max_lines = 6 })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'print(1)' })
    local cell = cells.get_cells(buf, cells.find_delimiters(buf, config.options.cell_delimiter), 2)[1]
    local id = state.cell_id(buf, cell)

    local function output_rows(text, win)
      state.apply_event(buf, id, { kind = 'execute_input', execution_count = 1 })
      state.apply_event(buf, id, { kind = 'stream', name = 'stdout', text = text })
      render.render_all(buf, { cell }, 'n', win)
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
        local lines = mark[4].virt_lines
        if lines then
          local rows = {}
          for i = 2, #lines - 1 do -- skip the Out[n] divider and the bottom border
            table.insert(rows, lines[i][2][1])
          end
          return rows
        end
      end
      error('no output frame rendered')
    end

    -- Expectations follow from the text width (frame width minus the side
    -- borders and padding); check an even and an odd one.
    local function check(win)
      local text_width = vim.api.nvim_win_get_width(win) - 4
      local half = math.floor(text_width / 2)
      local label = ' (text width ' .. text_width .. ')'

      local rows = output_rows(string.rep('x', 2 * text_width + 5) .. '\n', win)
      assert_eq(#rows, 3, 'ASCII rows' .. label)
      assert_eq(rows[1], string.rep('x', text_width))
      assert_eq(rows[2], string.rep('x', text_width))
      assert_eq(rows[3], 'xxxxx')

      rows = output_rows(string.rep('中', text_width) .. '\n', win)
      assert_eq(rows[1], string.rep('中', half), 'double-width characters fill rows by display cells' .. label)
      assert_eq(#rows, math.ceil(text_width / half), 'double-width rows' .. label)

      -- After a one-cell character, the double-width character that would
      -- overflow the row moves to the next row.
      local fit = math.floor((text_width - 1) / 2)
      rows = output_rows('a' .. string.rep('中', fit + 1) .. '\n', win)
      assert_eq(rows[1], 'a' .. string.rep('中', fit), 'mixed widths' .. label)
      assert_eq(rows[2], '中', 'mixed widths' .. label)

      -- strip_ansi removes ESC and one byte, which can leave a byte of a
      -- multibyte character behind; it still takes its four cells, shown as
      -- <a9> (Neovim stores it in the extmark text that way).
      rows = output_rows('\27é' .. string.rep('x', text_width) .. '\n', win)
      assert_eq(rows[1], '<a9>' .. string.rep('x', text_width - 4), 'a leftover byte keeps its cells' .. label)
      assert_eq(rows[2], 'xxxx')

      rows = output_rows(string.rep('y', 100 * text_width) .. '\n', win)
      assert_eq(#rows, 7, 'six output rows plus the truncation marker' .. label)
      assert_eq(rows[6], string.rep('y', text_width))
      assert_true(rows[7]:find('output truncated', 1, true) ~= nil, rows[7])

      rows = output_rows(string.rep('中', 100 * text_width) .. '\n', win)
      assert_eq(#rows, 7, 'the row budget also stops double-width text' .. label)
      assert_eq(rows[6], string.rep('中', half))
    end

    check(first_win)
    -- Then a split whose text width has the other parity (in the headless
    -- 80-column suite: 76, then 37).
    local first_parity = (vim.api.nvim_win_get_width(first_win) - 4) % 2
    vim.cmd('vsplit')
    local split_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(split_win, first_parity == 0 and 41 or 40)
    assert_true((vim.api.nvim_win_get_width(split_win) - 4) % 2 ~= first_parity, 'the split must have a text width of the other parity')
    check(split_win)

    -- Wrapping must stop at the row budget: a 100K-character line used to take
    -- seconds per render because the whole line was wrapped every time.
    local uv = vim.uv or vim.loop
    local started = uv.hrtime()
    local rows = output_rows(string.rep('z', 100000) .. '\n', first_win)
    local elapsed_ms = (uv.hrtime() - started) / 1e6
    assert_eq(#rows, 7)
    assert_true(elapsed_ms < 1000, string.format('rendering a 100K-character line took %.0f ms', elapsed_ms))
  end)

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not vim.tbl_contains(windows_before, win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.api.nvim_set_current_win(first_win)
  state.clear(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  if not ok then error(err, 0) end
end)

test('clear output commands remove state, rendering, and output view', function()
  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local render = require('notebook_style.render')
  local cells_mod = require('notebook_style.cells')
  local config = require('notebook_style.config')
  local state = require('notebook_style.state')
  local buf = vim.api.nvim_create_buf(false, true)

  notebook.setup({ keymaps = false })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %% Alpha',
    'print("first")',
    '# %% Beta',
    'print("second")',
  })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local delimiters = cells_mod.find_delimiters(buf, config.options.cell_delimiter)
  local cell_list = cells_mod.get_cells(buf, delimiters, vim.api.nvim_buf_line_count(buf))
  local first_id = state.cell_id(buf, cell_list[1])
  local second_id = state.cell_id(buf, cell_list[2])
  state.apply_event(buf, first_id, { kind = 'execute_input', execution_count = 1 })
  state.apply_event(buf, first_id, { kind = 'stream', name = 'stdout', text = 'first output' })
  state.apply_event(buf, second_id, { kind = 'execute_input', execution_count = 2 })
  state.apply_event(buf, second_id, { kind = 'stream', name = 'stdout', text = 'second output' })

  local function virt_lines_text()
    local out = {}
    local marks = vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })
    for _, mark in ipairs(marks) do
      for _, line in ipairs((mark[4] or {}).virt_lines or {}) do
        for _, chunk in ipairs(line) do
          table.insert(out, chunk[1] or '')
        end
      end
    end
    return table.concat(out, '\n')
  end

  notebook.enable(buf)
  notebook.render(buf)
  assert_true(vim.wait(1000, function()
    local text = virt_lines_text()
    return text:find('first output', 1, true) ~= nil and text:find('second output', 1, true) ~= nil
  end, 20), 'both outputs should render before clearing')

  local winid, output_buf = notebook.open_output(buf)
  assert_true(winid and vim.api.nvim_win_is_valid(winid), 'output viewer should open before clearing')
  assert_true(output_buf and vim.api.nvim_buf_is_valid(output_buf), 'output viewer buffer should exist before clearing')

  vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  exec.clear_cell_output(buf)

  assert_eq(#state.outputs(buf, cell_list[1]), 0, 'current cell output state should be cleared')
  assert_eq(#state.outputs(buf, cell_list[2]), 1, 'other cell output state should remain')
  assert_true(vim.wait(1000, function()
    return not vim.api.nvim_win_is_valid(winid) and not vim.api.nvim_buf_is_valid(output_buf)
  end, 20), 'output viewer should close when current output is cleared')
  assert_true(vim.wait(1000, function()
    local text = virt_lines_text()
    return text:find('first output', 1, true) == nil and text:find('second output', 1, true) ~= nil
  end, 20), 'rendered current output should be removed')

  exec.clear_outputs(buf)
  assert_eq(#state.outputs(buf, cell_list[1]), 0, 'first cell should remain clear')
  assert_eq(#state.outputs(buf, cell_list[2]), 0, 'all output state should be cleared')
  assert_true(vim.wait(1000, function()
    return virt_lines_text():find('second output', 1, true) == nil
  end, 20), 'all rendered output should be removed')

  notebook.disable(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('extmark identity keeps outputs attached across edits', function()
  local cells_mod = require('notebook_style.cells')
  local config = require('notebook_style.config')
  local state = require('notebook_style.state')
  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %% Alpha',
    'print("first")',
    '# %% Beta',
    'print("second")',
  })

  local function scan()
    local delimiters = cells_mod.find_delimiters(buf, config.options.cell_delimiter)
    return cells_mod.get_cells(buf, delimiters, vim.api.nvim_buf_line_count(buf))
  end

  local cell_list = scan()
  local beta_id = state.cell_id(buf, cell_list[2])
  state.apply_event(buf, beta_id, { kind = 'execute_input', execution_count = 1 })
  state.apply_event(buf, beta_id, { kind = 'stream', name = 'stdout', text = 'second output' })

  -- Insert a new cell above: Beta shifts from ordinal 2 to ordinal 3
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { '# %% Inserted', 'x = 1' })
  cell_list = scan()
  state.sync_cells(buf, cell_list)  -- production order: GC runs before rendering resolves ids
  assert_eq(#cell_list, 3, 'expected three cells after inserting one above')
  assert_eq(state.cell_id(buf, cell_list[3]), beta_id, 'Beta should keep its identity after inserting a cell above')
  assert_eq(state.outputs(buf, cell_list[3])[1].text, 'second output', 'Beta output should follow the cell')

  -- Rename the delimiter (whole-line replacement): identity must survive the
  -- GC-before-render ordering used by update_cells
  local beta_row = cell_list[3].delimiter
  vim.api.nvim_buf_set_lines(buf, beta_row, beta_row + 1, false, { '# %% Renamed Beta' })
  cell_list = scan()
  state.sync_cells(buf, cell_list)
  assert_eq(state.cell_id(buf, cell_list[3]), beta_id, 'Beta should keep its identity after renaming the delimiter')
  assert_eq(state.outputs(buf, cell_list[3])[1].text, 'second output', 'Beta output should survive renaming')

  -- Open a new line right below the delimiter (like `o`): identity is stable
  vim.api.nvim_buf_set_lines(buf, beta_row + 1, beta_row + 1, false, { 'y = 2' })
  cell_list = scan()
  state.sync_cells(buf, cell_list)
  assert_eq(state.cell_id(buf, cell_list[3]), beta_id, 'Beta should keep its identity after opening a line below the delimiter')

  state.clear(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('deleting a cell drops its state and keeps neighbor outputs', function()
  local cells_mod = require('notebook_style.cells')
  local config = require('notebook_style.config')
  local state = require('notebook_style.state')
  local buf = vim.api.nvim_create_buf(false, true)

  -- Identical plain delimiters: identity collisions cannot be resolved by
  -- delimiter text, only by the end-of-line mark anchor
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '# %%',
    'print("first")',
    '# %%',
    'print("second")',
  })

  local function scan()
    local delimiters = cells_mod.find_delimiters(buf, config.options.cell_delimiter)
    return cells_mod.get_cells(buf, delimiters, vim.api.nvim_buf_line_count(buf))
  end

  local cell_list = scan()
  local alpha_id = state.cell_id(buf, cell_list[1])
  local beta_id = state.cell_id(buf, cell_list[2])
  state.apply_event(buf, alpha_id, { kind = 'stream', name = 'stdout', text = 'first output' })
  state.apply_event(buf, beta_id, { kind = 'stream', name = 'stdout', text = 'second output' })

  -- Delete the whole first cell; its identity mark collapses onto the second
  -- cell's delimiter line
  vim.api.nvim_buf_set_lines(buf, 0, 2, false, {})
  cell_list = scan()
  state.sync_cells(buf, cell_list)  -- production order: GC runs before rendering resolves ids
  assert_eq(#cell_list, 1, 'expected one cell after deleting the first cell')
  assert_eq(state.cell_id(buf, cell_list[1]), beta_id, 'second cell should keep its identity when the first is deleted')
  assert_eq(state.outputs(buf, cell_list[1])[1].text, 'second output', 'second cell output should remain after the collision')

  local buffer_state = state.get(buf)
  assert_eq(buffer_state.outputs[alpha_id], nil, 'deleted cell output state should be dropped after resolving the collision')

  -- A late kernel event for the dropped cell must not resurrect its state
  state.apply_event(buf, alpha_id, { kind = 'stream', name = 'stdout', text = 'late output' })
  assert_eq(buffer_state.outputs[alpha_id], nil, 'late events for garbage-collected cells should be ignored')

  -- Turning the delimiter into a plain comment orphans the identity mark;
  -- sync_cells garbage-collects the mark and its outputs
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { '# not a delimiter' })
  cell_list = scan()
  assert_eq(#cell_list, 0, 'expected no cells after removing the delimiter')
  state.sync_cells(buf, cell_list)
  buffer_state = state.get(buf)
  assert_eq(buffer_state.outputs[beta_id], nil, 'orphaned cell output state should be garbage-collected')
  assert_eq(next(buffer_state.mark_delimiters), nil, 'orphaned identity marks should be garbage-collected')
  state.apply_event(buf, beta_id, { kind = 'stream', name = 'stdout', text = 'late output' })
  assert_eq(buffer_state.outputs[beta_id], nil, 'late events after orphan GC should be ignored')

  state.clear(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('checkhealth notebook_style reports all sections', function()
  vim.cmd('checkhealth notebook_style')
  local lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  assert_true(lines:find('notebook_style: Neovim', 1, true) ~= nil, 'health should report Neovim section')
  assert_true(lines:find('notebook_style: execution backend', 1, true) ~= nil, 'health should report backend section')
  assert_true(lines:find('notebook_style: Jupyter kernel', 1, true) ~= nil, 'health should report kernel section')
  assert_true(lines:find('notebook_style: terminal images', 1, true) ~= nil, 'health should report image section')
  vim.cmd('bwipeout!')
end)

test('checkhealth reports Neovim older than 0.10 as unsupported', function()
  local real_has = vim.fn.has
  local function health_text()
    vim.cmd('checkhealth notebook_style')
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    vim.cmd('bwipeout!')
    return text
  end

  local ok, err = pcall(function()
    assert_true(health_text():find('(>= 0.10)', 1, true) ~= nil, 'the running Neovim should be reported as supported')
    -- Pretend to be an older Neovim: only the 0.10 feature check answers no.
    vim.fn.has = function(feature)
      if feature == 'nvim-0.10' then
        return 0
      end
      return real_has(feature)
    end
    local text = health_text()
    -- Other sections can report errors too (e.g. no backend installed), so
    -- the ERROR must be on the version line itself.
    local version_line
    for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
      if line:find('requires Neovim >= 0.10', 1, true) then
        version_line = line
      end
    end
    assert_true(version_line ~= nil, 'an older Neovim must be reported as unsupported: ' .. text)
    assert_true(version_line:find('ERROR', 1, true) ~= nil, 'as an error: ' .. version_line)
    assert_true(text:find('still works', 1, true) == nil, 'and without claiming that rendering still works')
  end)

  vim.fn.has = real_has
  if not ok then error(err, 0) end
end)

test('a failed backend download keeps the installed backend', function()
  local install = require('notebook_style.install')
  if not install._detect_target() then
    skip_now('no prebuilt backend for this platform')
  end

  -- Stand-ins first on PATH: git reports a release tag; curl writes part of
  -- the file to its -o path and fails like an interrupted transfer, or with
  -- NBS_FAKE_CURL_OK writes the whole file; cargo fails.
  local root = vim.fn.tempname()
  local bin = root .. '/bin'
  local release_dir = root .. '/plugin/core/target/release'
  local dest = release_dir .. '/notebook-style-core'
  vim.fn.mkdir(bin, 'p')
  vim.fn.mkdir(release_dir, 'p')
  local function script(name, lines)
    table.insert(lines, 1, '#!/bin/sh')
    vim.fn.writefile(lines, bin .. '/' .. name)
    vim.fn.setfperm(bin .. '/' .. name, 'rwxr-xr-x')
  end
  script('git', { 'echo v0.0.0-test' })
  script('curl', {
    'while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done',
    'if [ -n "$NBS_FAKE_CURL_OK" ]; then echo "new backend" > "$out"; exit 0; fi',
    'printf partial > "$out"',
    'exit 18',
  })
  script('cargo', { 'echo "fake cargo: build failed" >&2', 'exit 101' })
  vim.fn.writefile({ 'old backend' }, dest)
  vim.fn.setfperm(dest, 'rwxr-xr-x')

  local old_path, old_notify = vim.env.PATH, vim.notify
  vim.env.PATH = bin .. ':' .. old_path
  vim.notify = function() end
  local ok, err = pcall(function()
    local installed, install_err = pcall(install.run, { dir = root .. '/plugin' })
    assert_eq(installed, false, 'the cargo fallback fails here')
    assert_true(tostring(install_err):find('cargo build failed', 1, true) ~= nil, 'unexpected error: ' .. tostring(install_err))
    assert_eq(table.concat(vim.fn.readfile(dest), '\n'), 'old backend', 'a failed download must keep the installed backend')
    assert_eq(vim.fn.executable(dest), 1, 'the installed backend must stay executable')
    assert_eq(table.concat(vim.fn.readdir(release_dir), ' '), 'notebook-style-core', 'no partial download may be left behind')

    vim.env.NBS_FAKE_CURL_OK = '1'
    assert_eq(install.run({ dir = root .. '/plugin' }), true, 'a complete download is installed')
    assert_eq(table.concat(vim.fn.readfile(dest), '\n'), 'new backend', 'the complete download replaces the backend')
    assert_eq(vim.fn.executable(dest), 1, 'the new backend must be executable')
    assert_eq(table.concat(vim.fn.readdir(release_dir), ' '), 'notebook-style-core', 'the download file is moved into place')
  end)

  vim.env.PATH = old_path
  vim.env.NBS_FAKE_CURL_OK = nil
  vim.notify = old_notify
  vim.fn.delete(root, 'rf')
  if not ok then error(err, 0) end
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
  assert_eq(
    vim.wo[winid].winhighlight,
    'NormalFloat:Normal,FloatBorder:Normal,FloatTitle:Normal,EndOfBuffer:Normal',
    'output viewer should use the editor background'
  )
  assert_eq(table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), '\n'), 'hello\nline two\n42')

  pcall(vim.api.nvim_win_close, winid, true)
  notebook.disable(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.o.columns = old_columns
  vim.o.lines = old_lines
end)

test('plain Python buffers expose one implicit execution cell', function()
  local config = require('notebook_style.config')
  local cells = require('notebook_style.cells')
  local buf = vim.api.nvim_create_buf(false, true)
  config.setup({})

  local function scan()
    return cells.get_cells(buf, cells.find_delimiters(buf, config.options.cell_delimiter), vim.api.nvim_buf_line_count(buf))
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'value = 17' })
  assert_eq(#scan(), 0, 'non-Python buffers must not acquire an implicit cell')
  vim.bo[buf].filetype = 'python'
  local cell = scan()[1]
  assert_true(cell.implicit, 'Python without delimiters should have an implicit cell')
  assert_eq(cell.start_line, 0, 'the first source line must be included')
  assert_eq(cell.end_line, 0, 'one-line files must be executable')
  assert_true(cells.is_valid_cell(cell))

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'value = 17', '', '' })
  assert_eq(scan()[1].end_line, 2, 'file output should follow trailing blank lines')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%' })
  assert_true(not scan()[1].implicit, 'an empty explicit cell must not fall back to file execution')
  assert_true(not cells.is_valid_cell(scan()[1]))

  config.options.cell_delimiter = '^# CELL'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# CELL', 'value = 17' })
  assert_true(not scan()[1].implicit, 'custom delimiters must keep working')
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('implicit files render only real output at EOF in auto and manual modes', function()
  local notebook = require('notebook_style')
  local cells = require('notebook_style.cells')
  local render = require('notebook_style.render')
  local state = require('notebook_style.state')
  local exec = require('notebook_style.exec')

  for _, manual in ipairs({ false, true }) do
    notebook.setup({ keymaps = false, manual_render = manual })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'value = 17', 'value', '' })
    local cell = cells.get_cells(buf, {}, 3)[1]
    local id = state.cell_id(buf, cell)
    local function marks()
      return vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })
    end
    local function settle()
      assert_true(vim.wait(1000, function() return not notebook.pending_updates[buf] end, 10))
    end

    notebook.enable(buf)
    settle()
    assert_eq(notebook.render_visible[buf], not manual)
    assert_eq(#marks(), 0, 'unexecuted files must have no code borders')
    state.apply_event(buf, id, { kind = 'execute_input', execution_count = 4 })
    notebook.render(buf)
    settle()
    assert_eq(#marks(), 0, 'busy files without output must have no running placeholder')

    state.apply_event(buf, id, { kind = 'stream', name = 'stdout', text = 'first output' })
    notebook.render(buf)
    settle()
    assert_eq(#marks(), 1, 'only the output extmark should exist')
    assert_eq(marks()[1][2], 2, 'output must be below the actual last line')
    assert_eq(marks()[1][4].virt_text, nil, 'source lines must not have border text')
    assert_eq(marks()[1][4].conceal, nil, 'the first source line must not be concealed')
    assert_true(marks()[1][4].virt_lines[1][1][1]:find('Out[*]', 1, true) ~= nil)

    for _, mode in ipairs({ 'n', 'v', 'i' }) do
      render.render_all(buf, { cell }, mode, vim.api.nvim_get_current_win())
      assert_eq(#marks(), mode == 'i' and 0 or 1, 'output visibility should follow existing mode behavior')
    end
    for _, width in ipairs({ 37, 81 }) do
      render.clear(buf)
      render.render_cell(buf, cell, true, false, width, 1)
      for _, row in ipairs(marks()[1][4].virt_lines) do
        local text = ''
        for _, chunk in ipairs(row) do text = text .. chunk[1] end
        assert_eq(vim.fn.strdisplaywidth(text), width, 'file output borders should fit the window')
      end
    end

    notebook.toggle_render(buf)
    state.apply_event(buf, id, { kind = 'stream', name = 'stdout', text = ' updated' })
    vim.api.nvim_exec_autocmds('ModeChanged', { buffer = buf })
    settle()
    assert_eq(#marks(), 0, 'hidden rendering must stay hidden on updates')
    notebook.toggle_render(buf)
    settle()
    assert_eq(#marks(), 1)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local win, output_buf = notebook.open_output(buf)
    assert_eq(table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), '\n'), 'first output updated')
    vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
    exec.clear_cell_output(buf)
    settle()
    assert_true(not vim.api.nvim_win_is_valid(win), 'clear should close the existing viewer')
    assert_eq(#marks(), 0, 'cleared file output must not leave an empty frame')
    notebook.disable(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end)

test('file identity survives text edits and retires on delimiter transitions', function()
  local notebook = require('notebook_style')
  local cells = require('notebook_style.cells')
  local config = require('notebook_style.config')
  local state = require('notebook_style.state')
  local image = require('notebook_style.image')
  local buf = vim.api.nvim_create_buf(false, true)
  local old_clear = image.clear
  local cleared = {}

  local ok, err = pcall(function()
    notebook.setup({ keymaps = false })
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'value = 17' })
    image.clear = function(output) table.insert(cleared, output) end
    local function scan()
      local list = cells.get_cells(buf, cells.find_delimiters(buf, config.options.cell_delimiter), vim.api.nvim_buf_line_count(buf))
      state.sync_cells(buf, list)
      return list[1]
    end
    local id = state.cell_id(buf, scan())
    local output = state.apply_event(buf, id, { kind = 'display_data', data = { ['image/png'] = 'test image' } })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'renamed = 23', 'print(renamed)', '' })
    assert_eq(state.cell_id(buf, scan()), id, 'replacing the first line must not change file identity')
    assert_eq(state.outputs(buf, scan())[1], output)
    assert_eq(#vim.api.nvim_buf_get_extmarks(buf, state.identity_ns, 0, -1, {}), 0)

    state.apply_event(buf, id, { kind = 'execute_input', execution_count = 2 })
    assert_eq(cleared[1], output, 'rerunning should release old file images')
    assert_eq(#state.outputs(buf, scan()), 0)
    state.apply_event(buf, id, { kind = 'stream', name = 'stdout', text = 'old file output' })
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { '# %% Cell' })
    local explicit = scan()
    local explicit_id = state.cell_id(buf, explicit)
    assert_true(not explicit.implicit)
    assert_eq(state.get(buf).outputs[id], nil)
    state.apply_event(buf, explicit_id, { kind = 'stream', name = 'stdout', text = 'cell output' })

    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { '# ordinary comment' })
    local file = scan()
    local new_id = state.cell_id(buf, file)
    assert_true(new_id ~= id, 'a mode round-trip must allocate a fresh file identity')
    assert_eq(state.get(buf).outputs[explicit_id], nil, 'old cell output must not transfer to the file')
    for _, retired_id in ipairs({ id, explicit_id }) do
      state.apply_event(buf, retired_id, { kind = 'stream', name = 'stdout', text = 'late output' })
      assert_eq(state.get(buf).outputs[retired_id], nil, 'late events must not revive retired identities')
    end
    local final_image = state.apply_event(buf, new_id, { kind = 'display_data', data = { ['image/png'] = 'new image' } })
    notebook.disable(buf)
    assert_eq(cleared[#cleared], final_image, 'disabling should release file images')
  end)

  image.clear = old_clear
  notebook.disable(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  if not ok then error(err, 0) end
end)

test('rpc client delivers responses sent before exit and fails the rest', function()
  local rpc = require('notebook_style.rpc')
  local frame = vim.fn.tempname()
  local payload = vim.mpack.encode({ 1, 1, vim.NIL, 'pong' })
  local file = assert(io.open(frame, 'wb'))
  file:write(string.char(0, 0, math.floor(#payload / 256), #payload % 256) .. payload)
  file:close()

  -- `cat` answers request 1 and exits without answering request 2.
  local exited
  local results = {}
  local client = rpc.spawn({
    cmd = { 'cat', frame },
    on_exit = function(code, signal)
      exited = { code = code, signal = signal }
    end,
  })
  client:call('ping', {}, function(err, result)
    results[1] = { err = err, result = result }
  end)
  client:call('never_answered', {}, function(err, result)
    results[2] = { err = err, result = result }
  end)
  local resolved = vim.wait(5000, function()
    return exited ~= nil and results[1] ~= nil and results[2] ~= nil
  end, 10)
  vim.fn.delete(frame)

  assert_true(resolved, 'calls must resolve once the process exits: ' .. vim.inspect({ exited = exited, results = results }))
  assert_eq(exited.code, 0)
  assert_eq(results[1].err, nil, 'a response written before exit must still be delivered')
  assert_eq(results[1].result, 'pong')
  assert_eq(results[2].err, 'notebook-style-core exited')

  assert_true(client.handle:is_closing(), 'the process handle must be closed after the exit')

  local late
  client:call('after_exit', {}, function(err)
    late = err
  end)
  assert_true(vim.wait(1000, function() return late ~= nil end, 10), 'calls after exit must fail')
  assert_eq(late, 'notebook-style-core is not running')
end)

test('backend exit resets buffer sessions and the next run opens a new one', function()
  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local state = require('notebook_style.state')
  local cells = require('notebook_style.cells')
  local config = require('notebook_style.config')
  local old_notify = vim.notify
  local messages = {}
  local fake = fake_backend()
  local buf

  local ok, err = pcall(function()
    vim.notify = function(message) table.insert(messages, tostring(message)) end
    notebook.setup({ keymaps = false, auto_venv = false, backend_cmd = { 'fake-backend' } })
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'print(1)' })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local cell = cells.get_cells(buf, cells.find_delimiters(buf, config.options.cell_delimiter), 2)[1]

    exec.run_cell(buf)
    fake.reply('open_py', nil, { session_id = 'old-session' })
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    fake.reply('execute_silent', nil, {})
    fake.reply('update_cell_source', nil, { ok = true })
    local cell_id = fake.reply('execute', nil, { msg_id = 'm1' }).params.cell_id
    local old_client = fake.client
    local function event(target, payload)
      target.handlers.cell_event({ session_id = 'old-session', cell_id = cell_id, event = payload })
    end
    event(old_client, { kind = 'execute_input', execution_count = 1 })
    event(old_client, { kind = 'stream', name = 'stdout', text = '1\n' })
    assert_eq(state.status(buf, cell), 'busy')

    messages = {}
    fake.exit(nil, 9)
    local buffer_state = state.get(buf)
    assert_eq(buffer_state.session_id, nil, 'the dead backend session must be forgotten')
    assert_eq(buffer_state.kernel_started, false)
    assert_eq(state.status(buf, cell), nil, 'cells must not stay busy after the backend died')
    assert_eq(state.outputs(buf, cell)[1].text, '1\n', 'existing outputs stay visible')
    assert_eq(#messages, 1, 'expected one notification, got ' .. vim.inspect(messages))
    assert_true(messages[1]:find('execution backend exited', 1, true) ~= nil, messages[1])

    event(old_client, { kind = 'stream', name = 'stdout', text = 'late\n' })
    assert_eq(state.outputs(buf, cell)[1].text, '1\n', 'late events of the dead session must be ignored')

    exec.run_cell(buf)
    assert_eq(#fake.clients, 2, 'the next run must spawn a new backend')
    assert_true(fake.reply('open_py', nil, { session_id = 'new-session' }).client ~= old_client)
    assert_eq(fake.reply('start_kernel', nil, { kernel_name = 'python3' }).params.session_id, 'new-session')
    fake.reply('execute_silent', nil, {})
    fake.reply('update_cell_source', nil, { ok = true })
    assert_eq(fake.reply('execute', nil, { msg_id = 'm2' }).params.session_id, 'new-session')
  end)

  fake.restore()
  vim.notify = old_notify
  if buf and vim.api.nvim_buf_is_valid(buf) then
    notebook.disable(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  if not ok then error(err, 0) end
end)

test('runs issued during kernel startup share one session and keep their order', function()
  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local old_notify = vim.notify
  local messages = {}
  local fake = fake_backend()
  local buf

  local ok, err = pcall(function()
    vim.notify = function(message) table.insert(messages, tostring(message)) end
    notebook.setup({ keymaps = false, auto_venv = false, backend_cmd = { 'fake-backend' } })
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'a = 1', '# %%', 'b = 2' })

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    exec.run_cell(buf)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    exec.run_cell(buf)
    -- Edits made while the kernel starts must not change what was run.
    vim.api.nvim_buf_set_lines(buf, 3, 4, false, { 'b = 3' })
    assert_eq(fake.count('open_py'), 1, 'a second run must not open another session')

    fake.reply('open_py', nil, { session_id = 's1' })
    assert_eq(fake.count('start_kernel'), 1, 'a second run must not start another kernel')
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    assert_eq(fake.count('update_cell_source'), 0, 'runs wait until the kernel setup code was sent')
    fake.reply('execute_silent', nil, { msg_id = 'setup' })
    assert_eq(fake.count('update_cell_source'), 1, 'one run is sent at a time')

    local first = fake.reply('update_cell_source', nil, { ok = true })
    assert_eq(first.params.source, 'a = 1')
    assert_eq(fake.count('update_cell_source'), 1, 'the next run waits for the execute reply')
    fake.reply('execute', nil, { msg_id = 'm1' })
    assert_eq(fake.count('update_cell_source'), 2, 'the next run is sent once the previous one reached the kernel')
    local second = fake.reply('update_cell_source', nil, { ok = true })
    assert_eq(second.params.source, 'b = 2', 'a run uses the source from when it was issued')
    local second_execute = fake.reply('execute', nil, { msg_id = 'm2' })
    assert_eq(second_execute.params.session_id, 's1')
    assert_true(first.params.cell_id ~= second.params.cell_id)
    assert_eq(fake.count('execute'), 2)
    assert_eq(#messages, 1, 'only the kernel start is announced: ' .. vim.inspect(messages))
  end)

  fake.restore()
  vim.notify = old_notify
  if buf and vim.api.nvim_buf_is_valid(buf) then
    notebook.disable(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  if not ok then error(err, 0) end
end)

test('a restart holds new runs for the new kernel and a failed start drops them', function()
  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local old_notify = vim.notify
  local messages = {}
  local fake = fake_backend()
  local buf

  local ok, err = pcall(function()
    vim.notify = function(message) table.insert(messages, tostring(message)) end
    notebook.setup({ keymaps = false, auto_venv = false, backend_cmd = { 'fake-backend' } })
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'x = 1' })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    exec.start_kernel(buf)
    fake.reply('open_py', nil, { session_id = 's1' })
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    fake.reply('execute_silent', nil, {})

    exec.restart_kernel(buf)
    exec.run_cell(buf)
    assert_eq(fake.count('update_cell_source'), 0, 'a run issued during a restart waits for the new kernel')
    fake.reply('stop_kernel', nil, { ok = true })
    assert_eq(fake.reply('start_kernel', nil, { kernel_name = 'python3' }).params.session_id, 's1')
    assert_eq(fake.count('update_cell_source'), 0)
    fake.reply('execute_silent', nil, {})
    fake.reply('update_cell_source', nil, { ok = true })
    fake.reply('execute', nil, {})

    exec.stop_kernel(buf)
    fake.reply('stop_kernel', nil, { ok = true })
    messages = {}
    exec.run_cell(buf)
    fake.reply('start_kernel', 'no kernelspec found', nil)
    assert_eq(fake.count('update_cell_source'), 1, 'runs must not be sent after a failed start')
    assert_true(#messages == 1 and messages[1]:find('start_kernel failed', 1, true) ~= nil, vim.inspect(messages))
    exec.run_cell(buf)
    assert_eq(fake.count('start_kernel'), 4, 'the next run starts the kernel again')
    assert_eq(fake.count('open_py'), 1, 'and reuses the session')
  end)

  fake.restore()
  vim.notify = old_notify
  if buf and vim.api.nvim_buf_is_valid(buf) then
    notebook.disable(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  if not ok then error(err, 0) end
end)

-- Fake-backend fixture for the run queue tests: a buffer with three cells
-- (a = 1, b = 2, c = 3) and `run(n)` running the n-th cell.
local function queue_fixture(fn)
  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local old_notify = vim.notify
  local messages = {}
  local fake = fake_backend()
  local buf

  local ok, err = pcall(function()
    vim.notify = function(message) table.insert(messages, tostring(message)) end
    notebook.setup({ keymaps = false, auto_venv = false, backend_cmd = { 'fake-backend' } })
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'a = 1', '# %%', 'b = 2', '# %%', 'c = 3' })
    local function run(n)
      vim.api.nvim_win_set_cursor(0, { 2 * n, 0 })
      exec.run_cell(buf)
    end
    local function start(session_id)
      exec.start_kernel(buf)
      fake.reply('open_py', nil, { session_id = session_id })
      fake.reply('start_kernel', nil, { kernel_name = 'python3' })
      fake.reply('execute_silent', nil, {})
    end
    fn({ exec = exec, fake = fake, buf = buf, run = run, start = start, messages = messages })
  end)

  fake.restore()
  vim.notify = old_notify
  if buf and vim.api.nvim_buf_is_valid(buf) then
    notebook.disable(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  if not ok then error(err, 0) end
end

local function assert_no_failures(messages)
  for _, message in ipairs(messages) do
    assert_true(not message:find('failed', 1, true), 'no request may fail: ' .. vim.inspect(messages))
  end
end

test('a stop waits for the run in flight and drops the runs not sent yet', function()
  queue_fixture(function(t)
    t.start('s1')
    t.run(1)
    t.run(2)
    t.exec.stop_kernel(t.buf)
    t.run(3)
    assert_eq(t.fake.count('stop_kernel'), 0, 'the stop waits for the run in flight')
    assert_eq(t.fake.count('update_cell_source'), 1, 'a run issued after the stop must not be sent alongside it')
    t.fake.reply('update_cell_source', nil, { ok = true })
    assert_eq(t.fake.count('execute'), 0, 'a run dropped by the stop must not go on to execute')
    assert_eq(t.fake.count('update_cell_source'), 1, 'nothing is sent while the kernel stops')
    t.fake.reply('stop_kernel', nil, { ok = true })
    -- The run issued during the stop starts a new kernel, as any run would.
    t.fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    t.fake.reply('execute_silent', nil, {})
    assert_eq(t.fake.reply('update_cell_source', nil, { ok = true }).params.source, 'c = 3', 'only the run issued after the stop is sent')
    t.fake.reply('execute', nil, {})
    assert_eq(t.fake.count('update_cell_source'), 2)
    assert_no_failures(t.messages)
  end)
end)

test('a restart lets the run in flight reach the old kernel first', function()
  queue_fixture(function(t)
    t.start('s1')
    t.run(1)
    t.exec.restart_kernel(t.buf)
    t.run(2)
    t.fake.reply('update_cell_source', nil, { ok = true })
    assert_eq(t.fake.count('stop_kernel'), 0, 'the restart waits for the run in flight')
    assert_eq(t.fake.reply('execute', nil, {}).params.session_id, 's1')
    t.fake.reply('stop_kernel', nil, { ok = true })
    t.fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    assert_eq(t.fake.count('update_cell_source'), 1, 'the run issued during the restart waits for the new kernel')
    t.fake.reply('execute_silent', nil, {})
    assert_eq(t.fake.reply('update_cell_source', nil, { ok = true }).params.source, 'b = 2')
    t.fake.reply('execute', nil, {})
    assert_eq(t.fake.count('execute'), 2)
    assert_no_failures(t.messages)
  end)
end)

test('stopping a kernel that is still starting drops the queued runs', function()
  queue_fixture(function(t)
    -- Before the session exists (open_py in flight).
    t.run(1)
    t.run(2)
    t.exec.stop_kernel(t.buf)
    t.fake.reply('open_py', nil, { session_id = 's1' })
    t.fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    t.fake.reply('execute_silent', nil, {})
    assert_eq(t.fake.count('update_cell_source'), 0, 'runs issued before the stop must not be sent')

    -- With a session, while start_kernel is in flight. The start itself is not
    -- cancelled, so no stop request is sent for it.
    t.exec.stop_kernel(t.buf)
    t.fake.reply('stop_kernel', nil, { ok = true })
    t.run(1)
    t.exec.stop_kernel(t.buf)
    t.fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    t.fake.reply('execute_silent', nil, {})
    assert_eq(t.fake.count('update_cell_source'), 0, 'a run issued before the stop must not be sent')
    assert_eq(t.fake.count('stop_kernel'), 1)
    local notices = vim.tbl_filter(function(message)
      return message:find('still starting, so it was not stopped', 1, true) ~= nil
    end, t.messages)
    assert_eq(#notices, 2, 'each stop during a start says what it did: ' .. vim.inspect(t.messages))
  end)
end)

test('a backend exit ends starts in flight and drops the runs waiting for them', function()
  queue_fixture(function(t)
    -- open_py in flight: the start has no session yet. A run issued after the
    -- exit was handled, but before the dead request's reply is read, must not
    -- join the dead start.
    t.run(1)
    t.fake.exit(nil, 9, { replies_after_exit = true })
    t.run(2)
    assert_eq(t.fake.count('open_py'), 2, 'a run after the exit must start again on a new backend')
    t.fake.reply('open_py', 'notebook-style-core exited', nil)
    t.fake.reply('open_py', nil, { session_id = 's2' })
    t.fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    t.fake.reply('execute_silent', nil, {})
    assert_eq(t.fake.reply('update_cell_source', nil, { ok = true }).params.source, 'b = 2', 'only the run issued after the exit is sent')
    t.fake.reply('execute', nil, {})

    -- start_kernel in flight on an existing session: the same.
    t.exec.stop_kernel(t.buf)
    t.fake.reply('stop_kernel', nil, { ok = true })
    t.run(1)
    t.fake.exit(nil, 9, { replies_after_exit = true })
    t.run(3)
    assert_eq(t.fake.count('open_py'), 3, 'a run after the exit must open a new session')
    t.fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    t.fake.reply('open_py', nil, { session_id = 's3' })
    assert_eq(t.fake.reply('start_kernel', nil, { kernel_name = 'python3' }).params.session_id, 's3')
    t.fake.reply('execute_silent', nil, {})
    assert_eq(t.fake.reply('update_cell_source', nil, { ok = true }).params.source, 'c = 3', 'runs queued before the exit are dropped')
    t.fake.reply('execute', nil, {})
    assert_eq(t.fake.count('update_cell_source'), 2)
  end)
end)

test('callers waiting for a restart or stop are called once a kernel serves them', function()
  queue_fixture(function(t)
    t.start('s1')
    local calls = 0
    local function waiter()
      calls = calls + 1
    end

    t.exec.restart_kernel(t.buf)
    t.exec.start_kernel(t.buf, waiter)
    t.fake.reply('stop_kernel', nil, { ok = true })
    t.fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    assert_eq(calls, 0, 'not before the new kernel is set up')
    t.fake.reply('execute_silent', nil, {})
    assert_eq(calls, 1, 'once the new kernel is up')

    t.exec.restart_kernel(t.buf)
    t.exec.start_kernel(t.buf, waiter)
    t.fake.reply('stop_kernel', 'stop failed', nil)
    assert_eq(calls, 2, 'at once when the old kernel keeps running')
    assert_eq(t.fake.count('start_kernel'), 2, 'no new kernel after a failed stop')

    t.exec.stop_kernel(t.buf)
    t.exec.start_kernel(t.buf, waiter)
    t.fake.reply('stop_kernel', nil, { ok = true })
    t.fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    t.fake.reply('execute_silent', nil, {})
    assert_eq(calls, 3, 'a start requested during a stop starts a new kernel')

    -- Also without a callback (:NotebookStyleKernelStart, or a restart).
    t.exec.stop_kernel(t.buf)
    t.exec.start_kernel(t.buf)
    t.fake.reply('stop_kernel', nil, { ok = true })
    assert_eq(t.fake.count('start_kernel'), 4, 'a start requested during a stop is not lost')
  end)
end)

test('a stop also drops the kernel starts requested since an earlier stop', function()
  queue_fixture(function(t)
    t.start('s1')
    -- Stop, run, stop again before the first stop is answered: the run is
    -- dropped and must not start a new kernel either.
    t.exec.stop_kernel(t.buf)
    t.run(1)
    t.exec.stop_kernel(t.buf)
    t.fake.reply('stop_kernel', nil, { ok = true })
    assert_eq(t.fake.count('start_kernel'), 1, 'the last stop wins: no new kernel')
    assert_eq(t.fake.count('update_cell_source'), 0)
    assert_eq(require('notebook_style.state').get(t.buf).kernel_started, false)

    -- The same while the first stop still waits for a run in flight.
    t.exec.start_kernel(t.buf)
    t.fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    t.fake.reply('execute_silent', nil, {})
    t.run(1)
    t.exec.stop_kernel(t.buf)
    t.run(2)
    t.exec.stop_kernel(t.buf)
    t.fake.reply('update_cell_source', nil, { ok = true })
    t.fake.reply('stop_kernel', nil, { ok = true })
    assert_eq(t.fake.count('start_kernel'), 2, 'the last stop wins while the first one waited: no new kernel')
    assert_eq(t.fake.count('execute'), 0)
    assert_eq(t.fake.count('update_cell_source'), 1)
    assert_eq(require('notebook_style.state').get(t.buf).kernel_started, false)

    -- The same for an explicit start between the stops.
    t.exec.start_kernel(t.buf)
    t.fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    t.fake.reply('execute_silent', nil, {})
    t.exec.stop_kernel(t.buf)
    t.exec.start_kernel(t.buf)
    t.exec.stop_kernel(t.buf)
    t.fake.reply('stop_kernel', nil, { ok = true })
    assert_eq(t.fake.count('start_kernel'), 3, 'the last stop wins over an earlier start request')

    -- Without the second stop, the run starts a new kernel and executes.
    t.exec.start_kernel(t.buf)
    t.fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    t.fake.reply('execute_silent', nil, {})
    t.exec.stop_kernel(t.buf)
    t.run(2)
    t.fake.reply('stop_kernel', nil, { ok = true })
    t.fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    t.fake.reply('execute_silent', nil, {})
    assert_eq(t.fake.reply('update_cell_source', nil, { ok = true }).params.source, 'b = 2')
  end)
end)

test('a backend exit during a stop or restart does not call the callers waiting for it', function()
  queue_fixture(function(t)
    t.start('s1')
    local calls = 0
    t.exec.restart_kernel(t.buf)
    t.exec.start_kernel(t.buf, function()
      calls = calls + 1
    end)
    t.run(1)
    -- The stop request fails because the backend died, before the exit is
    -- handled: no kernel serves the waiting callers or runs.
    t.fake.exit(nil, 9)
    assert_eq(calls, 0, 'callers must not be told a kernel is ready')
    assert_eq(#t.fake.calls_after_exit, 0, 'nothing may be sent to the exited backend')
    assert_eq(t.fake.count('update_cell_source'), 0)
  end)
end)

test('replies from an exited backend do not disturb the next backend', function()
  queue_fixture(function(t)
    -- Run 1 is in flight and a stop waits for it when the backend exits; its
    -- reply is read only after the next backend started runs 2 and 3.
    t.start('s1')
    t.run(1)
    t.exec.stop_kernel(t.buf)
    t.fake.exit(nil, 9, { replies_after_exit = true })
    t.run(2)
    t.run(3)
    t.fake.reply('open_py', nil, { session_id = 's2' })
    t.fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    t.fake.reply('execute_silent', nil, {})
    assert_eq(t.fake.count('update_cell_source'), 2, 'the exit must release the dead run in flight')

    local dead = t.fake.reply('update_cell_source', nil, { ok = true })
    assert_true(dead.client ~= t.fake.client, 'expected the reply of the exited backend')
    assert_eq(t.fake.count('update_cell_source'), 2, 'the dead reply must not release the live run in flight')
    assert_eq(#t.fake.calls_after_exit, 0, 'the dead stop must not be sent: ' .. vim.inspect(t.fake.calls_after_exit))
    assert_eq(t.fake.count('stop_kernel'), 0)

    assert_eq(t.fake.reply('update_cell_source', nil, { ok = true }).params.source, 'b = 2')
    t.fake.reply('execute', nil, {})
    assert_eq(t.fake.reply('update_cell_source', nil, { ok = true }).params.source, 'c = 3')
    t.fake.reply('execute', nil, {})
  end)
end)

test('a start cut short by a backend exit does not block later runs', function()
  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local old_notify = vim.notify
  local messages = {}
  local fake = fake_backend()
  local buf

  local ok, err = pcall(function()
    vim.notify = function(message) table.insert(messages, tostring(message)) end
    notebook.setup({ keymaps = false, auto_venv = false, backend_cmd = { 'fake-backend' } })
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'x = 1' })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    -- The backend exits while open_py is in flight, and the exit is handled
    -- before the request's failure (or a reply written just before dying) is
    -- read. A start in this phase has no session the exit reset could see.
    for _, late in ipairs({ { 'notebook-style-core exited', nil }, { nil, { session_id = 'dead' } } }) do
      exec.run_cell(buf)
      local opened = fake.count('open_py')
      fake.exit(nil, 9, { replies_after_exit = true })
      fake.reply('open_py', late[1], late[2])
      exec.run_cell(buf)
      assert_eq(fake.count('open_py'), opened + 1, 'a later run must start again instead of waiting for the dead start')
    end
    for _, message in ipairs(messages) do
      assert_true(message:find('execution backend exited', 1, true) ~= nil, 'only exit warnings expected: ' .. vim.inspect(messages))
    end
  end)

  fake.restore()
  vim.notify = old_notify
  if buf and vim.api.nvim_buf_is_valid(buf) then
    notebook.disable(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  if not ok then error(err, 0) end
end)

test('runs are dropped when the backend cannot be spawned', function()
  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local state = require('notebook_style.state')
  local rpc = require('notebook_style.rpc')
  local spawn = rpc.spawn
  local old_notify = vim.notify
  local buf
  local fake

  local ok, err = pcall(function()
    vim.notify = function() end
    notebook.setup({ keymaps = false, auto_venv = false, backend_cmd = { 'fake-backend' } })
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'x = 1' })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    rpc.spawn = function()
      error('notebook-style-core spawn failed: backend not installed', 0)
    end
    for _ = 1, 2 do
      local run_ok, run_err = pcall(exec.run_cell, buf)
      assert_true(not run_ok and tostring(run_err):find('spawn failed', 1, true) ~= nil, tostring(run_err))
    end
    assert_eq(state.get(buf).run_queue, nil, 'failed runs must not stay queued')
    rpc.spawn = spawn

    -- Once a backend exists, only the new run executes.
    fake = fake_backend()
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'x = 2' })
    exec.run_cell(buf)
    fake.reply('open_py', nil, { session_id = 's1' })
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    fake.reply('execute_silent', nil, {})
    assert_eq(fake.reply('update_cell_source', nil, { ok = true }).params.source, 'x = 2')
    fake.reply('execute', nil, {})
    assert_eq(fake.count('update_cell_source'), 1)
  end)

  rpc.spawn = spawn
  if fake then fake.restore() end
  vim.notify = old_notify
  if buf and vim.api.nvim_buf_is_valid(buf) then
    notebook.disable(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  if not ok then error(err, 0) end
end)

test('a kernel that fails to start is reported instead of hanging', function()
  local backend = backend_path()
  if vim.fn.executable(backend) ~= 1 then
    skip_now('backend binary not executable: ' .. backend)
  end

  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local state = require('notebook_style.state')
  local project = vim.fn.tempname()
  local old_notify = vim.notify
  local old_jupyter_path = vim.env.JUPYTER_PATH
  local messages = {}
  local buf

  local ok, err = pcall(function()
    -- A "kernel" that dies at once, like a kernelspec whose python lacks ipykernel.
    assert_eq(vim.fn.mkdir(project .. '/kernels/broken', 'p'), 1)
    vim.fn.writefile({ vim.fn.json_encode({
      argv = { 'sh', '-c', 'echo "kernel-start-marker: No module named ipykernel_launcher" >&2; exit 3' },
      display_name = 'Broken kernel', language = 'python',
    }) }, project .. '/kernels/broken/kernel.json')
    vim.env.JUPYTER_PATH = project
    close_backends()
    vim.notify = function(message) table.insert(messages, tostring(message)) end
    notebook.setup({ keymaps = false, backend_cmd = { backend }, auto_venv = false, kernel_name = 'broken' })
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'print(1)' })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    local function failures()
      return vim.tbl_filter(function(message)
        return message:find('start_kernel failed', 1, true) ~= nil
      end, messages)
    end
    exec.run_cell(buf)
    assert_true(vim.wait(10000, function() return #failures() == 1 end, 10), 'the failed start was not reported: ' .. vim.inspect(messages))
    local failure = failures()[1]
    assert_true(failure:find('exited during startup', 1, true) ~= nil, failure)
    assert_true(failure:find('kernel-start-marker: No module named ipykernel_launcher', 1, true) ~= nil, 'the kernel stderr must be shown: ' .. failure)
    assert_eq(state.get(buf).kernel_started, false)

    exec.run_cell(buf)
    assert_true(vim.wait(10000, function() return #failures() == 2 end, 10), 'a later run must try again: ' .. vim.inspect(messages))
  end)

  vim.notify = old_notify
  if buf and vim.api.nvim_buf_is_valid(buf) then
    notebook.disable(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  close_backends()
  vim.env.JUPYTER_PATH = old_jupyter_path
  vim.fn.delete(project, 'rf')
  if not ok then error(err, 0) end
end)

test('deleting or disabling a buffer closes its backend session', function()
  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local old_notify = vim.notify
  local fake = fake_backend()
  local bufs = {}

  local function python_buffer()
    local buf = vim.api.nvim_create_buf(true, true)
    table.insert(bufs, buf)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'x = 1' })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    return buf
  end

  local ok, err = pcall(function()
    vim.notify = function() end
    notebook.setup({ keymaps = false, auto_venv = false, backend_cmd = { 'fake-backend' } })

    -- :NotebookStyleDisable on a buffer with a running kernel.
    local buf = python_buffer()
    exec.start_kernel(buf)
    fake.reply('open_py', nil, { session_id = 's1' })
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    fake.reply('execute_silent', nil, {})
    notebook.disable(buf)
    assert_eq(fake.reply('close', nil, { ok = true }).params.session_id, 's1')
    notebook.enable(buf)
    exec.run_cell(buf)
    assert_eq(fake.count('open_py'), 2, 'enabling again starts from a new session, as before')

    -- Deleted while its kernel is still launching: the session is closed once
    -- the launch completes, and the queued run is not sent.
    fake.reply('open_py', nil, { session_id = 's2' })
    vim.api.nvim_buf_delete(buf, { force = true })
    assert_eq(fake.count('close'), 1, 'no close while the kernel is launching')
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    assert_eq(fake.reply('close', nil, { ok = true }).params.session_id, 's2')
    assert_eq(fake.count('update_cell_source'), 0, 'the deleted buffer run must not be sent')
    assert_eq(fake.count('execute_silent'), 1)

    -- Deleted before the backend even opened its session.
    buf = python_buffer()
    exec.run_cell(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    fake.reply('open_py', nil, { session_id = 's3' })
    assert_eq(fake.reply('close', nil, { ok = true }).params.session_id, 's3')
    assert_eq(fake.count('start_kernel'), 2, 'no kernel is started for a deleted buffer')

    -- Disabled while a restart stops the old kernel: no launch is in flight,
    -- so the session is closed at once, and no new kernel is started.
    buf = python_buffer()
    exec.start_kernel(buf)
    fake.reply('open_py', nil, { session_id = 's4' })
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    fake.reply('execute_silent', nil, {})
    exec.restart_kernel(buf)
    notebook.disable(buf)
    assert_eq(fake.reply('close', nil, { ok = true }).params.session_id, 's4')
    fake.reply('stop_kernel', nil, { ok = true })
    assert_eq(fake.count('start_kernel'), 3, 'no kernel is started after the buffer was disabled')

    -- Disabled after the kernel started but before its setup request was
    -- answered: the launch is over, so the session is closed at once.
    buf = python_buffer()
    exec.run_cell(buf)
    fake.reply('open_py', nil, { session_id = 's5' })
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    notebook.disable(buf)
    assert_eq(fake.reply('close', nil, { ok = true }).params.session_id, 's5')
    fake.reply('execute_silent', nil, {})
    assert_eq(fake.count('update_cell_source'), 0, 'the disabled buffer run must not be sent')

    -- Disabled while a run is in flight: the session is closed at once, and
    -- the run does not go on to execute.
    buf = python_buffer()
    exec.start_kernel(buf)
    fake.reply('open_py', nil, { session_id = 's6' })
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    fake.reply('execute_silent', nil, {})
    exec.run_cell(buf)
    notebook.disable(buf)
    assert_eq(fake.reply('close', nil, { ok = true }).params.session_id, 's6')
    fake.reply('update_cell_source', nil, { ok = true })
    assert_eq(fake.count('execute'), 0, 'the run in flight must not go on to execute')

    -- Disabled while a stop waits for the run in flight: the session is
    -- closed at once, and the stop is not sent afterwards.
    buf = python_buffer()
    exec.start_kernel(buf)
    fake.reply('open_py', nil, { session_id = 's7' })
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    fake.reply('execute_silent', nil, {})
    exec.run_cell(buf)
    exec.stop_kernel(buf)
    notebook.disable(buf)
    assert_eq(fake.reply('close', nil, { ok = true }).params.session_id, 's7')
    fake.reply('update_cell_source', nil, { ok = true })
    assert_eq(fake.count('stop_kernel'), 1, 'no stop is sent for the disabled buffer')
    assert_eq(fake.count('execute'), 0)
  end)

  fake.restore()
  vim.notify = old_notify
  for _, buf in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      notebook.disable(buf)
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  if not ok then error(err, 0) end
end)

test('wiping an unlisted buffer also closes its backend session', function()
  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local state = require('notebook_style.state')
  local old_notify = vim.notify
  local messages = {}
  local fake = fake_backend()
  local bufs = {}

  -- Unlisted, like a plugin's scratch buffer: wiping it fires BufWipeout but
  -- no BufDelete.
  local function scratch_buffer()
    local buf = vim.api.nvim_create_buf(false, true)
    table.insert(bufs, buf)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'x = 1' })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    return buf
  end
  local function has_state(buf)
    for b in state.each() do
      if b == buf then
        return true
      end
    end
    return false
  end

  local ok, err = pcall(function()
    vim.notify = function(message) table.insert(messages, tostring(message)) end
    notebook.setup({ keymaps = false, auto_venv = false, backend_cmd = { 'fake-backend' } })

    -- With a running kernel.
    local buf = scratch_buffer()
    assert_true(notebook.enabled_buffers[buf], 'FileType enables the unlisted buffer')
    exec.start_kernel(buf)
    fake.reply('open_py', nil, { session_id = 'u1' })
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    fake.reply('execute_silent', nil, {})
    vim.api.nvim_buf_delete(buf, { force = true })
    assert_eq(fake.reply('close', nil, { ok = true }).params.session_id, 'u1')
    assert_true(not has_state(buf), 'the wiped buffer leaves no state')
    -- A late event for the closed session must not bring the state back.
    fake.client.handlers.cell_event({ session_id = 'u1', cell_id = 'cell-late', event = { kind = 'stream', name = 'stdout', text = 'late\n' } })
    assert_true(not has_state(buf), 'a late event must not recreate the state of a wiped buffer')

    -- Wiped before its session was opened: the session it gets is closed.
    buf = scratch_buffer()
    exec.run_cell(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    fake.reply('open_py', nil, { session_id = 'u2' })
    assert_eq(fake.reply('close', nil, { ok = true }).params.session_id, 'u2')

    -- Wiped while its kernel launches: closed once the launch completes.
    buf = scratch_buffer()
    exec.run_cell(buf)
    fake.reply('open_py', nil, { session_id = 'u3' })
    vim.api.nvim_buf_delete(buf, { force = true })
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    assert_eq(fake.reply('close', nil, { ok = true }).params.session_id, 'u3')
    assert_eq(fake.count('start_kernel'), 2, 'no kernel is started for a wiped buffer')
    assert_eq(fake.count('update_cell_source'), 0, 'no run of a wiped buffer may be sent')
    assert_eq(fake.count('execute'), 0)

    -- A failed open_py for a buffer that is gone is not reported.
    buf = scratch_buffer()
    exec.run_cell(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    messages = {}
    fake.reply('open_py', 'open_py failed on purpose', nil)
    assert_eq(#messages, 0, 'nobody waits for this start: ' .. vim.inspect(messages))
  end)

  fake.restore()
  vim.notify = old_notify
  for _, b in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(b) then
      pcall(notebook.disable, b)
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    state.clear(b)
  end
  if not ok then error(err, 0) end
end)

test(':bdelete closes the session of a listed buffer; an unlisted one is only unloaded', function()
  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local state = require('notebook_style.state')
  local old_notify = vim.notify
  local fake = fake_backend()
  local bufs = {}

  local function python_buffer(listed)
    local buf = vim.api.nvim_create_buf(listed, not listed)
    table.insert(bufs, buf)
    if listed then
      vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. '.py')
    end
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'x = 1' })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    return buf
  end

  local ok, err = pcall(function()
    vim.notify = function() end
    notebook.setup({ keymaps = false, auto_venv = false, backend_cmd = { 'fake-backend' } })

    -- A listed buffer deleted with :bdelete! while its kernel launches: the
    -- session is closed once the launch completes and the run is not sent.
    local buf = python_buffer(true)
    exec.run_cell(buf)
    fake.reply('open_py', nil, { session_id = 'l1' })
    vim.cmd('bdelete! ' .. buf)
    assert_eq(fake.count('close'), 0, 'no close while the kernel launches')
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    assert_eq(fake.reply('close', nil, { ok = true }).params.session_id, 'l1')
    assert_eq(fake.count('update_cell_source'), 0, 'the run of a deleted buffer is not sent')

    -- :bdelete! on an unlisted buffer only unloads it: like any unloaded
    -- buffer it keeps its kernel (documented).
    buf = python_buffer(false)
    exec.start_kernel(buf)
    fake.reply('open_py', nil, { session_id = 'u1' })
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    fake.reply('execute_silent', nil, {})
    vim.cmd('bdelete! ' .. buf)
    assert_true(vim.api.nvim_buf_is_valid(buf), 'the unlisted buffer still exists')
    assert_eq(fake.count('close'), 1, 'an unloaded buffer keeps its kernel')
    assert_true(notebook.enabled_buffers[buf], 'and stays enabled')
  end)

  fake.restore()
  vim.notify = old_notify
  for _, b in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(b) then
      pcall(notebook.disable, b)
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    state.clear(b)
  end
  if not ok then error(err, 0) end
end)

test('deleting a buffer stops its real kernel process', function()
  local backend = backend_path()
  local python = vim.fn.exepath('python3')
  if vim.fn.executable(backend) ~= 1 or python == '' or not python_imports_ipykernel(python) then
    skip_now('requires the backend and python3 with ipykernel')
  end

  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local state = require('notebook_style.state')
  local cells = require('notebook_style.cells')
  local config = require('notebook_style.config')
  local project = vim.fn.tempname()
  local old_notify = vim.notify
  local old_jupyter_path = vim.env.JUPYTER_PATH
  local messages = {}
  local buf

  local ok, err = pcall(function()
    assert_eq(vim.fn.mkdir(project .. '/kernels/notebook-style-smoke', 'p'), 1)
    vim.fn.writefile({ vim.fn.json_encode({
      argv = { python, '-m', 'ipykernel_launcher', '-f', '{connection_file}' },
      display_name = 'NotebookStyle smoke test', language = 'python',
    }) }, project .. '/kernels/notebook-style-smoke/kernel.json')
    vim.env.JUPYTER_PATH = project
    close_backends()
    vim.notify = function(message) table.insert(messages, tostring(message)) end
    notebook.setup({ keymaps = false, backend_cmd = { backend }, auto_venv = false, kernel_name = 'notebook-style-smoke' })
    vim.fn.writefile({ '# %%', 'print("alive")' }, project .. '/sample.py')
    vim.cmd('edit ' .. vim.fn.fnameescape(project .. '/sample.py'))
    buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].filetype = 'python' -- -u NONE has no filetype detection
    assert_true(notebook.enabled_buffers[buf], 'the plugin must be enabled for the buffer')
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    exec.run_cell(buf)
    assert_true(vim.wait(20000, function()
      local cell = cells.get_cells(buf, cells.find_delimiters(buf, config.options.cell_delimiter), 2)[1]
      local outputs = state.outputs(buf, cell)
      return outputs[1] and outputs[1].text == 'alive\n'
    end, 10), 'run failed: ' .. vim.inspect(messages))

    local backend = backends[#backends]
    local kernel_pid = vim.trim(vim.fn.system({ 'pgrep', '-P', tostring(backend.pid) }))
    assert_true(kernel_pid:match('^%d+$') ~= nil, 'expected one kernel process, got: ' .. kernel_pid)
    vim.cmd('bdelete! ' .. buf)
    buf = nil
    assert_true(vim.wait(5000, function() return not process_alive(kernel_pid) end, 50), 'the kernel outlived its buffer')
    assert_true(not backend.exit_handled, 'the backend itself must keep running')
  end)

  vim.notify = old_notify
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(exec.stop_kernel, buf)
    vim.wait(5000, function() return not state.get(buf).kernel_started end, 10)
    pcall(notebook.disable, buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  local closed, close_err = pcall(close_backends)
  vim.env.JUPYTER_PATH = old_jupyter_path
  vim.fn.delete(project, 'rf')
  if not ok then error(err, 0) end
  if not closed then error(close_err, 0) end
end)

test('deleting a buffer while its real kernel launches stops that kernel', function()
  local backend = backend_path()
  local python = vim.fn.exepath('python3')
  if vim.fn.executable(backend) ~= 1 or python == '' or not python_imports_ipykernel(python) then
    skip_now('requires the backend and python3 with ipykernel')
  end

  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local state = require('notebook_style.state')
  local project = vim.fn.tempname()
  local old_notify = vim.notify
  local old_jupyter_path = vim.env.JUPYTER_PATH
  local buf

  local gate = project .. '/gate'

  local ok, err = pcall(function()
    assert_eq(vim.fn.mkdir(project .. '/kernels/notebook-style-smoke', 'p'), 1)
    -- The kernel waits for a gate file before it starts, so the buffer is
    -- certainly deleted while start_kernel is still in flight.
    vim.fn.writefile({ vim.fn.json_encode({
      argv = {
        'sh', '-c', 'while [ ! -e "$1" ]; do sleep 0.05; done; exec "$2" -m ipykernel_launcher -f "$3"',
        'sh', gate, python, '{connection_file}',
      },
      display_name = 'NotebookStyle smoke test', language = 'python',
    }) }, project .. '/kernels/notebook-style-smoke/kernel.json')
    vim.env.JUPYTER_PATH = project
    close_backends()
    vim.notify = function() end
    notebook.setup({ keymaps = false, backend_cmd = { backend }, auto_venv = false, kernel_name = 'notebook-style-smoke' })
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'print("never")' })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    exec.run_cell(buf)

    local client = backends[#backends]
    local kernel_pid
    assert_true(vim.wait(20000, function()
      local start = state.get(buf).starting
      if not (start and start.launching) then
        return false
      end
      kernel_pid = vim.trim(vim.fn.system({ 'pgrep', '-P', tostring(client.pid) }))
      return kernel_pid:match('^%d+$') ~= nil
    end, 10), 'did not see the kernel launching')
    vim.api.nvim_buf_delete(buf, { force = true })
    buf = nil
    -- Let the kernel start (the wrapper execs it, keeping its pid). Its
    -- session is closed once the launch completes, which kills it.
    vim.fn.writefile({}, gate)
    assert_true(vim.wait(20000, function() return not process_alive(kernel_pid) end, 50), 'the kernel launched for a deleted buffer kept running')
    assert_true(not client.exit_handled, 'the backend itself must keep running')
  end)

  vim.fn.writefile({}, gate)

  vim.notify = old_notify
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(notebook.disable, buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  local closed, close_err = pcall(close_backends)
  vim.env.JUPYTER_PATH = old_jupyter_path
  vim.fn.delete(project, 'rf')
  if not ok then error(err, 0) end
  if not closed then error(close_err, 0) end
end)

test('rapid runs reach a real kernel once each and in order', function()
  local backend = backend_path()
  local python = vim.fn.exepath('python3')
  if vim.fn.executable(backend) ~= 1 or python == '' or not python_imports_ipykernel(python) then
    skip_now('requires the backend and python3 with ipykernel')
  end

  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local state = require('notebook_style.state')
  local cells = require('notebook_style.cells')
  local config = require('notebook_style.config')
  local project = vim.fn.tempname()
  local old_notify = vim.notify
  local old_jupyter_path = vim.env.JUPYTER_PATH
  local messages = {}
  local buf

  local ok, err = pcall(function()
    assert_eq(vim.fn.mkdir(project .. '/kernels/notebook-style-smoke', 'p'), 1)
    vim.fn.writefile({ vim.fn.json_encode({
      argv = { python, '-m', 'ipykernel_launcher', '-f', '{connection_file}' },
      display_name = 'NotebookStyle smoke test', language = 'python',
    }) }, project .. '/kernels/notebook-style-smoke/kernel.json')
    vim.env.JUPYTER_PATH = project
    close_backends()
    vim.notify = function(message) table.insert(messages, tostring(message)) end
    notebook.setup({ keymaps = false, backend_cmd = { backend }, auto_venv = false, kernel_name = 'notebook-style-smoke' })
    vim.fn.writefile({
      '# %%', 'seen = []',
      '# %%', 'seen.append("A")',
      '# %%', 'seen.append("B")',
      '# %%', 'seen.append("C")',
      '# %%', 'print("".join(seen))',
    }, project .. '/order.py')
    vim.cmd('edit ' .. vim.fn.fnameescape(project .. '/order.py'))
    buf = vim.api.nvim_get_current_buf()
    local function printed()
      local list = cells.get_cells(buf, cells.find_delimiters(buf, config.options.cell_delimiter), 10)
      local outputs = state.outputs(buf, list[5])
      return outputs[1] and outputs[1].text
    end
    local function run_all_cells(first)
      for line = first, 10, 2 do
        vim.api.nvim_win_set_cursor(0, { line, 0 })
        exec.run_cell(buf)
      end
    end

    -- Issued back to back before the kernel exists, then again on a running kernel.
    run_all_cells(2)
    assert_true(vim.wait(20000, function() return printed() ~= nil end, 10), 'runs did not finish: ' .. vim.inspect(messages))
    assert_eq(printed(), 'ABC\n', 'runs must execute once each, in order')
    local kernels = vim.split(vim.trim(vim.fn.system({ 'pgrep', '-P', tostring(backends[#backends].pid) })), '\n', { trimempty = true })
    assert_eq(#kernels, 1, 'one kernel per buffer')
    run_all_cells(4)
    assert_true(vim.wait(20000, function() return printed() == 'ABCABC\n' end, 10), 'second round: ' .. vim.inspect(printed()))
    assert_eq(#messages, 1, 'only the kernel start is announced: ' .. vim.inspect(messages))
  end)

  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(exec.stop_kernel, buf)
    vim.wait(5000, function() return not state.get(buf).kernel_started end, 10)
    notebook.disable(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  vim.notify = old_notify
  close_backends()
  vim.env.JUPYTER_PATH = old_jupyter_path
  vim.fn.delete(project, 'rf')
  if not ok then error(err, 0) end
end)

test('a backend exit with requests in flight notifies once and ignores late replies', function()
  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local state = require('notebook_style.state')
  local old_notify = vim.notify
  local messages = {}
  local fake = fake_backend()
  local buf

  local ok, err = pcall(function()
    vim.notify = function(message) table.insert(messages, tostring(message)) end
    notebook.setup({ keymaps = false, auto_venv = false, backend_cmd = { 'fake-backend' } })
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'x = 1' })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local function only_exit_notification(context)
      assert_eq(#messages, 1, context .. ': ' .. vim.inspect(messages))
      assert_true(messages[1]:find('execution backend exited', 1, true) ~= nil, messages[1])
      messages = {}
    end

    -- The backend dies while start_kernel is in flight.
    exec.run_cell(buf)
    fake.reply('open_py', nil, { session_id = 's1' })
    messages = {}
    fake.exit(nil, 9)
    only_exit_notification('exit during start_kernel')

    -- The backend dies while stop_kernel is in flight: no "kernel stopped".
    exec.start_kernel(buf)
    fake.reply('open_py', nil, { session_id = 's2' })
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    exec.stop_kernel(buf)
    messages = {}
    fake.exit(nil, 9)
    only_exit_notification('exit during stop_kernel')

    -- Replies the backend wrote just before dying can be read after the exit
    -- was handled. They must not attach the buffer to the dead session.
    exec.run_cell(buf)
    local dead_client = fake.client
    fake.exit(nil, 9, { replies_after_exit = true })
    only_exit_notification('exit before the open_py reply was read')
    fake.reply('open_py', nil, { session_id = 'dead' })
    assert_eq(state.get(buf).session_id, nil, 'a late open_py reply must be ignored')
    dead_client.handlers.cell_event({ session_id = 'dead', cell_id = 'x', event = { kind = 'stream', name = 'stdout', text = 'late' } })
    local opened = fake.count('open_py')
    exec.run_cell(buf)
    assert_eq(fake.count('open_py'), opened + 1, 'the next run must open a new session')

    fake.reply('open_py', nil, { session_id = 's4' })
    fake.exit(nil, 9, { replies_after_exit = true })
    only_exit_notification('exit before the start_kernel reply was read')
    fake.reply('start_kernel', nil, { kernel_name = 'python3' })
    assert_eq(state.get(buf).kernel_started, false, 'a late start_kernel reply must be ignored')
    assert_eq(#messages, 0, 'a late reply must not announce a started kernel: ' .. vim.inspect(messages))
    assert_eq(fake.count('execute_silent'), 1, 'no setup request for the dead backend')
  end)

  fake.restore()
  vim.notify = old_notify
  if buf and vim.api.nvim_buf_is_valid(buf) then
    notebook.disable(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  if not ok then error(err, 0) end
end)

test('replies read after a backend exit do not trigger follow-up requests or messages', function()
  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local old_notify = vim.notify
  local messages = {}
  local fake = fake_backend()
  local buf

  local ok, err = pcall(function()
    vim.notify = function(message) table.insert(messages, tostring(message)) end
    notebook.setup({ keymaps = false, auto_venv = false, backend_cmd = { 'fake-backend' } })
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = 'python'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'a = 1', '# %%', 'b = 2' })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local function start_kernel(session_id)
      exec.start_kernel(buf)
      fake.reply('open_py', nil, { session_id = session_id })
      fake.reply('start_kernel', nil, { kernel_name = 'python3' })
      fake.reply('execute_silent', nil, {})
    end
    -- The backend exits and the exit is handled before `method`'s reply is read.
    local function late_reply(method, result)
      local clients, calls, dead_calls = #fake.clients, #fake.calls, #fake.calls_after_exit
      fake.exit(nil, 9, { replies_after_exit = true })
      messages = {}
      fake.reply(method, nil, result)
      assert_eq(#fake.clients, clients, method .. ': a late reply must not spawn a backend')
      assert_eq(#fake.calls, calls, method .. ': a late reply must not send requests: ' .. vim.inspect(fake.methods()))
      assert_eq(#fake.calls_after_exit, dead_calls,
        method .. ': a late reply must not send requests to the dead backend: ' .. vim.inspect(fake.calls_after_exit))
      assert_eq(#messages, 0, method .. ': a late reply must not notify: ' .. vim.inspect(messages))
    end

    start_kernel('s0')
    exec.run_file(buf)
    late_reply('update_cell_source', { ok = true }) -- must not send execute

    start_kernel('s1')
    exec.run_file(buf)
    fake.reply('update_cell_source', nil, { ok = true })
    late_reply('execute', { msg_id = 'm1' }) -- must not send the next cell

    start_kernel('s2')
    exec.stop_kernel(buf)
    late_reply('stop_kernel', { ok = true }) -- must not say "kernel stopped"

    start_kernel('s3')
    exec.interrupt_kernel(buf)
    late_reply('interrupt_kernel', { ok = true }) -- must not say "kernel interrupted"

    start_kernel('s4')
    exec.restart_kernel(buf)
    late_reply('stop_kernel', { ok = true }) -- must not start a kernel on a new backend
  end)

  fake.restore()
  vim.notify = old_notify
  if buf and vim.api.nvim_buf_is_valid(buf) then
    notebook.disable(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  if not ok then error(err, 0) end
end)

test('a killed backend is replaced and the buffer keeps executing', function()
  local backend = backend_path()
  local python = vim.fn.exepath('python3')
  if vim.fn.executable(backend) ~= 1 or python == '' or not python_imports_ipykernel(python) then
    skip_now('requires the backend and python3 with ipykernel')
  end

  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local state = require('notebook_style.state')
  local cells = require('notebook_style.cells')
  local config = require('notebook_style.config')
  local project = vim.fn.tempname()
  local old_notify = vim.notify
  local old_jupyter_path = vim.env.JUPYTER_PATH
  local messages, orphans = {}, {}
  local buf

  local ok, err = pcall(function()
    assert_eq(vim.fn.mkdir(project .. '/kernels/notebook-style-smoke', 'p'), 1)
    vim.fn.writefile({ vim.fn.json_encode({
      argv = { python, '-m', 'ipykernel_launcher', '-f', '{connection_file}' },
      display_name = 'NotebookStyle smoke test', language = 'python',
    }) }, project .. '/kernels/notebook-style-smoke/kernel.json')
    vim.env.JUPYTER_PATH = project
    close_backends()
    vim.notify = function(message) table.insert(messages, tostring(message)) end
    notebook.setup({ keymaps = false, backend_cmd = { backend }, auto_venv = false, kernel_name = 'notebook-style-smoke' })
    vim.fn.writefile({ '# %%', 'print("one")', '# %%', 'print("two")' }, project .. '/sample.py')
    vim.cmd('edit ' .. vim.fn.fnameescape(project .. '/sample.py'))
    buf = vim.api.nvim_get_current_buf()
    local function output(index)
      local list = cells.get_cells(buf, cells.find_delimiters(buf, config.options.cell_delimiter), 4)
      local outputs = state.outputs(buf, list[index])
      return outputs[1] and outputs[1].text
    end

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    exec.run_cell(buf)
    assert_true(vim.wait(20000, function() return output(1) == 'one\n' end, 10), 'first run failed: ' .. vim.inspect(messages))
    local first = backends[#backends]
    orphans = vim.split(vim.trim(vim.fn.system({ 'pgrep', '-P', tostring(first.pid) })), '\n', { trimempty = true })
    assert_eq(#orphans, 1)
    vim.fn.system({ 'kill', '-9', tostring(first.pid) })
    assert_true(vim.wait(5000, function() return state.get(buf).session_id == nil end, 10), 'backend exit was not handled')
    -- SIGKILL skips the backend's own cleanup; the kernel must notice that its
    -- parent is gone (JPY_PARENT_PID, polled every second) and exit.
    assert_true(vim.wait(5000, function() return process_exited(orphans[1]) end, 100),
      'the kernel of the killed backend kept running')

    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    exec.run_cell(buf)
    assert_true(vim.wait(20000, function() return output(2) == 'two\n' end, 10), 'run after backend loss failed: ' .. vim.inspect(messages))
    assert_true(backends[#backends] ~= first, 'a new backend must serve the new session')
  end)

  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(exec.stop_kernel, buf)
    vim.wait(5000, function() return not state.get(buf).kernel_started end, 10)
    notebook.disable(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  for _, pid in ipairs(orphans) do
    vim.fn.system({ 'kill', pid })
  end
  vim.notify = old_notify
  close_backends()
  vim.env.JUPYTER_PATH = old_jupyter_path
  vim.fn.delete(project, 'rf')
  if not ok then error(err, 0) end
end)

test('plain files execute silently, stream output and plot through the existing kernel', function()
  local backend = backend_path()
  local python = vim.fn.exepath('python3')
  if vim.fn.executable(backend) ~= 1 or python == '' or not python_imports_ipykernel(python) then
    skip_now('requires the backend and python3 with ipykernel')
  end
  vim.fn.system({ python, '-c', 'import matplotlib' })
  if vim.v.shell_error ~= 0 then skip_now('python3 cannot import matplotlib') end

  local notebook = require('notebook_style')
  local exec = require('notebook_style.exec')
  local cells = require('notebook_style.cells')
  local state = require('notebook_style.state')
  local render = require('notebook_style.render')
  local image = require('notebook_style.image')
  local output_view = require('notebook_style.output_view')
  local project = vim.fn.tempname()
  local old_notify, old_event, old_supported = vim.notify, state.apply_event, image.supported
  local old_jupyter_path = vim.env.JUPYTER_PATH
  local messages = {}
  local idle, replies = 0, 0
  local buf

  local ok, err = pcall(function()
    assert_eq(vim.fn.mkdir(project .. '/kernels/notebook-style-smoke', 'p'), 1)
    vim.fn.writefile({ vim.fn.json_encode({
      argv = { python, '-m', 'ipykernel_launcher', '-f', '{connection_file}' },
      display_name = 'NotebookStyle smoke test', language = 'python',
    }) }, project .. '/kernels/notebook-style-smoke/kernel.json')
    -- Link the environment directory, not just its binary, so venv-installed
    -- packages remain discoverable without registering any user kernelspec.
    local prefix = vim.trim(vim.fn.system({ python, '-c', 'import sys; print(sys.prefix)' }))
    assert_true(vim.loop.fs_symlink(prefix, project .. '/.venv', { dir = true }))
    vim.env.JUPYTER_PATH = project
    vim.notify = function(message) table.insert(messages, tostring(message)) end
    image.supported = function() return false end
    state.apply_event = function(target_buf, id, event)
      local output = old_event(target_buf, id, event)
      if target_buf == buf then
        if event.kind == 'status' and event.state == 'idle' then idle = idle + 1 end
        if event.kind == 'execute_reply' then replies = replies + 1 end
      end
      return output
    end

    for _, auto_venv in ipairs({ true, false }) do
      notebook.setup({
        keymaps = false, backend_cmd = { backend }, auto_venv = auto_venv,
        kernel_name = 'notebook-style-smoke',
      })
      local path = project .. "/quote '中文.py"
      vim.fn.writefile({ 'raise RuntimeError("disk content must not execute")' }, path)
      buf = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(buf, path)
      vim.api.nvim_set_current_buf(buf)
      vim.bo[buf].filetype = 'python'
      local function file_cell()
        return cells.get_cells(buf, {}, vim.api.nvim_buf_line_count(buf))[1]
      end
      local function marks()
        return vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })
      end
      local function text()
        return table.concat(output_view.format_outputs(state.outputs(buf, file_cell())), '\n')
      end
      local function run(lines, command, during)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_win_set_cursor(0, { #lines, 0 })
        local next_idle, next_reply = idle + 1, replies + 1
        vim.cmd(command or 'NotebookStyleRunFile')
        if during then during() end
        assert_true(vim.wait(20000, function()
          return idle >= next_idle and replies >= next_reply and not notebook.pending_updates[buf]
        end, 10), 'kernel execution did not finish; messages=' .. vim.inspect(messages))
      end

      run({ 'import math', 'seed = 17', 'seed + 100' }, 'NotebookStyleRunCell')
      assert_eq(text(), '', 'bare expressions must not echo')
      assert_eq(#marks(), 0, 'a silent execution must leave no output frame')
      assert_eq(#messages, 0, 'automatic kernel startup must be quiet')
      local session = state.get(buf).session_id

      local previous_idle = idle
      run({
        'print("first", flush=True)', 'import time; time.sleep(1)',
        'print(math.sqrt(81) + seed)', '999', '',
      }, 'NotebookStyleRunFile', function()
        assert_true(vim.wait(10000, function()
          return text() == 'first' and #marks() > 0
        end, 10), 'stdout must render before execution completes')
        assert_eq(idle, previous_idle, 'streaming should not wait for idle')
        assert_eq(marks()[1][2], 4, 'streamed output must be below trailing blank lines')
      end)
      assert_eq(text(), 'first\n26.0', 'imports and variables must persist across commands')
      assert_eq(state.get(buf).session_id, session, 'file commands must reuse the existing session')

      run({ 'print("quote: \' / \\\\ 中文")' }, 'NotebookStyleRunCell')
      assert_eq(text(), "quote: ' / \\ 中文", 'one-line sources must preserve quoting and Unicode')
      run({ 'from IPython.display import display', 'display("explicit result")' })
      assert_eq(text(), "'explicit result'", 'explicit display must not be silenced')
      run({ 'import sys; print("stderr marker", file=sys.stderr)', 'raise ValueError("failure marker")' })
      local outputs = state.outputs(buf, file_cell())
      assert_eq(outputs[1].name, 'stderr')
      assert_eq(outputs[2].output_type, 'error')
      assert_eq(outputs[2].ename, 'ValueError')
      assert_eq(outputs[2].evalue, 'failure marker')
      assert_true(text():find(path, 1, true) ~= nil, 'tracebacks should name the source file')

      run({ 'import matplotlib.pyplot as plt', 'plt.plot([0, 2, 5], [3, 1, 4])' })
      outputs = state.outputs(buf, file_cell())
      assert_eq(#outputs, 1, 'plot expression repr should not accompany the image')
      assert_eq(outputs[1].output_type, 'display_data')
      assert_true(outputs[1].data['image/png']:match('^iVBOR') ~= nil, 'matplotlib must automatically emit a PNG')
      assert_eq(#marks(), 1, 'PNG output must use the same EOF output block')

      run({ '' })
      assert_eq(#state.outputs(buf, file_cell()), 0, 'silent reruns must replace previous plot output')
      assert_eq(#marks(), 0, 'silent reruns must remove the output frame')
      run({ 'seed += 1', '' }, 'NotebookStyleRunCellAndMove')
      assert_eq(vim.api.nvim_win_get_cursor(0)[1], 2, 'whole-file execution must not move the cursor')
      assert_eq(#messages, 0, 'whole-file run-and-move must not warn about missing cells')

      run({ 'print("interrupt ready", flush=True)', 'time.sleep(30)' }, nil, function()
        assert_true(vim.wait(10000, function() return text() == 'interrupt ready' end, 10))
        exec.interrupt_kernel(buf)
      end)
      assert_true(text():find('KeyboardInterrupt', 1, true) ~= nil, 'the existing interrupt command should work')
      exec.stop_kernel(buf)
      assert_true(vim.wait(5000, function() return not state.get(buf).kernel_started end, 10))
      notebook.disable(buf)
      vim.api.nvim_buf_delete(buf, { force = true })
      buf = nil
      messages = {}
    end
  end)

  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(exec.stop_kernel, buf)
    vim.wait(5000, function() return not state.get(buf).kernel_started end, 10)
    notebook.disable(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  vim.notify, state.apply_event, image.supported = old_notify, old_event, old_supported
  vim.env.JUPYTER_PATH = old_jupyter_path
  vim.fn.delete(project, 'rf')
  if not ok then error(err, 0) end
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
  local state = require('notebook_style.state')
  local cells = require('notebook_style.cells')
  local config = require('notebook_style.config')
  local project = vim.fn.tempname()
  local old_notify = vim.notify
  local messages = {}
  local buf

  local function cleanup()
    vim.notify = old_notify
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(exec.stop_kernel, buf)
      vim.wait(5000, function() return not state.get(buf).kernel_started end, 10)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    vim.fn.delete(project, 'rf')
  end

  local ok, err = pcall(function()
    assert_eq(vim.fn.mkdir(project .. '/.venv/bin', 'p'), 1, 'failed to create temporary .venv')
    -- A wrapper, not a symlink: a symlinked venv interpreter no longer finds
    -- its pyvenv.cfg and loses the environment's packages (ipykernel), so a
    -- symlink only works when python3 is not itself from a virtualenv. The
    -- wrapper runs from the temporary directory, which must allow executing
    -- files (not mounted noexec).
    local venv_python = project .. '/.venv/bin/python'
    vim.fn.writefile({ '#!/bin/sh', 'exec ' .. sh_quote(python) .. ' "$@"' }, venv_python)
    assert_eq(vim.fn.setfperm(venv_python, 'rwxr-xr-x'), 1, 'failed to make the temporary .venv python executable')
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

    -- Finish startup and a real explicit-cell execution before tearing down
    -- the kernel, rather than killing it with the inline setup still queued.
    local cell = cells.get_cells(buf, cells.find_delimiters(buf, config.options.cell_delimiter), 2)[1]
    exec.run_cell(buf)
    assert_true(vim.wait(20000, function()
      local outputs = state.outputs(buf, cell)
      local status = state.status(buf, cell)
      return (status == 'idle' or status == 'ok') and outputs[1]
        and outputs[1].text == 'hello from auto_venv\n'
    end, 10), 'explicit-cell execution should still work')
  end)

  cleanup()
  if not ok then
    error(err, 0)
  end
end)

-- Run the callbacks that come due within 50 ms of the last test; they can
-- raise too.
vim.wait(50)
local trailing_error = take_error_message()
if trailing_error then
  local failure = 'after the last test: error message recorded (v:errmsg): ' .. trailing_error
  table.insert(failures, failure)
  print('[FAIL] ' .. failure)
end

-- tests/run_all.sh requires this summary to be the last line of output.
print(string.format('notebook_style Lua smoke tests: %d passed, %d skipped, %d failed', passed, skipped, #failures))

if #failures > 0 then
  error(table.concat(failures, '\n'))
end
