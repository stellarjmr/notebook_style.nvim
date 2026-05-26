local M = {}

local cells = require('notebook_style.cells')
local config = require('notebook_style.config')
local state = require('notebook_style.state')

local views = {}

local function as_str(value)
  if type(value) == 'table' then
    return table.concat(value, '')
  end
  if type(value) == 'string' then
    return value
  end
  return ''
end

local function strip_ansi(text)
  text = text:gsub('\27%[[?]?[%d;]*[a-zA-Z]', '')
  text = text:gsub('\27%][^\27]*\27\\', '')
  text = text:gsub('\27.', '')
  return text
end

local function process_cr(text)
  local out = {}
  for chunk in (text .. '\n'):gmatch('([^\n]*)\n') do
    local segments = {}
    for segment in (chunk .. '\r'):gmatch('([^\r]*)\r') do
      table.insert(segments, segment)
    end
    table.insert(out, segments[#segments] or '')
  end
  if out[#out] == '' then
    table.remove(out)
  end
  return table.concat(out, '\n')
end

local function is_boring_image_repr(text)
  return text:match('^<Figure size .+ with %d+ Axes>$')
    or text:match('^<Figure size .+ with %d+ Axis>$')
    or text:match('^<IPython%.core%.display%.Image object')
end

local function current_cells(bufnr)
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local delimiters = cells.find_delimiters(bufnr, config.options.cell_delimiter)
  return cells.get_cells(bufnr, delimiters, total_lines)
end

local function cursor_line_for(bufnr)
  local winid = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(winid) ~= bufnr then
    winid = vim.fn.bufwinid(bufnr)
  end

  if winid and winid > 0 and vim.api.nvim_win_is_valid(winid) then
    return vim.api.nvim_win_get_cursor(winid)[1] - 1
  end

  return 0
end

local function current_cell_with_index(bufnr)
  local cursor_line = cursor_line_for(bufnr)
  for index, cell in ipairs(current_cells(bufnr)) do
    if cursor_line >= cell.start_line and cursor_line <= cell.end_line then
      return cell, index
    end
  end
  return nil, nil
end

local function add_text(lines, text)
  text = strip_ansi(process_cr(as_str(text)))
  if text == '' then
    return
  end

  vim.list_extend(lines, vim.split(text, '\n', { plain = true }))
end

function M.format_outputs(outputs)
  local lines = {}

  for _, output in ipairs(outputs or {}) do
    if output.output_type == 'stream' then
      add_text(lines, output.text)
    elseif output.output_type == 'execute_result' or output.output_type == 'display_data' then
      local data = output.data or {}
      local has_image = data['image/png'] ~= nil
      local text = as_str(data['text/plain'])
      local added_text = false

      if text ~= '' and not (has_image and is_boring_image_repr(text)) then
        add_text(lines, text)
        added_text = true
      end

      if has_image then
        add_text(lines, '[image/png output]')
      elseif not added_text and data['text/html'] ~= nil then
        add_text(lines, '[text/html output]')
      end
    elseif output.output_type == 'error' then
      add_text(lines, as_str(output.ename) .. ': ' .. as_str(output.evalue))
      for _, line in ipairs(output.traceback or {}) do
        add_text(lines, line)
      end
    end
  end

  return lines
end

local function ensure_view(source_bufnr)
  local view = views[source_bufnr]
  if view and view.bufnr and vim.api.nvim_buf_is_valid(view.bufnr) then
    return view
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  view = { bufnr = bufnr, winid = nil }
  views[source_bufnr] = view

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    once = true,
    callback = function()
      if views[source_bufnr] and views[source_bufnr].bufnr == bufnr then
        views[source_bufnr] = nil
      end
    end,
  })

  vim.keymap.set('n', 'q', function()
    M.close(source_bufnr)
  end, { buffer = bufnr, desc = 'Close notebook output', nowait = true, silent = true })

  vim.keymap.set('n', '<Esc>', function()
    M.close(source_bufnr)
  end, { buffer = bufnr, desc = 'Close notebook output', nowait = true, silent = true })

  return view
end

local function set_buffer_lines(bufnr, lines)
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undofile = false
  vim.bo[bufnr].filetype = 'notebook_style_output'

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
end

local function window_options(title)
  local columns = math.max(vim.o.columns, 1)
  local editor_lines = math.max(vim.o.lines - vim.o.cmdheight, 1)
  local view_config = config.options.output_view or {}
  local default_config = config.defaults.output_view or {}
  local width_ratio = view_config.width
  local height_ratio = view_config.height

  if type(width_ratio) ~= 'number' or width_ratio <= 0 then
    width_ratio = default_config.width or 0.85
  end
  if type(height_ratio) ~= 'number' or height_ratio <= 0 then
    height_ratio = default_config.height or 0.75
  end

  width_ratio = math.min(width_ratio, 1)
  height_ratio = math.min(height_ratio, 1)

  local width = math.min(math.max(math.floor(columns * width_ratio), 20), math.max(columns - 4, 1))
  local height = math.min(math.max(math.floor(editor_lines * height_ratio), 5), math.max(editor_lines - 4, 1))

  local opts = {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((editor_lines - height) / 2),
    col = math.floor((columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    focusable = true,
  }

  if vim.fn.has('nvim-0.9') == 1 then
    opts.title = title
    opts.title_pos = 'center'
  end

  return opts
end

local function set_window_options(winid)
  vim.wo[winid].wrap = false
  vim.wo[winid].cursorline = true
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = 'no'
  vim.wo[winid].foldcolumn = '0'
end

local function output_title(cell, cell_index, execution_count)
  local title = ' Notebook Output'
  if execution_count then
    title = title .. ' Out[' .. execution_count .. ']'
  elseif cell_index then
    title = title .. ' #' .. cell_index
  end
  if cell and cell.name then
    title = title .. ' ' .. cell.name
  end
  return title .. ' '
end

function M.open(bufnr)
  bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local cell, cell_index = current_cell_with_index(bufnr)
  if not cell then
    vim.notify('NotebookStyle: cursor is not inside a cell', vim.log.levels.WARN)
    return nil
  end

  local outputs = state.outputs(bufnr, cell)
  local lines = M.format_outputs(outputs)
  if #lines == 0 then
    vim.notify('NotebookStyle: current cell has no output', vim.log.levels.WARN)
    return nil
  end

  local view = ensure_view(bufnr)
  set_buffer_lines(view.bufnr, lines)

  local title = output_title(cell, cell_index, state.execution_count(bufnr, cell))
  local opts = window_options(title)
  if view.winid and vim.api.nvim_win_is_valid(view.winid) then
    local ok, win_config = pcall(vim.api.nvim_win_get_config, view.winid)
    if ok and win_config.relative ~= '' then
      pcall(vim.api.nvim_win_set_config, view.winid, opts)
      vim.api.nvim_set_current_win(view.winid)
    else
      view.winid = vim.api.nvim_open_win(view.bufnr, true, opts)
    end
  else
    view.winid = vim.api.nvim_open_win(view.bufnr, true, opts)
  end

  set_window_options(view.winid)
  vim.api.nvim_win_set_cursor(view.winid, { 1, 0 })

  return view.winid, view.bufnr
end

function M.close(source_bufnr)
  local view = views[source_bufnr]
  if not view then
    return
  end

  if view.winid and vim.api.nvim_win_is_valid(view.winid) then
    pcall(vim.api.nvim_win_close, view.winid, true)
  end

  if view.bufnr and vim.api.nvim_buf_is_valid(view.bufnr) then
    pcall(vim.api.nvim_buf_delete, view.bufnr, { force = true })
  end

  views[source_bufnr] = nil
end

return M
