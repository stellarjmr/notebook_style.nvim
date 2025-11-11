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
  return left .. string.rep(middle, width - 2) .. right
end

--- Render a cell border
--- @param bufnr number Buffer number
--- @param cell table Cell with start_line and end_line
--- @param show_borders boolean Whether to show borders
--- @param show_delimiter boolean Whether to show delimiter
--- @param frame_width number Baseline frame width (cells grow to fit longer lines)
function M.render_cell(bufnr, cell, show_borders, show_delimiter, frame_width)
  local chars = get_border_chars()

  -- Define cell marker text (used consistently throughout)
  local cell_marker_text = '  Cell'
  local cell_marker_width = vim.fn.strdisplaywidth(cell_marker_text)

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

  -- Precompute visible widths for each line in the cell so we can adjust the
  -- frame if a line is longer than the standard width.
  local line_widths = {}
  local max_line_width = 0

  for line = cell.start_line, cell.end_line do
    local line_content = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ''

    local line_width
    if line == cell.delimiter and not show_delimiter then
      line_width = cell_marker_width
    else
      line_width = vim.fn.strdisplaywidth(line_content)
    end

    line_widths[line] = line_width
    if line_width > max_line_width then
      max_line_width = line_width
    end
  end

  -- Guarantee the frame is wide enough for the current cell:
  -- left border + space + content + eol anchor + right border.
  local cell_frame_width = math.max(frame_width, max_line_width + 4)

  -- Top border - add it as a virtual line above the cell
  local top_border = make_border_line(cell_frame_width, chars.top_left, chars.horizontal, chars.top_right)
  if cell.start_line > 0 then
    -- Add top border above the cell (on the line before)
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, cell.start_line - 1, 0, {
      virt_lines = {
        { { top_border, 'NotebookCellBorder' } },
      },
    })
  else
    -- For first line in buffer, add virtual line above
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, cell.start_line, 0, {
      virt_lines = {
        { { top_border, 'NotebookCellBorder' } },
      },
    })
  end

  -- Side borders for each line in the cell
  for line = cell.start_line, cell.end_line do
    local line_width = line_widths[line] or 0

    -- Calculate padding so the right border lines up with the top/bottom corners.
    -- Layout: │ + space + content + (EOL anchor) + padding + │ = cell_frame_width,
    -- so padding = cell_frame_width - line_width - 4.
    local padding_needed = cell_frame_width - line_width - 4
    local padding = string.rep(' ', math.max(0, padding_needed))

    -- Left border (inline at start of line)
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, 0, {
      virt_text = { { chars.vertical .. ' ', 'NotebookCellBorder' } },
      virt_text_pos = 'inline',
      priority = 200,
    })

    if line == cell.delimiter and not show_delimiter then
      -- Place the delimiter row's right border exactly under the corner, even
      -- though the line itself is concealed (so there is no real EOL to anchor to).
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, 0, {
        virt_text = { { chars.vertical, 'NotebookCellBorder' } },
        virt_text_pos = 'overlay',
        virt_text_win_col = math.max(0, cell_frame_width - 1),
        priority = 200,
      })
    else
      -- Right border with padding (at end of line) - no extra space before │
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, 0, {
        virt_text = { { padding .. chars.vertical, 'NotebookCellBorder' } },
        virt_text_pos = 'eol',
        priority = 200,
      })
    end
  end

  -- Bottom border - add it as a virtual line below the cell
  local bottom_border = make_border_line(cell_frame_width, chars.bottom_left, chars.horizontal, chars.bottom_right)
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
function M.render_all(bufnr, cells, mode)
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

  -- Calculate a consistent frame width for ALL cells based on window width
  local win_width = vim.api.nvim_win_get_width(0)
  local percentage = config.options.cell_width_percentage or 80
  local min_width = config.options.min_cell_width or 40
  local max_width = config.options.max_cell_width or 120

  -- Calculate frame width as percentage of window width
  local calculated_width = math.floor(win_width * percentage / 100)

  -- Apply min/max constraints
  local standard_frame_width = math.max(min_width, math.min(calculated_width, max_width))

  for _, cell in ipairs(cells) do
    M.render_cell(bufnr, cell, show_borders, show_delimiter, standard_frame_width)
  end
end

return M
