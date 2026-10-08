-- msgpack-rpc client over a child's stdio.

local mpack = vim.mpack
local uv = vim.loop

local M = {}

local Client = {}
Client.__index = Client

-- Errors passed to callbacks when the backend process is gone. Whoever owns
-- the client reports the exit once (on_exit), so request handlers can skip
-- their own notifications for these.
local EXITED = 'notebook-style-core exited'
local NOT_RUNNING = 'notebook-style-core is not running'

function M.is_backend_gone(err)
  return err == EXITED or err == NOT_RUNNING
end

local function warn(msg)
  vim.schedule(function()
    vim.notify('notebook-style-core: ' .. msg, vim.log.levels.WARN)
  end)
end

local function spawn_error(cmd, err)
  local exists = vim.fn.filereadable(cmd) == 1
  local executable = vim.fn.executable(cmd) == 1
  local details = {
    'notebook-style-core spawn failed: ' .. tostring(err),
    'command: ' .. tostring(cmd),
    'exists: ' .. tostring(exists),
    'executable: ' .. tostring(executable),
  }

  if not exists or not executable then
    table.insert(details, 'Run :NotebookStyleDownloadBackend, then check :messages for installer output.')
    table.insert(details, 'Prebuilt backends are available for tagged releases on Apple Silicon macOS, Linux x86_64, and Linux ARM64.')
    table.insert(details, 'Unsupported platforms require Cargo to build core/Cargo.toml locally.')
  end

  return table.concat(details, '\n')
end

function M.spawn(opts)
  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local c = setmetatable({
    stdin = stdin,
    stdout = stdout,
    stderr = stderr,
    handle = nil,
    pid = nil,
    next_id = 1,
    pending = {},
    handlers = {},
    buf = '',
    on_exit = opts.on_exit,
    job = nil,
  }, Client)

  local cmd = opts.cmd[1]
  local args = {}
  for i = 2, #opts.cmd do
    args[i - 1] = opts.cmd[i]
  end

  local handle, pid = uv.spawn(cmd, {
    args = args,
    stdio = { stdin, stdout, stderr },
    cwd = opts.cwd,
    env = opts.env,
  }, function(code, signal)
    c.exited = true
    pcall(function()
      if not stdin:is_closing() then
        stdin:close()
      end
    end)
    pcall(function()
      if not stderr:is_closing() then
        stderr:close()
      end
    end)
    -- `handle` itself is not in scope yet inside its own initializer.
    pcall(function()
      if c.handle and not c.handle:is_closing() then
        c.handle:close()
      end
    end)
    -- Responses written just before the exit may still be in the stdout pipe:
    -- keep reading until EOF, but never leave callers waiting if EOF is late.
    local timer = uv.new_timer()
    timer:start(1000, 0, function()
      timer:close()
      c:_close()
    end)
    vim.schedule(function()
      if c.on_exit then
        c.on_exit(code, signal)
      else
        warn('exited code=' .. tostring(code) .. ' signal=' .. tostring(signal))
      end
    end)
  end)

  if not handle then
    error(spawn_error(cmd, pid))
  end

  c.handle, c.pid, c.job = handle, pid, pid

  stdout:read_start(function(err, chunk)
    if err then
      warn('stdout read: ' .. err)
    end
    if not chunk then
      c:_close()
      return
    end
    c.buf = c.buf .. chunk
    c:_drain()
  end)

  stderr:read_start(function(err, chunk)
    if err then
      warn('stderr read: ' .. err)
      return
    end
    if not chunk then
      return
    end
    for line in chunk:gmatch('[^\n]+') do
      warn(line)
    end
  end)

  return c
end

function Client:stop()
  if self.handle and not self.handle:is_closing() then
    self.handle:kill('sigterm')
  end
end

--- Stop reading responses and fail every outstanding call, in request order,
--- so no caller waits forever for a backend that is gone.
function Client:_close()
  if self.closed then
    return
  end
  self.closed = true
  if not self.stdout:is_closing() then
    self.stdout:close()
  end

  local pending = self.pending
  self.pending = {}
  local ids = vim.tbl_keys(pending)
  table.sort(ids)
  for _, id in ipairs(ids) do
    vim.schedule(function()
      pending[id](EXITED, nil)
    end)
  end
end

function Client:_drain()
  while #self.buf >= 4 do
    local b1, b2, b3, b4 = string.byte(self.buf, 1, 4)
    local len = b1 * 0x1000000 + b2 * 0x10000 + b3 * 0x100 + b4
    if #self.buf < 4 + len then
      return
    end
    local payload = self.buf:sub(5, 4 + len)
    self.buf = self.buf:sub(5 + len)
    local ok, val = pcall(mpack.decode, payload)
    if ok and val then
      self:_dispatch(val)
    else
      warn('decode failed: ' .. tostring(val))
    end
  end
end

local function denil(v)
  if v == vim.NIL then
    return nil
  end
  if type(v) == 'table' then
    for k, x in pairs(v) do
      if x == vim.NIL then
        v[k] = nil
      end
    end
  end
  return v
end

function Client:_dispatch(val)
  if type(val) ~= 'table' or #val < 3 then
    warn('invalid rpc msg: ' .. vim.inspect(val):sub(1, 200))
    return
  end

  local kind = val[1]
  if kind == 1 then
    local msgid, err, result = val[2], denil(val[3]), denil(val[4])
    local cb = self.pending[msgid]
    self.pending[msgid] = nil
    if cb then
      vim.schedule(function()
        cb(err, result)
      end)
    end
  elseif kind == 2 then
    local method, params = val[2], val[3]
    local h = self.handlers[method]
    if h then
      vim.schedule(function()
        h(params)
      end)
    end
  end
end

function Client:_write(payload)
  if not self.stdin or self.stdin:is_closing() then
    return
  end
  local n = #payload
  local hdr = string.char(
    bit.band(bit.rshift(n, 24), 0xff),
    bit.band(bit.rshift(n, 16), 0xff),
    bit.band(bit.rshift(n, 8), 0xff),
    bit.band(n, 0xff)
  )
  self.stdin:write(hdr .. payload)
end

function Client:call(method, params, cb)
  cb = cb or function() end
  if self.exited or self.closed then
    vim.schedule(function()
      cb(NOT_RUNNING, nil)
    end)
    return
  end

  local id = self.next_id
  self.next_id = self.next_id + 1
  self.pending[id] = cb
  self:_write(mpack.encode({ 0, id, method, { params or vim.empty_dict() } }))
end

function Client:on(method, handler)
  self.handlers[method] = handler
end

return M
