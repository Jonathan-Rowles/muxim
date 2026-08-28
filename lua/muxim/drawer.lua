local agents = require('muxim.agents')

local M = {}

M.FILETYPE = 'muxim-agents'

M.WIDTH = 34

M.SIDE = 'right'

local user_highlights = {}

local links = {
  MuximAgentSession = 'Directory',
  MuximAgentCurrent = 'Title',
  MuximAgentBlocked = 'DiagnosticError',
  MuximAgentWorking = 'DiagnosticWarn',
  MuximAgentDone = 'DiagnosticOk',
  MuximAgentIdle = 'Comment',
  MuximAgentRunning = 'Comment',
  MuximAgentEmpty = 'Comment',
  MuximPreviewHeading = 'Title',
  MuximPreviewPath = 'Comment',
  MuximPreviewJob = 'Special',
  MuximPreviewCursor = 'CursorLine',
}

local state_groups = agents.STATE_GROUPS

function M.set_highlights()
  for group, target in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
  local overrides = user_highlights
  if type(overrides) == 'function' then
    overrides = overrides()
  end
  for group, spec in pairs(type(overrides) == 'table' and overrides or {}) do
    vim.api.nvim_set_hl(0, group, spec)
  end
end

function M.setup(opts)
  opts = opts or {}
  if opts.width then M.WIDTH = opts.width end
  if opts.side then M.SIDE = opts.side end
  if opts.highlights then user_highlights = opts.highlights end
  if opts.format then M.format = opts.format end
end

M.NAMESPACE = vim.api.nvim_create_namespace('muxim_drawer')

local rows = {}

local groups = {}

local watcher = nil

local pending = nil

M.DEBOUNCE = 40

M.RESCAN = 3000

local rescan = nil

local function state_icon(state)
  return agents.MARKS[state] or ' '
end

function M.format(agent)
  return ('%s %s  %s'):format(
    state_icon(agent.state), agent.name or 'agent', agent.detail or agent.state)
end

local view = nil

function M.ordered(agents)
  local children, out = {}, {}
  local present = {}
  for _, agent in ipairs(agents) do
    if agent.id then present[agent.id] = true end
  end
  for _, agent in ipairs(agents) do
    if agent.parent and present[agent.parent] then
      children[agent.parent] = children[agent.parent] or {}
      table.insert(children[agent.parent], agent)
    else
      out[#out + 1] = agent
    end
  end
  local nested = {}
  for _, agent in ipairs(out) do
    nested[#nested + 1] = agent
    for _, child in ipairs(agent.id and children[agent.id] or {}) do
      nested[#nested + 1] = child
    end
  end
  return nested
end

function M.lines()
  local sessions = view
  local out, targets, marks = { 'muxim', '' }, {}, {}
  if not sessions then
    out[#out + 1] = '  (looking...)'
    marks[#out] = 'MuximAgentEmpty'
    rows, groups = targets, marks
    return out
  end
  for _, session in ipairs(sessions) do
    out[#out + 1] = (session.current and '* ' or '  ') .. session.name
    marks[#out] = session.current and 'MuximAgentCurrent' or 'MuximAgentSession'
    targets[#out] = { kind = 'session', path = session.path, current = session.current }
    if #session.agents == 0 then
      out[#out + 1] = '      (no agents)'
      marks[#out] = 'MuximAgentEmpty'
    end
    for _, agent in ipairs(M.ordered(session.agents)) do
      local ok, text = pcall(M.format, agent)
      if not ok or (type(text) ~= 'string' and type(text) ~= 'number') then
        text = agent.name or 'agent'
      end
      out[#out + 1] = (agent.parent and '      ' or '    ')
        .. (tostring(text):gsub('%s+', ' '))
      marks[#out] = state_groups[agent.state] or 'MuximAgentIdle'
      targets[#out] = {
        kind = 'agent',
        path = session.path,
        current = session.current,
        buf = session.current and agent.buf or nil,
      }
    end
  end
  if #sessions == 0 then
    out[#out + 1] = '  (no live sessions)'
    marks[#out] = 'MuximAgentEmpty'
  end
  local waiting = agents.unwired(sessions)[1]
  local vendor = waiting and agents.vendor(waiting.name)
  if vendor and vendor.installed and not vendor.installed() then
    out[#out + 1] = ''
    out[#out + 1] = ('  ! %s is running but not reporting'):format(waiting.name or 'an agent')
    marks[#out] = 'MuximAgentBlocked'
    out[#out + 1] = '    <CR> to wire it up'
    marks[#out] = 'MuximAgentEmpty'
    targets[#out] = { kind = 'install', vendor = vendor.name, current = true }
  end
  rows, groups = targets, marks
  return out
end

function M.show(sessions)
  view = sessions
  return M.render()
end

function M.refresh()
  if vim.v.exiting ~= vim.NIL then return false end
  if not M.is_open() then return false end
  agents.fleet_view(M.show)
  return true
end

function M.buffer()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == M.FILETYPE then
      return buf
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.keymap.set('n', '<CR>', M.select, { buffer = buf, desc = 'muxim: go to this session or agent' })
  vim.keymap.set('n', 'q', M.close, { buffer = buf, desc = 'muxim: close the drawer' })
  vim.keymap.set('n', 'r', M.refresh, { buffer = buf, desc = 'muxim: refresh' })
  vim.bo[buf].filetype = M.FILETYPE
  pcall(vim.api.nvim_buf_set_name, buf, 'muxim://agents')
  return buf
end

function M.window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == M.FILETYPE then
      return win, buf
    end
  end
  return nil, nil
end

function M.is_open()
  return M.window() ~= nil
end

function M.open_anywhere()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == M.FILETYPE then
        return true
      end
    end
  end
  return false
end

function M.render()
  local win, buf = M.window()
  if not win then return false end
  local cursor = vim.api.nvim_win_get_cursor(win)
  vim.bo[buf].modifiable = true
  local lines = M.lines()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, M.NAMESPACE, 0, -1)
  for line, group in pairs(groups) do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.NAMESPACE, line - 1, 0, {
      end_row = line - 1, end_col = #(lines[line] or ''), hl_group = group,
    })
  end
  local last = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_win_set_cursor(win, { math.min(cursor[1], last), cursor[2] })
  return true
end

local function focus_window_showing(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      return true
    end
  end
  return false
end

local function leave_drawer()
  local drawer_win = M.window()
  local previous = vim.fn.win_getid(vim.fn.winnr('#'))
  if previous ~= 0 and previous ~= drawer_win and vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
    return true
  end
  if #vim.api.nvim_tabpage_list_wins(0) > 1 then
    return M.close()
  end
  if drawer_win then
    vim.wo[drawer_win].winfixwidth = false
  end
  return false
end

function M.select()
  local target = rows[vim.fn.line('.')]
  if not target then return false end
  if target.kind == 'install' then
    local wired = agents.wire_up(target.vendor)
    M.refresh()
    return wired
  end
  if not target.current then
    return require('muxim.server').connect(target.path)
  end
  if target.buf and focus_window_showing(target.buf) then
    return true
  end
  leave_drawer()
  if target.buf then
    vim.api.nvim_set_current_buf(target.buf)
  end
  return true
end

local function stop_watching()
  pcall(vim.api.nvim_del_augroup_by_name, 'muxim_drawer')
  if watcher then
    pcall(function() watcher:stop() end)
    pcall(function() watcher:close() end)
    watcher = nil
  end
  if rescan then
    pcall(function() rescan:stop() end)
    pcall(function() rescan:close() end)
    rescan = nil
  end
end

function M.open()
  if not agents.enabled then
    vim.notify('muxim: agent watching is off (agents = false)', vim.log.levels.WARN)
    return false
  end
  if M.is_open() then
    M.render()
    return true
  end
  local buf = M.buffer()

  M.set_highlights()
  vim.cmd((M.SIDE == 'left' and 'topleft' or 'botright') .. ' vsplit')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, M.WIDTH)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].winfixwidth = true

  stop_watching()
  local group = vim.api.nvim_create_augroup('muxim_drawer', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = M.set_highlights,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = stop_watching,
  })
  vim.api.nvim_create_autocmd('User', {
    pattern = 'MuximAgentState',
    group = group,
    callback = function() M.schedule_render() end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function()
      vim.schedule(function()
        if not M.open_anywhere() then stop_watching() end
      end)
    end,
  })

  watcher = agents.watch(function() M.schedule_render() end)
  rescan = vim.uv.new_timer()
  if rescan then
    rescan:start(M.RESCAN, M.RESCAN, vim.schedule_wrap(function() M.refresh() end))
  end

  M.render()
  M.refresh()
  return true
end

function M.schedule_render()
  if pending then return end
  pending = vim.defer_fn(function()
    pending = nil
    M.refresh()
  end, M.DEBOUNCE)
end

function M.close()
  local win = M.window()
  if not win then return false end
  local closed = pcall(vim.api.nvim_win_close, win, true)
  if not closed then return false end
  if not M.open_anywhere() then
    stop_watching()
  end
  return true
end

function M.toggle()
  if M.is_open() then
    return M.close()
  end
  return M.open()
end

return M
