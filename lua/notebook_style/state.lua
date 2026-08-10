local M = {}

local buffers = {}

-- Namespace holding one invisible extmark per cell delimiter line. The
-- extmark id is the stable cell identity: extmarks move with text edits, so
-- outputs follow their cell when cells are inserted, moved, or renamed.
local identity_ns = vim.api.nvim_create_namespace('notebook_style_cell_identity')

M.identity_ns = identity_ns

-- Optional callback invoked with the outputs of a garbage-collected cell so
-- the execution layer can release resources (e.g. transmitted images).
local on_outputs_dropped

function M.set_on_outputs_dropped(fn)
  on_outputs_dropped = fn
end

local function default_buffer_state()
  return {
    session_id = nil,
    kernel_started = false,
    selected_kernel_name = nil,
    mark_delimiters = {},  -- extmark id -> last delimiter text seen on that mark
    active_cells = {},  -- cell id -> true while its identity mark exists
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
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, identity_ns, 0, -1)
  end
end

local function to_cell_id(bufnr, mark_id)
  return string.format('cell-%d-%d', bufnr, mark_id)
end

--- Delete an identity mark together with the state it owns.
local function drop_mark(bufnr, state, mark_id)
  pcall(vim.api.nvim_buf_del_extmark, bufnr, identity_ns, mark_id)
  local cell_id = to_cell_id(bufnr, mark_id)
  local outputs = state.outputs[cell_id]
  state.outputs[cell_id] = nil
  state.execution_counts[cell_id] = nil
  state.statuses[cell_id] = nil
  state.mark_delimiters[mark_id] = nil
  state.active_cells[cell_id] = nil
  if outputs and #outputs > 0 and on_outputs_dropped then
    pcall(on_outputs_dropped, outputs)
  end
end

--- Resolve a stable identity for a cell, anchored to an extmark on its
--- delimiter line. The extmark is created lazily on first use.
---
--- The mark is anchored at the *end* of the delimiter line with left gravity:
--- line insertions above (which happen at column 0) shift it with its line,
--- and replacing the whole delimiter line collapses it to column 0 of the
--- same row instead of pushing it onto the next line. A mark that collapsed
--- here from a deleted cell therefore sits at column 0, while the mark that
--- belongs to this delimiter keeps a non-zero column.
function M.cell_id(bufnr, cell)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = M.get(bufnr)

  local row = cell.delimiter or cell.start_line or 0
  local last_row = math.max(vim.api.nvim_buf_line_count(bufnr) - 1, 0)
  row = math.min(math.max(row, 0), last_row)

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, identity_ns, { row, 0 }, { row, -1 }, {})
  local mark_id

  if #marks == 1 then
    mark_id = marks[1][1]
  elseif #marks > 1 then
    -- Several identity marks collided on this delimiter line, e.g. a deleted
    -- cell's mark collapsed onto the next delimiter. Prefer marks still at
    -- their end-of-line anchor (column > 0), then a matching delimiter text,
    -- and drop the leftovers together with their state.
    local candidates = {}
    for _, mark in ipairs(marks) do
      if mark[3] > 0 then
        table.insert(candidates, mark)
      end
    end
    if #candidates == 0 then
      candidates = marks
    end
    for _, mark in ipairs(candidates) do
      if state.mark_delimiters[mark[1]] == cell.delimiter_text then
        mark_id = mark[1]
        break
      end
    end
    mark_id = mark_id or candidates[1][1]
    for _, mark in ipairs(marks) do
      if mark[1] ~= mark_id then
        drop_mark(bufnr, state, mark[1])
      end
    end
  end

  -- Create the mark, or re-anchor the adopted one to the current line end.
  mark_id = vim.api.nvim_buf_set_extmark(bufnr, identity_ns, row, #(cell.delimiter_text or ''), {
    id = mark_id,
    right_gravity = false,
    strict = false,
  })

  local cell_id = to_cell_id(bufnr, mark_id)
  state.mark_delimiters[mark_id] = cell.delimiter_text
  state.active_cells[cell_id] = true
  return cell_id
end

--- Garbage-collect identity marks that no longer sit on a cell delimiter, so
--- outputs of deleted cells do not attach to unrelated cells later.
--- @param bufnr number Buffer number
--- @param cell_list table Cells from cells.get_cells for the current buffer text
function M.sync_cells(bufnr, cell_list)
  local state = buffers[bufnr]
  if not state or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local anchors = {}
  for _, cell in ipairs(cell_list or {}) do
    anchors[cell.delimiter or cell.start_line or 0] = true
  end

  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, identity_ns, 0, -1, {})) do
    if not anchors[mark[2]] then
      drop_mark(bufnr, state, mark[1])
    end
  end
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

--- Reset all cell statuses, e.g. after stopping or restarting the kernel so
--- cells killed mid-run do not stay marked as busy forever.
function M.clear_statuses(bufnr)
  M.get(bufnr).statuses = {}
end

function M.set_kernel_name(bufnr, kernel_name)
  M.get(bufnr).selected_kernel_name = kernel_name
end

function M.kernel_name(bufnr)
  return M.get(bufnr).selected_kernel_name
end

function M.clear_cell_output(bufnr, cell)
  local state = M.get(bufnr)
  local cell_id = M.cell_id(bufnr, cell)
  local outputs = state.outputs[cell_id] or {}
  state.outputs[cell_id] = {}
  state.execution_counts[cell_id] = nil
  state.statuses[cell_id] = nil
  return outputs, cell_id
end

function M.clear_outputs(bufnr)
  local state = M.get(bufnr)
  local outputs = state.outputs
  state.outputs = {}
  state.execution_counts = {}
  state.statuses = {}
  return outputs
end

function M.apply_event(bufnr, cell_id, event)
  local state = M.get(bufnr)

  -- Ignore late events for cells that were garbage-collected (or a cleared
  -- buffer), so async kernel output cannot resurrect orphaned state.
  if not state.active_cells[cell_id] then
    return
  end

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
      return last
    else
      local output = {
        output_type = 'stream',
        name = event.name,
        text = event.text,
      }
      table.insert(outputs, output)
      return output
    end
  elseif kind == 'execute_result' then
    state.outputs[cell_id] = state.outputs[cell_id] or {}
    state.execution_counts[cell_id] = event.execution_count
    local output = {
      output_type = 'execute_result',
      execution_count = event.execution_count,
      data = event.data,
    }
    table.insert(state.outputs[cell_id], output)
    return output
  elseif kind == 'display_data' then
    state.outputs[cell_id] = state.outputs[cell_id] or {}
    local output = {
      output_type = 'display_data',
      data = event.data,
      metadata = event.metadata,
    }
    table.insert(state.outputs[cell_id], output)
    return output
  elseif kind == 'error' then
    state.outputs[cell_id] = state.outputs[cell_id] or {}
    local output = {
      output_type = 'error',
      ename = event.ename,
      evalue = event.evalue,
      traceback = event.traceback,
    }
    table.insert(state.outputs[cell_id], output)
    state.statuses[cell_id] = 'error'
    return output
  elseif kind == 'clear_output' and not event.wait then
    state.outputs[cell_id] = {}
  elseif kind == 'execute_reply' then
    state.statuses[cell_id] = event.status or 'idle'
  end
end

return M
