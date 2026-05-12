-- Minimal Kitty/Ghostty Unicode-placeholder image support.

local M = {}
local config = require('notebook_style.config')

local DIACRITICS = {
  0x0305,0x030D,0x030E,0x0310,0x0312,0x033D,0x033E,0x033F,0x0346,0x034A,
  0x034B,0x034C,0x0350,0x0351,0x0352,0x0357,0x035B,0x0363,0x0364,0x0365,
  0x0366,0x0367,0x0368,0x0369,0x036A,0x036B,0x036C,0x036D,0x036E,0x036F,
  0x0483,0x0484,0x0485,0x0486,0x0487,0x0592,0x0593,0x0594,0x0595,0x0597,
  0x0598,0x0599,0x059C,0x059D,0x059E,0x059F,0x05A0,0x05A1,0x05A8,0x05A9,
  0x05AB,0x05AC,0x05AF,0x05C4,0x0610,0x0611,0x0612,0x0613,0x0614,0x0615,
  0x0616,0x0617,0x0657,0x0658,0x0659,0x065A,0x065B,0x065D,0x065E,0x06D6,
  0x06D7,0x06D8,0x06D9,0x06DA,0x06DB,0x06DC,0x06DF,0x06E0,0x06E1,0x06E2,
  0x06E4,0x06E7,0x06E8,0x06EB,0x06EC,0x0730,0x0732,0x0733,0x0735,0x0736,
  0x073A,0x073D,0x073F,0x0740,0x0741,0x0743,0x0745,0x0747,0x0749,0x074A,
  0x07EB,0x07EC,0x07ED,0x07EE,0x07EF,0x07F0,0x07F1,0x07F3,0x0816,0x0817,
  0x0818,0x0819,0x081B,0x081C,0x081D,0x081E,0x0823,0x0825,0x0826,0x0827,
  0x0829,0x082A,0x082B,0x082C,0x082D,0x0951,0x0953,0x0954,0x0F82,0x0F83,
  0x0F86,0x0F87,0x135D,0x135E,0x135F,0x17DD,0x193A,0x1A17,0x1A75,0x1A76,
  0x1A77,0x1A78,0x1A79,0x1A7A,0x1A7B,0x1A7C,0x1B6B,0x1B6D,0x1B6E,0x1B6F,
  0x1B70,0x1B71,0x1B72,0x1B73,0x1CD0,0x1CD1,0x1CD2,0x1CDA,0x1CDB,0x1CE0,
  0x1DC0,0x1DC1,0x1DC3,0x1DC4,0x1DC5,0x1DC6,0x1DC7,0x1DC8,0x1DC9,0x1DCB,
  0x1DCC,0x1DD1,0x1DD2,0x1DD3,0x1DD4,0x1DD5,0x1DD6,0x1DD7,0x1DD8,0x1DD9,
  0x1DDA,0x1DDB,0x1DDC,0x1DDD,0x1DDE,0x1DDF,0x1DE0,0x1DE1,0x1DE2,0x1DE3,
  0x1DE4,0x1DE5,0x1DE6,0x1DFE,0x20D0,0x20D1,0x20D4,0x20D5,0x20D6,0x20D7,
  0x20DB,0x20DC,0x20E1,0x20E7,0x20E9,0x20F0,0x2CEF,0x2CF0,0x2CF1,0x2DE0,
  0x2DE1,0x2DE2,0x2DE3,0x2DE4,0x2DE5,0x2DE6,0x2DE7,0x2DE8,0x2DE9,0x2DEA,
  0x2DEB,0x2DEC,0x2DED,0x2DEE,0x2DEF,0x2DF0,0x2DF1,0x2DF2,0x2DF3,0x2DF4,
  0x2DF5,0x2DF6,0x2DF7,0x2DF8,0x2DF9,0x2DFA,0x2DFB,0x2DFC,0x2DFD,0x2DFE,
  0x2DFF,0xA66F,0xA67C,0xA67D,0xA6F0,0xA6F1,0xA8E0,0xA8E1,0xA8E2,0xA8E3,
  0xA8E4,0xA8E5,0xA8E6,0xA8E7,0xA8E8,0xA8E9,0xA8EA,0xA8EB,0xA8EC,0xA8ED,
  0xA8EE,0xA8EF,0xA8F0,0xA8F1,0xAAB0,0xAAB2,0xAAB3,0xAAB7,0xAAB8,0xAABE,
  0xAABF,0xAAC1,0xFE20,0xFE21,0xFE22,0xFE23,0xFE24,0xFE25,0xFE26,0x10A0F,
  0x10A38,0x1D185,0x1D186,0x1D187,0x1D188,0x1D189,0x1D1AA,0x1D1AB,0x1D1AC,
  0x1D1AD,0x1D242,0x1D243,0x1D244,
}


local PLACEHOLDER = 0x10EEEE
local CHUNK_SIZE = 4096

local attached = false
local attach_failed = false
local rpc_client = nil
local next_lua_image_id = 1000
local BASE64_VALUES = {}

for i = string.byte('A'), string.byte('Z') do
  BASE64_VALUES[string.char(i)] = i - string.byte('A')
end
for i = string.byte('a'), string.byte('z') do
  BASE64_VALUES[string.char(i)] = i - string.byte('a') + 26
end
for i = string.byte('0'), string.byte('9') do
  BASE64_VALUES[string.char(i)] = i - string.byte('0') + 52
end
BASE64_VALUES['+'] = 62
BASE64_VALUES['/'] = 63
BASE64_VALUES['-'] = 62
BASE64_VALUES['_'] = 63

local function utf8(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + (cp % 0x40)
    )
  else
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + math.floor(cp / 0x1000) % 0x40,
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + (cp % 0x40)
    )
  end
end

local function ensure_hl(image_id)
  local hl = 'NotebookStyleImage_' .. image_id
  local r = bit.band(bit.rshift(image_id, 16), 0xff)
  local g = bit.band(bit.rshift(image_id, 8), 0xff)
  local b = bit.band(image_id, 0xff)
  if r == 0 and g == 0 and b == 0 then
    b = 1
  end
  vim.api.nvim_set_hl(0, hl, { fg = string.format('#%02x%02x%02x', r, g, b) })
  return hl
end

local function alloc_lua_image_id()
  local image_id = next_lua_image_id
  next_lua_image_id = next_lua_image_id + 1
  return image_id
end

local function build_transmit_escape(image_id, b64, cols, rows)
  local total = #b64
  local pos = 1
  local chunks = {}
  local first = true

  while pos <= total do
    local stop = math.min(pos + CHUNK_SIZE - 1, total)
    local chunk = b64:sub(pos, stop)
    local more = stop < total and 1 or 0
    if first then
      table.insert(
        chunks,
        string.format('\27_Ga=t,U=1,f=100,i=%d,q=2,m=%d;%s\27\\', image_id, more, chunk)
      )
      first = false
    else
      table.insert(chunks, string.format('\27_Gm=%d,q=2;%s\27\\', more, chunk))
    end
    pos = stop + 1
  end

  table.insert(chunks, string.format('\27_Ga=p,U=1,i=%d,c=%d,r=%d,q=2\27\\', image_id, cols, rows))

  return table.concat(chunks)
end

local function in_tmux()
  return vim.env.TMUX ~= nil
    and vim.env.TMUX ~= ''
    and not (vim.env.NOTEBOOK_STYLE_DISABLE_TMUX_PASSTHROUGH ~= nil and vim.env.NOTEBOOK_STYLE_DISABLE_TMUX_PASSTHROUGH ~= '')
end

local function tmux_wrap(bytes)
  local doubled = bytes:gsub('\27', '\27\27')
  return '\27Ptmux;' .. doubled .. '\27\\'
end

local function write_to_terminal(bytes)
  if in_tmux() then
    bytes = tmux_wrap(bytes)
  end

  if vim.v.stderr and vim.v.stderr ~= 0 then
    local ok = pcall(vim.api.nvim_chan_send, vim.v.stderr, bytes)
    if ok then
      return true
    end
  end

  local ok = pcall(function()
    io.stdout:write(bytes)
    io.stdout:flush()
  end)
  if ok then
    return true
  end

  local tty = vim.env.NOTEBOOK_STYLE_TTY or vim.env.JUPYNVIM_TTY or '/dev/tty'
  local file = io.open(tty, 'wb')
  if file then
    local wrote = pcall(function()
      file:write(bytes)
      file:close()
    end)
    return wrote
  end

  return false
end

local function transmit_from_lua(b64, cols, rows)
  if not M.supported() then
    return nil, 'terminal does not advertise Kitty graphics support'
  end

  local image_id = alloc_lua_image_id()
  local ok = write_to_terminal(build_transmit_escape(image_id, b64, cols, rows))
  if not ok then
    return nil, 'failed to write Kitty graphics escape to terminal'
  end

  return image_id
end

function M.supported()
  local term = ((vim.env.TERM_PROGRAM or '') .. ' ' .. (vim.env.TERM or '')):lower()
  return term:find('ghostty') ~= nil or term:find('kitty') ~= nil or vim.env.KITTY_WINDOW_ID ~= nil or vim.env.GHOSTTY_RESOURCES_DIR ~= nil
end

function M.attach(client, callback)
  rpc_client = client
  if attached then
    if callback then callback(true) end
    return
  end
  if attach_failed or not M.supported() then
    if callback then callback(false) end
    return
  end

  local tty = vim.env.NOTEBOOK_STYLE_TTY or vim.env.JUPYNVIM_TTY or '/dev/tty'
  client:call('kitty_attach', { tty = tty }, function(err)
    if err then
      attach_failed = true
      if callback then callback(false, err) end
      return
    end
    attached = true
    if callback then callback(true) end
  end)
end

local function configured_size()
  local image_opts = config.options.image or config.defaults.image
  local default_image_opts = config.defaults.image or {}
  local cols = tonumber(image_opts and image_opts.cols) or default_image_opts.cols
  local rows = tonumber(image_opts and image_opts.rows) or default_image_opts.rows

  return math.max(1, math.floor(cols)), math.max(1, math.floor(rows))
end

local function configured_cell_height_to_width()
  local image_opts = config.options.image or config.defaults.image
  local default_image_opts = config.defaults.image or {}
  local ratio = tonumber(image_opts and image_opts.cell_height_to_width)
    or default_image_opts.cell_height_to_width
    or 2.0
  return math.max(0.1, ratio)
end

local function decode_base64_prefix(value, max_bytes)
  local out = {}
  local buffer = 0
  local bits = 0

  value = value:gsub('%s+', '')
  for i = 1, #value do
    local char = value:sub(i, i)
    if char == '=' then
      break
    end

    local decoded = BASE64_VALUES[char]
    if decoded then
      buffer = buffer * 64 + decoded
      bits = bits + 6
      while bits >= 8 do
        bits = bits - 8
        local byte = bit.band(bit.rshift(buffer, bits), 0xff)
        table.insert(out, string.char(byte))
        if #out >= max_bytes then
          return table.concat(out)
        end
      end
      if bits > 0 then
        buffer = bit.band(buffer, bit.lshift(1, bits) - 1)
      else
        buffer = 0
      end
    end
  end

  return table.concat(out)
end

local function read_u32_be(bytes, offset)
  local b1, b2, b3, b4 = bytes:byte(offset, offset + 3)
  if not b4 then
    return nil
  end
  return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
end

local function png_dimensions(b64)
  if type(b64) ~= 'string' or b64 == '' then
    return nil, nil
  end

  local header = decode_base64_prefix(b64, 24)
  if #header < 24 or header:sub(1, 8) ~= '\137PNG\r\n\26\n' or header:sub(13, 16) ~= 'IHDR' then
    return nil, nil
  end

  return read_u32_be(header, 17), read_u32_be(header, 21)
end

local function fit_cols_to_png(max_cols, rows, b64)
  local width, height = png_dimensions(b64)
  if not width or not height or height <= 0 then
    return max_cols
  end

  local cell_ratio = configured_cell_height_to_width()
  local fitted = math.floor(rows * (width / height) * cell_ratio + 0.5)
  return math.max(1, math.min(max_cols, fitted))
end

function M.pick_size(inner_width, b64)
  local configured_cols, rows = configured_size()
  local max_cols = math.max(1, math.min(configured_cols, inner_width or configured_cols))
  local cols = fit_cols_to_png(max_cols, rows, b64)
  return cols, rows
end

function M.ensure_transmitted(output, client, inner_width, callback)
  if not output or not output.data then
    return
  end
  if output.inline_image and (output.inline_image.status == 'ready' or output.inline_image.status == 'pending') then
    return
  end

  local b64 = output.data['image/png']
  if type(b64) == 'table' then
    b64 = table.concat(b64, '')
  end
  if type(b64) ~= 'string' or b64 == '' then
    return
  end

  output.inline_image = { status = 'pending' }

  local cols, rows = M.pick_size(inner_width, b64)
  local function fallback(err)
    local image_id, fallback_err = transmit_from_lua(b64, cols, rows)
    if image_id then
      output.inline_image = {
        status = 'ready',
        image_id = image_id,
        cols = cols,
        rows = rows,
        transport = 'nvim',
      }
      if callback then callback(true) end
      return
    end

    output.inline_image = { status = 'failed', error = fallback_err or err }
    if callback then callback(false) end
  end

  M.attach(client, function(ok, err)
    if not ok then
      fallback(err)
      return
    end

    client:call('kitty_transmit', { png_b64 = b64, cols = cols, rows = rows }, function(tx_err, result)
      if tx_err then
        fallback(tx_err)
        return
      end
      output.inline_image = {
        status = 'ready',
        image_id = result.image_id,
        cols = result.cols or cols,
        rows = result.rows or rows,
      }
      if callback then callback(true) end
    end)
  end)
end

function M.placeholder_rows(inline_image)
  if not inline_image or inline_image.status ~= 'ready' then
    return nil
  end

  local image_id = inline_image.image_id
  local default_cols, default_rows = configured_size()
  local rows = inline_image.rows or default_rows
  local cols = inline_image.cols or default_cols
  local hl = ensure_hl(image_id)
  local placeholder = utf8(PLACEHOLDER)
  local out = {}

  for row = 0, rows - 1 do
    local row_d = utf8(DIACRITICS[row + 1] or DIACRITICS[1])
    local text = ''
    for col = 0, cols - 1 do
      local col_d = utf8(DIACRITICS[col + 1] or DIACRITICS[1])
      text = text .. placeholder .. row_d .. col_d
    end
    table.insert(out, { { text, hl } })
  end

  return out, cols
end

function M.clear(output, client)
  local inline_image = output and output.inline_image
  if inline_image and inline_image.image_id and client then
    client:call('kitty_clear', { image_id = inline_image.image_id }, function() end)
  end
end

return M
