local M = {}

M.label = nil

local function buffer_label(buf, name, buftype)
  if M.label then
    local custom = M.label(buf, name, buftype)
    if custom then return custom end
  end
  if buftype == 'terminal' then
    return 'term: ' .. (require('muxim.terminal').label(buf) or 'shell')
  end
  return nil
end

function M.summary()
  local lines = {}
  lines[#lines + 1] = 'cwd  ' .. vim.fn.fnamemodify(vim.fn.getcwd(-1, -1), ':~')
  lines[#lines + 1] = ''
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local win = vim.api.nvim_tabpage_get_win(tab)
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    local label
    if vim.bo[buf].buftype == 'terminal' then
      label = require('muxim.terminal').label(buf) or 'terminal'
    elseif name == '' then
      label = '[No Name]'
    else
      label = vim.fn.fnamemodify(name, ':t')
      if label == '' then
        label = vim.fn.fnamemodify(name, ':h:t')
      end
    end
    lines[#lines + 1] = ('tab %d  %s  (%d win)')
        :format(i, label, #require('muxim.tabline').content_windows(tab))
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'buffers'
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local buftype = vim.bo[buf].buftype
      local name = vim.api.nvim_buf_get_name(buf)
      local special = buffer_label(buf, name, buftype)
      if special then
        lines[#lines + 1] = '  ' .. special
      elseif buftype == '' and vim.bo[buf].buflisted and name ~= '' then
        lines[#lines + 1] = '  ' .. vim.fn.fnamemodify(name, ':~:.') .. (vim.bo[buf].modified and ' [+]' or '')
      end
    end
  end
  return table.concat(lines, '\n')
end

M.PREVIEW_LINES = 300

M.LABEL_WIDTH = 22

local function tab_root(index)
  local root = vim.fn.getcwd(-1, index)
  if root == vim.fn.getcwd(-1, -1) then return nil end
  return vim.fn.fnamemodify(root, ':~')
end

function M.info()
  local agents = require('muxim.agents')
  local terminal = require('muxim.terminal')
  local tabline = require('muxim.tabline')
  local children, commands, _, elapsed = agents.process_scan()
  local by_tab = {}
  for _, entry in ipairs(agents.tracked()) do
    if entry.tab then
      by_tab[entry.tab] = by_tab[entry.tab] or {}
      table.insert(by_tab[entry.tab],
        { name = entry.name, state = entry.state, detail = entry.detail })
    end
  end
  local current = vim.api.nvim_get_current_tabpage()
  local windows = {}
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local wins = tabline.content_windows(tab)
    local jobs = {}
    for _, win in ipairs(wins) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype == 'terminal' then
        local pid = tonumber(vim.b[buf].terminal_job_pid)
        local name, since, busy
        if pid then name, since, busy = agents.running_in(children, commands, elapsed, pid) end
        jobs[#jobs + 1] = {
          name = name or terminal.label(buf) or 'terminal',
          elapsed = since,
          busy = busy or false,
        }
      end
    end
    windows[i] = {
      index = i,
      label = tabline.tab_label(tab),
      current = tab == current,
      panes = #wins,
      root = tab_root(i),
      agents = by_tab[tab] or {},
      jobs = jobs,
    }
  end
  local payload = {
    name = require('muxim.runtime').display_name(require('muxim.server').self_path or ''),
    cwd = vim.fn.fnamemodify(vim.fn.getcwd(-1, -1), ':~'),
    windows = windows,
    modified = require('muxim.server').modified_here(),
  }
  local ok, encoded = pcall(vim.json.encode, payload)
  return ok and encoded or vim.json.encode({ windows = {}, modified = {} })
end

local function pad(text, width)
  return text .. string.rep(' ', math.max(1, width - vim.fn.strdisplaywidth(text)))
end

function M.render(info)
  local agents = require('muxim.agents')
  local lines, marks = {}, {}
  local function add(text, group, col)
    lines[#lines + 1] = text
    if group then
      marks[#marks + 1] = { line = #lines, col = col or 0, end_col = #text, group = group }
    end
    return #lines
  end
  add(info.name or 'session', 'MuximPreviewHeading')
  add(info.cwd or '', 'MuximPreviewPath')
  add('')
  for _, window in ipairs(info.windows or {}) do
    local head = ('%s%d  %s'):format(window.current and '* ' or '  ', window.index, window.label or '')
    local parts = {}
    if window.root then parts[#parts + 1] = window.root end
    if window.panes > 1 then parts[#parts + 1] = window.panes .. ' panes' end
    local detail = table.concat(parts, '  ')
    if detail == '' then
      add(head)
    else
      local text = pad(head, M.LABEL_WIDTH)
      marks[#marks + 1] =
          { line = #lines + 1, col = #text, end_col = #text + #detail, group = 'MuximPreviewPath' }
      add(text .. detail)
    end
    for _, agent in ipairs(window.agents or {}) do
      local mark = agents.MARKS[agent.state] or ' '
      local row = ('      %s %s  %s'):format(mark, agent.name or 'agent', agent.detail or agent.state or '')
      add(row, agents.STATE_GROUPS[agent.state] or 'MuximAgentIdle', 6)
    end
    for _, job in ipairs(window.jobs or {}) do
      local row = ('      %s %s'):format(job.busy and '>' or '$', job.name)
      if job.elapsed then row = pad(row, M.LABEL_WIDTH) .. job.elapsed end
      add(row, job.busy and 'MuximPreviewJob' or 'MuximAgentIdle', 6)
    end
  end
  if #(info.modified or {}) > 0 then
    add('')
    add('unsaved', 'MuximPreviewHeading')
    for _, name in ipairs(info.modified) do
      add('  ' .. name, 'MuximAgentBlocked', 2)
    end
  end
  return lines, marks
end

function M.preview_async(entry, callback)
  local server = require('muxim.server')
  local function render(raw)
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= 'table' then return false end
    callback(M.render(decoded))
    return true
  end
  if not entry.path or entry.path == server.self_path then
    return render(M.info())
  end
  if not vim.uv.fs_stat(entry.path) then
    return callback(entry.dir and M.dir_lines(entry.dir) or { 'not running' }, {})
  end
  callback({ 'loading...' }, {})
  vim.system({ vim.v.progpath, '--server', entry.path, '--remote-expr',
    "v:lua.require'muxim.session'.info()" },
    { text = true, timeout = 1000 }, function(result)
      vim.schedule(function()
        local raw = result.code == 0 and (result.stdout or ''):gsub('\n$', '') or ''
        if not render(raw) then
          M.lines_async(entry, function(lines) callback(lines, {}) end)
        end
      end)
    end)
end

local ELLIPSIS = '…'

function M.fit(line, width)
  if not width or width < 1 or vim.fn.strdisplaywidth(line) <= width then return line end
  local chars = vim.fn.strchars(line)
  local room = width - vim.fn.strdisplaywidth(ELLIPSIS)
  while chars > 0 do
    local cut = vim.fn.strcharpart(line, 0, chars)
    if vim.fn.strdisplaywidth(cut) <= room then return cut .. ELLIPSIS end
    chars = chars - 1
  end
  return ELLIPSIS
end

function M.window_view(win, height, width)
  local buf = vim.api.nvim_win_get_buf(win)
  local total = vim.api.nvim_buf_line_count(buf)
  height = math.max(1, math.min(height or M.PREVIEW_LINES, M.PREVIEW_LINES))
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  local top = math.max(1, vim.fn.line('w0', win))
  if cursor < top or cursor > top + height - 1 then
    top = math.max(1, cursor - math.floor(height / 2))
  end
  if total - top + 1 < height then
    top = math.max(1, total - height + 1)
  end
  local lines = vim.api.nvim_buf_get_lines(buf, top - 1, top - 1 + height, false)
  if width and width > 0 then
    for i, line in ipairs(lines) do
      lines[i] = M.fit(line, width)
    end
  end
  return {
    filetype = vim.bo[buf].filetype,
    lines = lines,
    top = top,
    total = total,
    cursor = cursor - top + 1,
  }
end

function M.tab_lines(index, height, width)
  local tabs = vim.api.nvim_list_tabpages()
  local tab = tabs[tonumber(index) or 0]
  if not tab then
    return vim.json.encode({ lines = { '(no such window)' } })
  end
  local ok, payload = pcall(M.window_view,
    require('muxim.tabline').content_window(tab), tonumber(height), tonumber(width))
  if not ok then
    return vim.json.encode({ lines = { '(no window to preview)' } })
  end
  local encoded
  ok, encoded = pcall(vim.json.encode, payload)
  if ok then return encoded end
  return vim.json.encode({ lines = { '(buffer is not text)' } })
end

function M.tab_lines_async(entry, callback, height, width)
  local server = require('muxim.server')
  local index = entry.index or 1
  height = height or M.PREVIEW_LINES
  width = width or 0
  if not entry.path or entry.path == server.self_path then
    local decoded = vim.json.decode(M.tab_lines(index, height, width))
    return callback(decoded.lines, decoded.filetype, decoded)
  end
  local expr = ("v:lua.require'muxim.session'.tab_lines(%d,%d,%d)"):format(index, height, width)
  vim.system({ vim.v.progpath, '--server', entry.path, '--remote-expr', expr },
    { text = true, timeout = 1000 }, function(result)
      vim.schedule(function()
        local raw = result.code == 0 and (result.stdout or ''):gsub('\n$', '') or ''
        local ok, decoded = pcall(vim.json.decode, raw)
        if ok and type(decoded) == 'table' and decoded.lines then
          return callback(decoded.lines, decoded.filetype, decoded)
        end
        M.lines_async(entry, function(lines) callback(lines) end)
      end)
    end)
end

function M.goto_tab(index)
  local tabs = vim.api.nvim_list_tabpages()
  if not tabs[index] then return false end
  vim.api.nvim_set_current_tabpage(tabs[index])
  return true
end

M.REMOTE_EXPR = "v:lua.require'muxim.session'.summary()"

local function as_entry(target)
  if type(target) == 'string' then
    return { path = target }
  end
  return target
end

function M.lines_async(target, callback)
  local entry = as_entry(target)
  if entry.path == require('muxim.server').self_path then
    return callback(vim.split(M.summary(), '\n'), true)
  end
  local function fallback(message)
    callback(entry.dir and M.dir_lines(entry.dir) or { message }, true)
  end
  if not vim.uv.fs_stat(entry.path) then
    return fallback('not running')
  end
  callback({ 'loading...' }, false)
  vim.system({ vim.v.progpath, '--server', entry.path, '--remote-expr', M.REMOTE_EXPR },
    { text = true, timeout = 1000 }, function(result)
      vim.schedule(function()
        if result.code == 0 and result.stdout and result.stdout ~= '' then
          callback(vim.split((result.stdout:gsub('\n$', '')), '\n'), true)
        else
          fallback('server not responding')
        end
      end)
    end)
end

function M.dir_lines(dir)
  local entries = {}
  for name, kind in vim.fs.dir(dir) do
    entries[#entries + 1] = kind == 'directory' and (name .. '/') or name
  end
  table.sort(entries)
  return entries
end

return M
