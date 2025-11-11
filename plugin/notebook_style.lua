-- notebook_style.nvim - Render Python cells with borders
-- Automatically loads the plugin when Neovim starts

if vim.g.loaded_notebook_style then
  return
end
vim.g.loaded_notebook_style = 1

-- Plugin will be initialized via setup() call in user config
