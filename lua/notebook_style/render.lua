local M = {}
local config = require('notebook_style.config')

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
--- @param right_margin number Empty columns between the right border and window edge
--- @param cell_number number Cell number for display
function M.render_cell(bufnr, cell, show_borders, show_delimiter, frame_width, right_margin, cell_number)
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
    -- When the configured frame is narrower than the usable text area, trailing
    -- spaces keep the visible border inset from the window edge.
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, 0, {
      virt_text = { { chars.vertical .. string.rep(' ', right_margin), 'NotebookCellBorder' } },
      virt_text_pos = 'right_align',
      virt_text_repeat_linebreak = true,
      hl_mode = 'combine',
      priority = 200,
    })
  end

  -- Bottom border - add it as a virtual line below the cell
  local bottom_border = make_border_line(frame_width, chars.bottom_left, chars.horizontal, chars.bottom_right)
  vim.api.nvim_buf_set_extmark(bufnr, M.ns, cell.end_line, 0, {
    virt_lines = {
      { { bottom_border, 'NotebookCellBorder' } },
    },
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

  -- Calculate a consistent frame width for ALL cells based on usable text area.
  local usable_width = get_usable_width(winid)
  local percentage = config.options.cell_width_percentage or 80
  local min_width = config.options.min_cell_width or 40
  local max_width = math.min(config.options.max_cell_width or 120, usable_width)

  -- Calculate frame width as percentage of usable text width
  local calculated_width = math.floor(usable_width * percentage / 100)

  -- Apply min/max constraints
  local standard_frame_width = math.max(math.min(min_width, usable_width), math.min(calculated_width, max_width))
  standard_frame_width = math.min(standard_frame_width, usable_width)
  local right_margin = math.max(usable_width - standard_frame_width, 0)

  for i, cell in ipairs(cells) do
    M.render_cell(bufnr, cell, show_borders, show_delimiter, standard_frame_width, right_margin, i)
  end
end

return M
