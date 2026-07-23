local M = {}

local function add_mark(marks, mark)
  if mark.kind == 'conceal' or mark.kind == 'hl' then
    if mark.end_col <= mark.col then
      return
    end
  end
  table.insert(marks, mark)
end

local function conceal(marks, col, end_col)
  add_mark(marks, { kind = 'conceal', col = col, end_col = end_col })
end

local function highlight(marks, col, end_col, group)
  add_mark(marks, { kind = 'hl', col = col, end_col = end_col, hl = group })
end

local function virtual_text(marks, col, text, group)
  add_mark(marks, {
    kind = 'virt',
    col = col,
    chunks = { { text, group } },
  })
end

local function trim(text)
  return text:match('^%s*(.-)%s*$')
end

--- Extract Markdown content from a Jupytext comment line.
--- Returned columns are zero-based byte offsets in the original line.
local function comment_content(raw)
  local leading = raw:match('^(%s*)') or ''
  local hash_col = #leading
  if raw:sub(hash_col + 1, hash_col + 1) ~= '#' then
    return nil
  end

  local next_char = raw:sub(hash_col + 2, hash_col + 2)
  if next_char == '' then
    return '', hash_col, hash_col + 1
  end
  if next_char ~= ' ' and next_char ~= '\t' then
    return nil
  end

  return raw:sub(hash_col + 3), hash_col, hash_col + 2
end

local function find_balanced(text, start_pos, open_char, close_char)
  local depth = 0
  local pos = start_pos
  while pos <= #text do
    local char = text:sub(pos, pos)
    if char == '\\' then
      pos = pos + 2
    else
      if char == open_char then
        depth = depth + 1
      elseif char == close_char then
        depth = depth - 1
        if depth == 0 then
          return pos
        end
      end
      pos = pos + 1
    end
  end
  return nil
end

local function link_at(text, pos)
  local image = text:sub(pos, pos + 1) == '!['
  local open_pos = image and (pos + 1) or pos
  if text:sub(open_pos, open_pos) ~= '[' then
    return nil
  end

  local label_end = find_balanced(text, open_pos, '[', ']')
  if not label_end or text:sub(label_end + 1, label_end + 1) ~= '(' then
    return nil
  end

  local target_end = find_balanced(text, label_end + 1, '(', ')')
  if not target_end then
    return nil
  end

  return {
    image = image,
    start_pos = pos,
    open_pos = open_pos,
    label_end = label_end,
    target_end = target_end,
  }
end

local inline_markers = {
  { marker = '***', hl = 'NotebookMarkdownBoldItalic' },
  { marker = '___', hl = 'NotebookMarkdownBoldItalic' },
  { marker = '**', hl = 'NotebookMarkdownBold' },
  { marker = '__', hl = 'NotebookMarkdownBold' },
  { marker = '~~', hl = 'NotebookMarkdownStrike' },
  { marker = '*', hl = 'NotebookMarkdownItalic' },
  { marker = '_', hl = 'NotebookMarkdownItalic' },
}

local function underscore_is_word_internal(text, pos, marker_length)
  local before = text:sub(pos - 1, pos - 1)
  local after = text:sub(pos + marker_length, pos + marker_length)
  return before:match('[%w]') ~= nil and after:match('[%w]') ~= nil
end

local function parse_inline(text, base_col, marks)
  local pos = 1
  while pos <= #text do
    local char = text:sub(pos, pos)
    if char == '\\' and pos < #text then
      pos = pos + 2
    else
      local link = link_at(text, pos)
      if link then
        local opening_end = link.open_pos + 1
        conceal(marks, base_col + link.start_pos - 1, base_col + opening_end - 1)
        highlight(marks, base_col + link.open_pos, base_col + link.label_end - 1, 'NotebookMarkdownLink')
        conceal(marks, base_col + link.label_end - 1, base_col + link.target_end)
        if link.image then
          virtual_text(marks, base_col + link.start_pos - 1, '▣ ', 'NotebookMarkdownLink')
        end
        pos = link.target_end + 1
      elseif char == '`' then
        local marker_end = pos
        while text:sub(marker_end + 1, marker_end + 1) == '`' do
          marker_end = marker_end + 1
        end
        local marker = text:sub(pos, marker_end)
        local close = text:find(marker, marker_end + 1, true)
        if close and close > marker_end + 1 then
          conceal(marks, base_col + pos - 1, base_col + marker_end)
          highlight(marks, base_col + marker_end, base_col + close - 1, 'NotebookMarkdownCode')
          conceal(marks, base_col + close - 1, base_col + close + #marker - 1)
          pos = close + #marker
        else
          pos = marker_end + 1
        end
      else
        local matched = false
        for _, item in ipairs(inline_markers) do
          local marker = item.marker
          if text:sub(pos, pos + #marker - 1) == marker
            and not (marker:sub(1, 1) == '_' and underscore_is_word_internal(text, pos, #marker))
          then
            local close = text:find(marker, pos + #marker, true)
            if close and close > pos + #marker and text:sub(pos + #marker, close - 1):match('%S') then
              local close_is_internal = marker:sub(1, 1) == '_'
                and underscore_is_word_internal(text, close, #marker)
              if not close_is_internal then
                conceal(marks, base_col + pos - 1, base_col + pos + #marker - 1)
                highlight(marks, base_col + pos + #marker - 1, base_col + close - 1, item.hl)
                conceal(marks, base_col + close - 1, base_col + close + #marker - 1)
                pos = close + #marker
                matched = true
                break
              end
            end
          end
        end
        if not matched then
          pos = pos + 1
        end
      end
    end
  end
end

local function fence(text)
  local indent, marker, info = text:match('^(%s*)(```+)%s*(.-)%s*$')
  if not marker then
    indent, marker, info = text:match('^(%s*)(~~~+)%s*(.-)%s*$')
  end
  if not marker then
    return nil
  end
  return {
    indent = indent,
    marker = marker:sub(1, 1),
    length = #marker,
    marker_text = marker,
    info = info,
  }
end

local function is_rule(text)
  local compact = trim(text):gsub('%s', '')
  if #compact < 3 then
    return false
  end
  local marker = compact:sub(1, 1)
  return (marker == '-' or marker == '*' or marker == '_')
    and compact == string.rep(marker, #compact)
end

local function is_table_separator(text)
  local value = trim(text)
  if not value:find('|', 1, true) then
    return false
  end
  value = value:gsub('^|', ''):gsub('|$', '')

  local count = 0
  for part in (value .. '|'):gmatch('(.-)|') do
    local compact = trim(part):gsub('%s', '')
    compact = compact:gsub('^:', ''):gsub(':$', '')
    if #compact < 3 or not compact:match('^%-+$') then
      return false
    end
    count = count + 1
  end
  return count > 0
end

local function highlight_table_pipes(text, base_col, marks)
  local pos = 1
  while pos <= #text do
    local char = text:sub(pos, pos)
    if char == '\\' then
      pos = pos + 2
    elseif char == '|' then
      highlight(marks, base_col + pos - 1, base_col + pos, 'NotebookMarkdownTableBorder')
      pos = pos + 1
    else
      pos = pos + 1
    end
  end
end

local function parse_regular_line(text, base_col, marks, table_header, table_line)
  local _, marker_end, indent, hashes = text:find('^(%s*)(#+)%s+')
  if hashes and #hashes <= 6 then
    local marker_start = base_col + #indent
    local content_col = base_col + marker_end
    conceal(marks, marker_start, content_col)
    virtual_text(marks, marker_start, '▌ ', 'NotebookMarkdownH' .. #hashes)
    highlight(marks, content_col, base_col + #text, 'NotebookMarkdownH' .. #hashes)
    parse_inline(text:sub(marker_end + 1), content_col, marks)
    return
  end

  if is_rule(text) then
    conceal(marks, base_col, base_col + #text)
    virtual_text(marks, base_col, '────────────────────────', 'NotebookMarkdownRule')
    return
  end

  local list_indent, bullet, spacing, body = text:match('^(%s*)([-+*])(%s+)(.*)$')
  if bullet then
    local marker_start = base_col + #list_indent
    local body_col = marker_start + #bullet + #spacing
    local checked, task_spacing, task_body = body:match('^%[([ xX%-])%](%s+)(.*)$')
    if checked then
      local task_col = body_col + 3 + #task_spacing
      conceal(marks, marker_start, task_col)
      local icon = checked == ' ' and '☐ ' or (checked == '-' and '◩ ' or '☑ ')
      local group = checked == ' '
          and 'NotebookMarkdownUnchecked'
        or (checked == '-' and 'NotebookMarkdownTodo' or 'NotebookMarkdownChecked')
      virtual_text(marks, marker_start, icon, group)
      parse_inline(task_body, task_col, marks)
    else
      conceal(marks, marker_start, body_col)
      virtual_text(marks, marker_start, '• ', 'NotebookMarkdownBullet')
      parse_inline(body, body_col, marks)
    end
    return
  end

  local ordered_indent, ordered, ordered_spacing, ordered_body = text:match('^(%s*)(%d+[.)])(%s+)(.*)$')
  if ordered then
    local marker_start = base_col + #ordered_indent
    highlight(marks, marker_start, marker_start + #ordered, 'NotebookMarkdownBullet')
    parse_inline(ordered_body, marker_start + #ordered + #ordered_spacing, marks)
    return
  end

  local quote_indent, quote, quote_spacing, quote_body = text:match('^(%s*)(>+)(%s?)(.*)$')
  if quote then
    local marker_start = base_col + #quote_indent
    local body_col = marker_start + #quote + #quote_spacing
    conceal(marks, marker_start, body_col)
    virtual_text(marks, marker_start, string.rep('▌ ', #quote), 'NotebookMarkdownQuote')
    parse_inline(quote_body, body_col, marks)
    return
  end

  if table_header then
    highlight(marks, base_col, base_col + #text, 'NotebookMarkdownTableHeader')
  end
  if table_line then
    highlight_table_pipes(text, base_col, marks)
  end
  parse_inline(text, base_col, marks)
end

--- Parse Jupytext Markdown comment lines into source-aligned decorations.
--- The parser never rewrites or overlays complete source lines; it returns
--- byte ranges that render.lua can conceal or highlight with extmarks.
--- @param lines string[] Raw Python buffer lines from a Markdown cell body
--- @return table[] Decorations keyed by zero-based line offsets
function M.parse(lines)
  local source = {}
  for index, raw in ipairs(lines) do
    local text, prefix_col, base_col = comment_content(raw)
    source[index] = {
      text = text,
      prefix_col = prefix_col,
      base_col = base_col,
    }
  end

  local decorations = {}
  local active_fence
  local table_start = 0
  local table_until = 0

  for index, info in ipairs(source) do
    if info.text ~= nil then
      local marks = {}
      conceal(marks, info.prefix_col, info.base_col)

      local current_fence = fence(info.text)
      if active_fence then
        local closes = current_fence
          and current_fence.marker == active_fence.marker
          and current_fence.length >= active_fence.length
          and trim(info.text):match('^[`~]+$')
        if closes then
          conceal(marks, info.base_col, info.base_col + #info.text)
          active_fence = nil
        else
          highlight(marks, info.base_col, info.base_col + #info.text, 'NotebookMarkdownCodeBlock')
        end
      elseif current_fence then
        local marker_start = info.base_col + #current_fence.indent
        conceal(marks, marker_start, marker_start + #current_fence.marker_text)
        virtual_text(marks, marker_start, '▌ ', 'NotebookMarkdownCodeInfo')
        if current_fence.info ~= '' then
          local info_start = info.text:find(current_fence.info, 1, true)
          if info_start then
            highlight(
              marks,
              info.base_col + info_start - 1,
              info.base_col + info_start + #current_fence.info - 1,
              'NotebookMarkdownCodeInfo'
            )
          end
        end
        active_fence = current_fence
      else
        local next_info = source[index + 1]
        if info.text:find('|', 1, true) and next_info and next_info.text and is_table_separator(next_info.text) then
          table_start = index
          table_until = index + 1
          local following = index + 2
          while source[following]
            and source[following].text
            and source[following].text:find('|', 1, true)
          do
            table_until = following
            following = following + 1
          end
        end
        local table_line = index <= table_until
        parse_regular_line(info.text, info.base_col, marks, table_line and index == table_start, table_line)
      end

      if #marks > 0 then
        table.insert(decorations, { line = index - 1, marks = marks })
      end
    end
  end

  return decorations
end

return M
