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
  else
    health.error('Neovim ' .. tostring(vim.version()) .. ' is not supported; notebook_style.nvim requires Neovim >= 0.10', {
      'Cell borders use the virt_text_repeat_linebreak extmark option, added in Neovim 0.10.',
    })
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

--- The user data directory as the backend sees it (`dirs::data_dir()` in
--- core/src/kernelspec.rs): ~/Library/Application Support on macOS, else
--- $XDG_DATA_HOME if it is an absolute path, else ~/.local/share.
local function user_data_dir(home)
  if vim.fn.has('mac') == 1 then
    return home .. '/Library/Application Support'
  end
  local xdg = vim.env.XDG_DATA_HOME
  if xdg and xdg:sub(1, 1) == '/' then
    return xdg
  end
  return home .. '/.local/share'
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
  table.insert(dirs, user_data_dir(home) .. '/jupyter/kernels')
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

--- How to get an ipykernel without that problem into `python`: 7.4 or newer,
--- or 6 if the Python (`python_version`, "3.10"; nil if unknown) is older
--- than 3.11, which ipykernel 7.4 needs.
local function ipykernel_advice(python, python_version)
  local py = vim.fn.shellescape(python)
  local major, minor = (python_version or ''):match('^(%d+)%.(%d+)$')
  local old_python = major ~= nil and (tonumber(major) < 3 or (tonumber(major) == 3 and tonumber(minor) < 11))
  local requirement = old_python and '"ipykernel<7"' or '"ipykernel>=7.4"'
  local advice = {
    ('%s -m pip install -U %s'):format(py, requirement),
    ('In a venv made by uv, which has no pip: uv pip install --python %s -U %s'):format(py, requirement),
  }
  if old_python then
    table.insert(advice, 1, ('ipykernel 7.4 needs Python 3.11 or newer, and this is Python %s: use ipykernel 6, which does not have the problem, or a newer Python'):format(python_version))
  end
  return advice
end

--- ipykernel 7.0 to 7.3 can stop handling requests when one arrives while it
--- sends a reply (fixed in 7.4.0): cells run in quick succession then stay
--- busy until the kernel is restarted. Report the version `python` imports
--- with the kernel's interpreter options and environment.
local function check_ipykernel_version(label, python, options, env)
  local cmd = vim.list_extend({ python }, options or {})
  vim.list_extend(cmd, {
    '-c',
    "import sys; print('notebook_style:python=%d.%d' % sys.version_info[:2]); import ipykernel; print('notebook_style:ipykernel=' + ipykernel.__version__)",
  })
  -- vim.system raises when the program cannot be started, e.g. a script
  -- whose #! interpreter is missing.
  local started, process = pcall(vim.system, cmd, { text = true, env = env })
  if not started then
    health.warn(('%s: could not run %s: %s'):format(label, python, process))
    return
  end
  -- nil when something it started keeps its output open after the kill.
  local result = process:wait(5000)
  if not result or result.code == 124 then
    health.info(('%s: could not read the ipykernel version of %s within 5 s'):format(label, python))
    return
  end
  -- Labelled lines: the interpreter can print other lines at startup
  -- (sitecustomize, .pth files).
  local stdout = '\n' .. (result.stdout or '')
  local python_version = stdout:match('\nnotebook_style:python=(%d+%.%d+)')
  if result.code ~= 0 then
    local reason = vim.trim(result.stderr or ''):match('[^\n]*$')
    health.warn(
      ('%s: %s cannot import ipykernel%s'):format(label, python, reason ~= '' and (': ' .. reason) or ''),
      ipykernel_advice(python, python_version)
    )
    return
  end
  local version = stdout:match('\nnotebook_style:ipykernel=([^\n]*)')
  local major, minor = (version or ''):match('^(%d+)%.(%d+)')
  if not major then
    health.info(('%s: could not read the ipykernel version of %s (it printed %s)'):format(label, python, vim.inspect(vim.trim(result.stdout or ''))))
  elseif tonumber(major) == 7 and tonumber(minor) < 4 then
    health.warn(
      ('%s: ipykernel %s can stop handling requests when cells are run in quick succession; they then stay busy until the kernel is restarted (fixed in ipykernel 7.4)'):format(label, version),
      ipykernel_advice(python, python_version)
    )
  else
    health.ok(('%s: ipykernel %s'):format(label, version))
  end
end

--- The interpreter options when a kernelspec's argv runs ipykernel directly:
--- an interpreter, options written as one word each (like
--- -Xfrozen_modules=off, which `ipykernel install` adds), then
--- -m ipykernel_launcher or -m ipykernel. nil for any other argv: a wrapper
--- (`conda run`, `/usr/bin/env python3`, `sh -c`, a script) is not run here,
--- since it is not Python and running it could start a kernel.
local function ipykernel_options(argv)
  local options = {}
  for i = 2, #argv - 1 do
    if argv[i] == '-m' then
      local module = argv[i + 1]
      return (module == 'ipykernel_launcher' or module == 'ipykernel') and options or nil
    end
    if type(argv[i]) ~= 'string' or argv[i]:sub(1, 1) ~= '-' then
      return nil
    end
    table.insert(options, argv[i])
  end
  return nil
end

--- The program a kernelspec runs, found as the backend finds it: like
--- Rust's Command, a bare name is looked up in the PATH of the kernelspec's
--- env when that sets one, otherwise in Neovim's. nil if it is not there.
local function find_program(program, env)
  local path = type(env) == 'table' and env.PATH
  if type(path) ~= 'string' or program:find('[/\\]') then
    return vim.fn.executable(program) == 1 and program or nil
  end
  for _, dir in ipairs(vim.split(path, vim.fn.has('win32') == 1 and ';' or ':', { plain = true })) do
    if dir ~= '' and vim.fn.executable(dir .. '/' .. program) == 1 then
      return dir .. '/' .. program
    end
  end
  return nil
end

--- What a kernelspec runs: the program must exist, and a Python kernel that
--- runs ipykernel directly gets its ipykernel version checked.
local function check_kernelspec(label, spec_dir)
  local ok, spec = pcall(vim.fn.json_decode, table.concat(vim.fn.readfile(spec_dir .. '/kernel.json'), '\n'))
  if not ok or type(spec) ~= 'table' or type(spec.argv) ~= 'table' or type(spec.argv[1]) ~= 'string' then
    return
  end
  -- As the backend does when it starts the kernel.
  local function expand(arg)
    return (arg:gsub('{resource_dir}', function() return spec_dir end))
  end
  local env = type(spec.env) == 'table' and spec.env or nil
  local program = find_program(expand(spec.argv[1]), env)
  if not program then
    health.warn(('%s runs %s, which cannot be found or is not executable, so the kernel cannot start'):format(label, expand(spec.argv[1])))
    return
  end
  local options = spec.language == 'python' and ipykernel_options(spec.argv)
  if options then
    check_ipykernel_version(label, program, vim.tbl_map(expand, options), env)
  end
end

local function check_kernel(opts)
  health.start('notebook_style: Jupyter kernel')

  local exec = require('notebook_style.exec')
  local venv_python, venv_warning

  if opts.auto_venv ~= false then
    venv_python, venv_warning = exec._find_local_venv_python(vim.fn.getcwd())
    if venv_python then
      health.ok('auto_venv: local .venv Python with ipykernel: ' .. venv_python)
      check_ipykernel_version('auto_venv', venv_python)
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
    check_kernelspec(("kernelspec '%s'"):format(kernel_name), spec_dir)
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
