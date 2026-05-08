local M = {}
local config = require('notebook_style.config')
local state = require('notebook_style.state')

-- Namespace for extmarks
M.ns = vim.api.nvim_create_namespace('notebook_style')

--- Clear all extmarks in the buffer
--- @param bufnr number Buffer number
function M.clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
end

--- Get border characters based on configuration
--- @return table Border characters
local function get_border_chars()
  local style = config.options.border_style or 'solid'
  return config.options.border_chars[style]
end

--- Create a horizontal border line
--- @param width number Width of the border
--- @param left string Left corner character
--- @param middle string Middle character
--- @param right string Right corner character
--- @return string Complete border line
local function make_border_line(width, left, middle, right)
  width = math.max(width, 2)
  return left .. string.rep(middle, width - 2) .. right
end

local function divider_line(width, label)
  local chars = get_border_chars()
  local main = chars.vertical .. '─ ' .. label .. ' '
  local pad = width - vim.fn.strdisplaywidth(main) - 1
  return main .. string.rep(chars.horizontal, math.max(pad, 0)) .. chars.vertical
end

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

local function wrap_line(line, width)
  if width <= 0 or vim.fn.strdisplaywidth(line) <= width then
    return { line }
  end

  local out = {}
  local chars = vim.fn.strchars(line)
  local pos = 0

  while pos < chars do
    local start = pos
    local current_width = 0
    while pos < chars do
      local char = vim.fn.strcharpart(line, pos, 1)
      local char_width = vim.fn.strdisplaywidth(char)
      if current_width + char_width > width then
        break
      end
      current_width = current_width + char_width
      pos = pos + 1
    end
    if pos == start then
      pos = pos + 1
    end
    table.insert(out, vim.fn.strcharpart(line, start, pos - start))
  end

  return out
end

local function with_sides(text, hl, width)
  local inner_width = math.max(width - 4, 1)
  local display_width = vim.fn.strdisplaywidth(text)
  if display_width > inner_width then
    text = vim.fn.strcharpart(text, 0, inner_width)
    display_width = vim.fn.strdisplaywidth(text)
  end
  local pad = math.max(inner_width - display_width, 0)
  return {
    { '│ ', 'NotebookCellBorder' },
    { text, hl },
    { string.rep(' ', pad) .. ' │', 'NotebookCellBorder' },
  }
end

local function build_output_lines(outputs, width)
  local rows = {}
  local inner_width = math.max(width - 4, 1)
  local max_lines = config.options.output_max_lines or 200

  local function add_text(text, hl)
    text = strip_ansi(process_cr(text))
    for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
      for _, wrapped in ipairs(wrap_line(line, inner_width)) do
        if #rows >= max_lines then
          return
        end
        table.insert(rows, with_sides(wrapped, hl, width))
      end
    end
  end

  for _, output in ipairs(outputs or {}) do
    if #rows >= max_lines then
      break
    end

    if output.output_type == 'stream' then
      add_text(as_str(output.text), output.name == 'stderr' and 'NotebookCellError' or 'NotebookCellOutput')
    elseif output.output_type == 'execute_result' or output.output_type == 'display_data' then
      local data = output.data or {}
      local text = as_str(data['text/plain'])
      if text ~= '' then
        add_text(text, 'NotebookCellResult')
      end
      for _, mime in ipairs({ 'image/gif', 'image/png', 'image/jpeg' }) do
        if data[mime] then
          add_text('[' .. mime .. ' output]', 'NotebookCellOutput')
          break
        end
      end
    elseif output.output_type == 'error' then
      add_text(as_str(output.ename) .. ': ' .. as_str(output.evalue), 'NotebookCellError')
      for _, line in ipairs(output.traceback or {}) do
        add_text(as_str(line), 'NotebookCellError')
      end
    end
  end

  if #rows >= max_lines then
    table.insert(rows, with_sides('… output truncated …', 'NotebookCellOutput', width))
  end

  return rows
end

--- Calculate the usable text width for a window.
--- @param winid number Window id
--- @return number Width available to buffer text
local function get_usable_width(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    winid = vim.api.nvim_get_current_win()
  end

  local win_width = vim.api.nvim_win_get_width(winid)
  local info = vim.fn.getwininfo(winid)[1]
  local text_offset = info and info.textoff or 0

  return math.max(win_width - text_offset, 2)
end

--- Build a cell label string from cell data and number
--- @param cell table Cell with optional name field
--- @param cell_number number Cell number for display
--- @return string Formatted cell label
local function build_cell_label(cell, cell_number)
  local icon = config.options.cell_marker or ''
  local show_name = config.options.show_cell_name and cell.name
  local show_number = config.options.show_cell_number

  local name = cell.name
  if name and config.options.cell_name_max_length then
    local max_len = config.options.cell_name_max_length
    if vim.fn.strdisplaywidth(name) > max_len then
      name = vim.fn.strcharpart(name, 0, max_len - 1) .. '…'
    end
  end

  local format_str
  if show_name then
    format_str = config.options.cell_label_format_named or '{icon}#{number} {name}'
  else
    format_str = config.options.cell_label_format_unnamed or '{icon}#{number}'
  end

  local label = format_str
    :gsub('{icon}', icon)
    :gsub('{number}', show_number and tostring(cell_number) or '')
    :gsub('{name}', name or '')

  return label
end

--- Render a cell border
--- @param bufnr number Buffer number
--- @param cell table Cell with start_line and end_line
--- @param show_borders boolean Whether to show borders
--- @param show_delimiter boolean Whether to show delimiter
--- @param frame_width number Frame width
--- @param cell_number number Cell number for display
function M.render_cell(bufnr, cell, show_borders, show_delimiter, frame_width, cell_number)
  local chars = get_border_chars()

  -- Build cell label with optional name
  local cell_marker_text = build_cell_label(cell, cell_number)

  -- Hide the delimiter line if configured
  if not show_delimiter and config.options.hide_delimiter then
    -- Get the delimiter line content to calculate length
    local delimiter_line = vim.api.nvim_buf_get_lines(bufnr, cell.delimiter, cell.delimiter + 1, false)[1] or ''

    -- Replace the entire delimiter with a subtle marker
    -- Use end_col as byte length for proper concealment
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, cell.delimiter, 0, {
      end_row = cell.delimiter,
      end_col = #delimiter_line,
      conceal = '',
    })

    -- Add a subtle marker to show where the delimiter is
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, cell.delimiter, 0, {
      virt_text = { { cell_marker_text, 'NotebookCellDelimiter' } },
      virt_text_pos = 'overlay',
      hl_mode = 'combine',
    })
  end

  if not show_borders then
    return
  end

  -- Top border - add it as a virtual line above the cell
  local top_border = make_border_line(frame_width, chars.top_left, chars.horizontal, chars.top_right)
  -- Always anchor at the delimiter line and place above it so the border sits
  -- directly on top of the cell even at the top of the buffer.
  vim.api.nvim_buf_set_extmark(bufnr, M.ns, cell.start_line, 0, {
    virt_lines = {
      { { top_border, 'NotebookCellBorder' } },
    },
    virt_lines_above = true,
  })

  -- Side borders for each line in the cell
  for line = cell.start_line, cell.end_line do
    -- Left border (inline at start of line, no trailing space to avoid cursor gap)
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, 0, {
      virt_text = { { chars.vertical, 'NotebookCellBorder' } },
      virt_text_pos = 'inline',
      hl_mode = 'combine',
      priority = 200,
    })

    -- Left border for wrapped continuation lines. The lower priority lets the
    -- inline mark define the first screen row while repeat_linebreak keeps the
    -- border visible on wrapped rows.
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, 0, {
      virt_text = { { chars.vertical, 'NotebookCellBorder' } },
      virt_text_win_col = 0,
      virt_text_repeat_linebreak = true,
      hl_mode = 'combine',
      priority = 190,
    })

    -- Right border is aligned by Neovim instead of manual per-line padding.
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, 0, {
      virt_text = { { chars.vertical, 'NotebookCellBorder' } },
      virt_text_pos = 'right_align',
      virt_text_repeat_linebreak = true,
      hl_mode = 'combine',
      priority = 200,
    })
  end

  local lines_below = {}
  local outputs = state.outputs(bufnr, cell)
  if #outputs > 0 then
    local execution_count = state.execution_count(bufnr, cell) or cell_number
    table.insert(lines_below, { { divider_line(frame_width, 'Out[' .. execution_count .. ']'), 'NotebookCellBorder' } })
    for _, row in ipairs(build_output_lines(outputs, frame_width)) do
      table.insert(lines_below, row)
    end
  end

  local bottom_border = make_border_line(frame_width, chars.bottom_left, chars.horizontal, chars.bottom_right)
  table.insert(lines_below, { { bottom_border, 'NotebookCellBorder' } })
  vim.api.nvim_buf_set_extmark(bufnr, M.ns, cell.end_line, 0, {
    virt_lines = lines_below,
  })
end

--- Render all cells in the buffer
--- @param bufnr number Buffer number
--- @param cells table List of cells
--- @param mode string Current mode
--- @param winid number Window id
function M.render_all(bufnr, cells, mode, winid)
  M.clear(bufnr)

  -- Determine visibility based on mode
  local show_borders = true
  local show_delimiter = true

  if mode:match('^i') then  -- Insert mode
    show_borders = config.options.hide_border_in_insert
    show_borders = not show_borders  -- Invert because option is "hide"
    show_delimiter = true
  elseif mode:match('^[nvV]') or mode == '' then  -- Normal or Visual mode
    show_borders = true
    show_delimiter = false
  end

  -- Full-window layout: use the full text area width. The legacy percentage
  -- options remain accepted for compatibility but no longer drive rendering.
  local usable_width = get_usable_width(winid)
  local standard_frame_width = usable_width

  for i, cell in ipairs(cells) do
    M.render_cell(bufnr, cell, show_borders, show_delimiter, standard_frame_width, i)
  end
end

return M
