-- Download the prebuilt notebook-style-core binary from GitHub releases.
--
-- This is intended for plugin-manager build hooks so users on supported
-- platforms do not need a Rust toolchain. Development branches and unsupported
-- platforms fall back to `cargo build --release`.

local M = {}

local REPO = 'stellarjmr/notebook_style.nvim'
local BINARY = 'notebook-style-core'

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO)
end

local function detect_target()
  local uv = vim.uv or vim.loop
  local uname = uv.os_uname()
  local sys = uname.sysname
  local machine = uname.machine

  if sys == 'Darwin' then
    if machine == 'arm64' then
      return 'aarch64-apple-darwin'
    end
    if machine == 'x86_64' then
      return 'x86_64-apple-darwin'
    end
  elseif sys == 'Linux' then
    if machine == 'x86_64' then
      return 'x86_64-unknown-linux-gnu'
    end
    if machine == 'aarch64' then
      return 'aarch64-unknown-linux-gnu'
    end
  end

  return nil
end

local function detect_exact_tag(plugin_dir)
  local out = vim.fn.system({ 'git', '-C', plugin_dir, 'describe', '--tags', '--exact-match' })
  if vim.v.shell_error == 0 then
    return vim.trim(out)
  end
  return nil
end

local function cargo_build_command(plugin_dir)
  local manifest = plugin_dir .. '/core/Cargo.toml'
  if vim.fn.executable('cargo') == 1 then
    return { 'cargo', 'build', '--release', '--manifest-path', manifest }
  end

  local cargo_env = vim.fn.expand('$HOME/.cargo/env')
  if vim.fn.filereadable(cargo_env) == 1 and vim.fn.executable('bash') == 1 then
    return { 'bash', '-lc', string.format('. %q && cargo build --release --manifest-path %q', cargo_env, manifest) }
  end

  return nil
end

local function build_from_source(plugin_dir)
  local cmd = cargo_build_command(plugin_dir)
  if not cmd then
    error('notebook_style: no prebuilt backend available and cargo was not found')
  end

  notify('notebook_style: building backend from source via cargo')
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    error(('notebook_style: cargo build failed:\n%s'):format(out))
  end
end

local function default_plugin_dir()
  local source = debug.getinfo(1, 'S').source
  if source:sub(1, 1) == '@' then
    source = source:sub(2)
  end
  return vim.fn.fnamemodify(source, ':p:h:h:h')
end

local function binary_dest(plugin_dir)
  local dest_dir = plugin_dir .. '/core/target/release'
  vim.fn.mkdir(dest_dir, 'p')
  return dest_dir .. '/' .. BINARY
end

function M._url_for(tag, target)
  return string.format('https://github.com/%s/releases/download/%s/%s-%s', REPO, tag, BINARY, target)
end

function M.run(plugin)
  local plugin_dir = (plugin and plugin.dir) or default_plugin_dir()
  local target = detect_target()
  if not target then
    notify('notebook_style: no prebuilt backend for this platform; falling back to cargo', vim.log.levels.WARN)
    build_from_source(plugin_dir)
    return false
  end

  local tag = detect_exact_tag(plugin_dir)
  if not tag then
    notify('notebook_style: checkout is not an exact release tag; falling back to cargo', vim.log.levels.INFO)
    build_from_source(plugin_dir)
    return false
  end

  local url = M._url_for(tag, target)
  local dest = binary_dest(plugin_dir)
  notify(('notebook_style: downloading prebuilt backend %s for %s'):format(tag, target))
  local out = vim.fn.system({
    'curl',
    '-fsSL',
    '--retry',
    '3',
    '--retry-delay',
    '2',
    '-o',
    dest,
    url,
  })
  if vim.v.shell_error ~= 0 then
    notify(('notebook_style: download failed; falling back to cargo:\n%s'):format(out), vim.log.levels.WARN)
    build_from_source(plugin_dir)
    return false
  end

  vim.fn.system({ 'chmod', '+x', dest })
  local uv = vim.uv or vim.loop
  if uv.os_uname().sysname == 'Darwin' then
    vim.fn.system({ 'xattr', '-cr', dest })
  end

  notify(('notebook_style: installed prebuilt backend for %s'):format(target))
  return true
end

M._detect_target = detect_target
M._detect_exact_tag = detect_exact_tag

return M
