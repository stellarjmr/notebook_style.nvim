local M = {}

M.defaults = {
  -- Cell delimiter pattern
  cell_delimiter = "^#%s*%%%%",

  -- Border style: 'solid', 'dashed', or 'double'
  border_style = 'solid',

  -- Colors (can be hex colors or named highlight groups)
  colors = {
    border = '#6272A4',  -- Default border color
    delimiter = '#50FA7B',  -- Delimiter highlight color
  },

  -- Border characters for different styles
  border_chars = {
    solid = {
      top_left = '┌',
      top_right = '┐',
      bottom_left = '└',
      bottom_right = '┘',
      horizontal = '─',
      vertical = '│',
    },
    dashed = {
      top_left = '┌',
      top_right = '┐',
      bottom_left = '└',
      bottom_right = '┘',
      horizontal = '╌',
      vertical = '╎',
    },
    double = {
      top_left = '╔',
      top_right = '╗',
      bottom_left = '╚',
      bottom_right = '╝',
      horizontal = '═',
      vertical = '║',
    },
  },

  -- Visibility options
  hide_delimiter = true,  -- Hide # %% in normal/visual modes
  hide_border_in_insert = true,  -- Hide borders in insert mode

  -- Cell marker (shown when delimiter is hidden)
  -- Use a nerd font icon for a nice visual indicator
  cell_marker = ' ',  --  is the Python nerd font icon

  -- Frame width configuration
  cell_width_percentage = 80,  -- Cell width as percentage of window width (1-100)
  min_cell_width = 40,  -- Minimum cell width in characters
  max_cell_width = 120,  -- Maximum cell width in characters

  -- Filetypes to enable the plugin for
  filetypes = { 'python' },

  -- Manual render mode - if true, cells won't render automatically
  -- Use the render command or keybinding to render on demand
  manual_render = false,
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', M.defaults, opts or {})

  -- Set up highlight groups
  vim.api.nvim_set_hl(0, 'NotebookCellBorder', {
    fg = M.options.colors.border,
  })

  vim.api.nvim_set_hl(0, 'NotebookCellDelimiter', {
    fg = M.options.colors.delimiter,
  })
end

return M
