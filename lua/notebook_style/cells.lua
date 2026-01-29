local M = {}
local config = require('notebook_style.config')

--- Find all cell delimiters in the buffer
--- @param bufnr number Buffer number
--- @param pattern string Delimiter pattern
--- @return table List of line numbers where delimiters are found
function M.find_delimiters(bufnr, pattern)
  local delimiters = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for i, line in ipairs(lines) do
    if line:match(pattern) then
      table.insert(delimiters, i - 1)  -- 0-indexed
    end
  end

  return delimiters
end

--- Get cell boundaries from delimiter positions
--- @param bufnr number Buffer number
--- @param delimiters table List of delimiter line numbers
--- @param total_lines number Total lines in buffer
--- @return table List of cells with start and end line numbers
function M.get_cells(bufnr, delimiters, total_lines)
  local cells = {}

  if #delimiters == 0 then
    return cells
  end

  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for i = 1, #delimiters do
    local start_line = delimiters[i]
    local potential_end_line

    -- Find potential end (line before next delimiter, or end of buffer)
    if i < #delimiters then
      potential_end_line = delimiters[i + 1] - 1
    else
      potential_end_line = total_lines - 1
    end

    -- Trim trailing blank lines from the cell
    local end_line = potential_end_line
    for line_idx = potential_end_line, start_line, -1 do
      local line_content = all_lines[line_idx + 1] or ''  -- +1 because all_lines is 1-indexed
      -- Check if line is not blank (has non-whitespace content)
      if line_content:match('%S') then
        end_line = line_idx
        break
      end
      -- If we're at the delimiter line, stop there
      if line_idx == start_line then
        end_line = start_line
        break
      end
    end

    -- Extract cell name from delimiter line
    local delimiter_content = all_lines[start_line + 1] or ''
    local name = nil
    if config.options.show_cell_name then
      local pattern = config.options.cell_name_pattern or '^#%s*%%%%%s*(.-)%s*$'
      local captured = delimiter_content:match(pattern)
      if captured and vim.trim(captured) ~= '' then
        name = vim.trim(captured)
      end
    end

    table.insert(cells, {
      delimiter = start_line,
      start_line = start_line,
      end_line = end_line,
      name = name,
    })
  end

  return cells
end

--- Check if a cell is valid (has content beyond delimiter)
--- @param cell table Cell with start_line and end_line
--- @return boolean True if cell has content
function M.is_valid_cell(cell)
  return cell.end_line > cell.start_line
end

return M
