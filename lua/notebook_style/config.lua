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

  -- Cell marker (shown in the top border when delimiter is hidden)
  -- Use a nerd font icon for a nice visual indicator
  cell_marker = ' ',  --  is the Python nerd font icon

  -- Cell name display options
  show_cell_name = true,  -- Show cell name extracted from delimiter (e.g., "# %% My Cell Name")
  show_cell_number = true,  -- Show cell number in the label
  cell_name_pattern = '^#%s*%%%%%s*(.-)%s*$',  -- Pattern to extract cell name (capture group)
  cell_name_max_length = 40,  -- Maximum length for cell name display (nil to disable)
  cell_label_format_named = '{icon}#{number} {name}',  -- Format when cell has a name
  cell_label_format_unnamed = '{icon}#{number}',  -- Format when cell has no name

  -- Frame width configuration
  -- These legacy options are accepted for compatibility. Rendering now uses a
  -- full-window layout for stable wrapped lines and right-aligned borders.
  cell_width_percentage = 80,  -- Cell width as percentage of window width (1-100)
  min_cell_width = 40,  -- Minimum cell width in characters
  max_cell_width = 120,  -- Maximum cell width in characters

  -- Inline execution options
  backend_cmd = nil,  -- Command list for notebook-style-core; auto-detected when nil
  kernel_name = 'python3',
  auto_venv = true,  -- Prefer a project-local .venv with ipykernel when starting Python kernels
  auto_start_kernel = true,
  output_max_lines = 200,
  image = {
    rows = 18,  -- Height reserved for image/png outputs, in terminal rows
    cols = 60,  -- Maximum width reserved for image/png outputs, in terminal columns
    cell_height_to_width = 2.0,  -- Approximate terminal cell pixel aspect ratio
  },

  -- Default keymaps. Set a mapping to false to disable it.
  keymaps = {
    toggle_render = '<leader>rs',
    run_cell = '<leader>rr',
    run_file = '<leader>rf',
    run_cell_and_move = '<leader>rn',
  },

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

  vim.api.nvim_set_hl(0, 'NotebookCellOutput', {
    fg = M.options.colors.output or '#A9B1D6',
  })

  vim.api.nvim_set_hl(0, 'NotebookCellResult', {
    fg = M.options.colors.result or '#C0CAF5',
  })

  vim.api.nvim_set_hl(0, 'NotebookCellError', {
    fg = M.options.colors.error or '#F7768E',
  })
end

return M
