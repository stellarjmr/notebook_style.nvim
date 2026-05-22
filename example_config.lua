-- Example configuration for notebook_style.nvim
-- Copy relevant parts to your Neovim config

-- Lazy.nvim setup
return {
  'stellarjmr/notebook_style.nvim',
  ft = 'python',
  build = function(plugin)
    local install = loadfile(plugin.dir .. '/lua/notebook_style/install.lua')()
    install.run(plugin)
  end,
  opts = {
    -- Choose border style: 'solid', 'dashed', or 'double'
    border_style = 'solid',

    -- Customize colors
    colors = {
      border = '#6272A4',      -- Dracula comment color
      delimiter = '#50FA7B',   -- Dracula green
    },

    -- Behavior options
    -- Cells render automatically by default; <leader>rs toggles visibility.
    hide_delimiter = true,
    hide_border_in_insert = true,

    -- Cell marker (requires Nerd Font)
    cell_marker = ' Cell',  --  is Python nerd font icon

    -- Cell width configuration
    cell_width_percentage = 80,  -- Use 80% of window width
    min_cell_width = 40,
    max_cell_width = 120,

    -- Inline image output size
    -- auto_venv defaults to true, so local .venv/bin/python is preferred when
    -- it can import ipykernel. Set false to always use kernel_name.
    auto_venv = true,
    image = {
      rows = 18,
      cols = 60,
      cell_height_to_width = 2.0,
    },

    -- Built-in keymaps. Set any mapping to false to disable it.
    keymaps = {
      toggle_render = '<leader>rs',
      run_cell = '<leader>rr',
      run_file = '<leader>rf',
      run_cell_and_move = '<leader>rn',
    },
  },
  keys = {
    { '<leader>ns', '<cmd>NotebookStyleToggle<cr>', desc = 'Toggle notebook style' },
  },
}

-- Alternative: Manual setup in init.lua
-- require('notebook_style').setup({
--   border_style = 'dashed',
--   colors = {
--     border = '#928374',    -- Gruvbox gray
--     delimiter = '#b8bb26', -- Gruvbox green
--   },
-- })

-- Custom keybindings (optional)
-- vim.keymap.set('n', '<leader>ns', '<cmd>NotebookStyleToggle<cr>', { desc = 'Toggle notebook style' })
-- vim.keymap.set('n', '<leader>ne', '<cmd>NotebookStyleEnable<cr>', { desc = 'Enable notebook style' })
-- vim.keymap.set('n', '<leader>nd', '<cmd>NotebookStyleDisable<cr>', { desc = 'Disable notebook style' })
