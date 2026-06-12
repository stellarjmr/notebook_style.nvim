-- :checkhealth notebook_style
--
-- Reports backend binary presence, Jupyter kernel availability, and
-- terminal image (Kitty graphics) support.

local M = {}

local health = vim.health

--- Active options, falling back to defaults when setup() has not run.
local function active_options()
  local config = require('notebook_style.config')
  if vim.tbl_isempty(config.options) then
    return config.defaults, false
  end
  return config.options, true
end

local function check_neovim()
  health.start('notebook_style: Neovim')

  if vim.fn.has('nvim-0.10') == 1 then
    health.ok('Neovim ' .. tostring(vim.version()) .. ' (>= 0.10)')
  elseif vim.fn.has('nvim-0.8') == 1 then
    health.warn('Neovim ' .. tostring(vim.version()) .. ' is older than 0.10', {
      'Borders on wrapped lines use virt_text_repeat_linebreak (Neovim 0.10+).',
      'Core rendering still works, but upgrading is recommended.',
    })
  else
    health.error('Neovim is older than 0.8; the plugin requires Neovim >= 0.8')
  end
end

local function check_setup(setup_called)
  health.start('notebook_style: setup')

  if setup_called then
    health.ok('setup() has been called')
  else
    health.warn('setup() has not been called; reporting against default options', {
      "Call require('notebook_style').setup() in your config.",
    })
  end
end

local function check_backend(opts)
  health.start('notebook_style: execution backend')

  local exec = require('notebook_style.exec')
  local cmd = opts.backend_cmd or exec._default_backend_cmd()
  local binary = cmd[1]
  local source = opts.backend_cmd and 'backend_cmd option' or 'auto-detected path'

  if vim.fn.executable(binary) == 1 then
    health.ok(('backend binary is executable (%s): %s'):format(source, binary))
  elseif vim.fn.filereadable(binary) == 1 then
    health.error(('backend binary exists but is not executable: %s'):format(binary), {
      'Run: chmod +x ' .. binary,
    })
  else
    health.error(('backend binary not found (%s): %s'):format(source, binary), {
      'Run :NotebookStyleDownloadBackend to download a prebuilt backend (tagged releases on',
      'Apple Silicon macOS, Linux x86_64, and Linux ARM64).',
      'Or build from source: cargo build --release --manifest-path core/Cargo.toml',
      'Cell border rendering works without the backend; only inline execution needs it.',
    })
  end
end

--- Standard Jupyter kernelspec directories (mirrors core/src/kernelspec.rs).
local function kernelspec_dirs()
  local dirs = {}
  local jupyter_path = vim.env.JUPYTER_PATH
  if jupyter_path and jupyter_path ~= '' then
    for _, p in ipairs(vim.split(jupyter_path, ':', { plain = true })) do
      table.insert(dirs, p .. '/kernels')
    end
  end

  local home = vim.fn.expand('~')
  table.insert(dirs, home .. '/Library/Jupyter/kernels')
  table.insert(dirs, (vim.env.XDG_DATA_HOME or (home .. '/.local/share')) .. '/jupyter/kernels')
  if vim.env.CONDA_PREFIX and vim.env.CONDA_PREFIX ~= '' then
    table.insert(dirs, vim.env.CONDA_PREFIX .. '/share/jupyter/kernels')
  end
  if vim.env.VIRTUAL_ENV and vim.env.VIRTUAL_ENV ~= '' then
    table.insert(dirs, vim.env.VIRTUAL_ENV .. '/share/jupyter/kernels')
  end
  table.insert(dirs, '/usr/share/jupyter/kernels')
  table.insert(dirs, '/usr/local/share/jupyter/kernels')
  table.insert(dirs, '/opt/homebrew/share/jupyter/kernels')
  return dirs
end

local function find_kernelspec(name)
  for _, dir in ipairs(kernelspec_dirs()) do
    if vim.fn.filereadable(dir .. '/' .. name .. '/kernel.json') == 1 then
      return dir .. '/' .. name
    end
  end
  return nil
end

local function check_kernel(opts)
  health.start('notebook_style: Jupyter kernel')

  local exec = require('notebook_style.exec')
  local venv_python, venv_warning

  if opts.auto_venv ~= false then
    venv_python, venv_warning = exec._find_local_venv_python(vim.fn.getcwd())
    if venv_python then
      health.ok('auto_venv: local .venv Python with ipykernel: ' .. venv_python)
    elseif venv_warning then
      health.warn('auto_venv: ' .. venv_warning, {
        'Install ipykernel into the venv, e.g. .venv/bin/python -m pip install ipykernel',
        'Or set auto_venv = false to always use kernel_name.',
      })
    else
      health.info('auto_venv: no local .venv found from ' .. vim.fn.getcwd() .. '; kernel_name will be used')
    end
  else
    health.info('auto_venv is disabled; kernel_name will be used')
  end

  local kernel_name = opts.kernel_name or 'python3'
  local spec_dir = find_kernelspec(kernel_name)
  if spec_dir then
    health.ok(("kernelspec '%s' found: %s"):format(kernel_name, spec_dir))
  elseif venv_python then
    health.info(("kernelspec '%s' not found, but the local .venv kernel is available"):format(kernel_name))
  else
    health.warn(("kernelspec '%s' not found in standard Jupyter directories"):format(kernel_name), {
      'Register one with: python -m ipykernel install --user --name ' .. kernel_name,
      'Or add ipykernel to a project-local .venv and keep auto_venv = true.',
    })
  end
end

local function check_terminal_images()
  health.start('notebook_style: terminal images')

  local image = require('notebook_style.image')
  if image.supported() then
    health.ok('terminal advertises Kitty graphics support; image/png outputs render inline')
  else
    health.info('no Kitty graphics support detected (Kitty/Ghostty); image/png outputs fall back to text')
  end

  if vim.env.TMUX and vim.env.TMUX ~= '' then
    if vim.fn.executable('tmux') == 1 then
      local out = vim.fn.system({ 'tmux', 'show', '-gv', 'allow-passthrough' })
      local value = vim.trim(out or '')
      if vim.v.shell_error == 0 and (value == 'on' or value == 'all') then
        health.ok('tmux allow-passthrough is ' .. value)
      else
        health.warn('tmux allow-passthrough is not enabled; inline images will not display', {
          'Add to tmux.conf: set -g allow-passthrough on',
        })
      end
    else
      health.info('running inside tmux; ensure allow-passthrough is on for inline images')
    end
  end
end

function M.check()
  local opts, setup_called = active_options()

  check_neovim()
  check_setup(setup_called)
  check_backend(opts)
  check_kernel(opts)
  check_terminal_images()
end

return M
