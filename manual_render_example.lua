-- Example configuration for manual rendering mode
-- Add this to your Neovim config (init.lua or init.vim)

require('notebook_style').setup({
  -- Enable manual rendering mode
  -- Cells won't render automatically - use <leader>rs to render
  manual_render = true,

  -- Other optional configuration
  cell_delimiter = "^#%s*%%%%",
  border_style = 'solid',
  colors = {
    border = '#6272A4',
    delimiter = '#50FA7B',
  },
  hide_delimiter = true,
  hide_border_in_insert = true,
  cell_marker = ' ',
  cell_width_percentage = 80,
  min_cell_width = 40,
  max_cell_width = 120,
  filetypes = { 'python' },
})

-- Usage:
-- 1. Open a Python file with cell delimiters (# %%)
-- 2. Cells won't render automatically
-- 3. Press <leader>rs to toggle cell rendering on/off
-- 4. Or use :NotebookStyleToggleRender command to toggle
-- 5. Or use :NotebookStyleRender command to show rendering (without toggle)
