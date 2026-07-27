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

test('checkhealth notebook_style reports all sections', function()
  vim.cmd('checkhealth notebook_style')
  local lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  assert_true(lines:find('notebook_style: Neovim', 1, true) ~= nil, 'health should report Neovim section')
  assert_true(lines:find('notebook_style: execution backend', 1, true) ~= nil, 'health should report backend section')
  assert_true(lines:find('notebook_style: Jupyter kernel', 1, true) ~= nil, 'health should report kernel section')
  assert_true(lines:find('notebook_style: terminal images', 1, true) ~= nil, 'health should report image section')
  vim.cmd('bwipeout!')
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
