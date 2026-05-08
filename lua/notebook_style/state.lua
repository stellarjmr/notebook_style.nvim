local M = {}

local buffers = {}

local function default_buffer_state()
  return {
    session_id = nil,
    kernel_started = false,
    cells = {},
    outputs = {},
    execution_counts = {},
    statuses = {},
  }
end

function M.get(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  buffers[bufnr] = buffers[bufnr] or default_buffer_state()
  return buffers[bufnr]
end

function M.clear(bufnr)
  buffers[bufnr] = nil
end

function M.cell_key(bufnr, cell)
  return table.concat({ tostring(bufnr), tostring(cell.delimiter_text or ''), tostring(cell.ordinal or '') }, ':')
end

function M.cell_id(bufnr, cell)
  local state = M.get(bufnr)
  local key = M.cell_key(bufnr, cell)
  if not state.cells[key] then
    state.cells[key] = 'cell-' .. vim.fn.sha256(key):sub(1, 16)
  end
  return state.cells[key]
end

function M.outputs(bufnr, cell)
  local state = M.get(bufnr)
  return state.outputs[M.cell_id(bufnr, cell)] or {}
end

function M.execution_count(bufnr, cell)
  local state = M.get(bufnr)
  return state.execution_counts[M.cell_id(bufnr, cell)]
end

function M.status(bufnr, cell)
  local state = M.get(bufnr)
  return state.statuses[M.cell_id(bufnr, cell)]
end

function M.apply_event(bufnr, cell_id, event)
  local state = M.get(bufnr)
  local kind = event.kind

  if kind == 'execute_input' then
    state.outputs[cell_id] = {}
    state.execution_counts[cell_id] = event.execution_count
    state.statuses[cell_id] = 'busy'
  elseif kind == 'status' then
    state.statuses[cell_id] = event.state
  elseif kind == 'stream' then
    state.outputs[cell_id] = state.outputs[cell_id] or {}
    local outputs = state.outputs[cell_id]
    local last = outputs[#outputs]
    if last and last.output_type == 'stream' and last.name == event.name then
      last.text = (last.text or '') .. (event.text or '')
    else
      table.insert(outputs, {
        output_type = 'stream',
        name = event.name,
        text = event.text,
      })
    end
  elseif kind == 'execute_result' then
    state.outputs[cell_id] = state.outputs[cell_id] or {}
    state.execution_counts[cell_id] = event.execution_count
    table.insert(state.outputs[cell_id], {
      output_type = 'execute_result',
      execution_count = event.execution_count,
      data = event.data,
    })
  elseif kind == 'display_data' then
    state.outputs[cell_id] = state.outputs[cell_id] or {}
    table.insert(state.outputs[cell_id], {
      output_type = 'display_data',
      data = event.data,
      metadata = event.metadata,
    })
  elseif kind == 'error' then
    state.outputs[cell_id] = state.outputs[cell_id] or {}
    table.insert(state.outputs[cell_id], {
      output_type = 'error',
      ename = event.ename,
      evalue = event.evalue,
      traceback = event.traceback,
    })
    state.statuses[cell_id] = 'error'
  elseif kind == 'clear_output' and not event.wait then
    state.outputs[cell_id] = {}
  elseif kind == 'execute_reply' then
    state.statuses[cell_id] = event.status or 'idle'
  end
end

return M
