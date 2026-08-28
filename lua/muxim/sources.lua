local server = require('muxim.server')

local M = {}

---@type string[]|fun(): string[]
M.project_dirs = {}

local function configured_dirs()
  local dirs = M.project_dirs
  if type(dirs) == 'function' then
    local ok, result = pcall(dirs)
    dirs = ok and result or {}
  end
  return type(dirs) == 'table' and dirs or {}
end

local function normalise(dir)
  return (vim.fn.fnamemodify(vim.fn.expand(dir), ':p'):gsub('/$', ''))
end

local function short(dir)
  return vim.fn.fnamemodify(dir, ':~')
end

local function disambiguate(entries)
  local seen = {}
  for _, entry in ipairs(entries) do
    seen[entry.name] = (seen[entry.name] or 0) + 1
  end
  for _, entry in ipairs(entries) do
    if seen[entry.name] > 1 and not (entry.live == false and entry.dir) then
      if entry.dir then
        entry.name = entry.name .. '  ' .. short(vim.fn.fnamemodify(entry.dir, ':h'))
      else
        entry.name = entry.name .. '  ' .. vim.fn.fnamemodify(entry.path, ':t'):sub(1, 6)
      end
    end
  end
  return entries
end

function M.sessions(dirs)
  local runtime = require('muxim.runtime')
  local agents = require('muxim.agents')
  local entries, by_path = {}, {}
  for _, running in ipairs(server.list()) do
    local mine = running.path == server.self_path
    local dir = mine and agents.session_cwd() or agents.published(running.path).cwd
    local entry = {
      name = runtime.display_name(running.path),
      dir = dir,
      path = running.path,
      live = true,
      current = running.current,
    }
    entries[#entries + 1] = entry
    by_path[running.path] = entry
  end
  local extra = {}
  for _, dir in ipairs(dirs or configured_dirs()) do
    local full = normalise(dir)
    local path = server.socket_for(full)
    if by_path[path] then
      by_path[path].dir = by_path[path].dir or full
    else
      extra[#extra + 1] = {
        name = vim.fn.fnamemodify(full, ':t'),
        dir = full,
        path = path,
        live = false,
        current = false,
      }
    end
  end
  local function rank(entry)
    if entry.current then return 0 end
    return entry.live and 1 or 2
  end
  table.sort(entries, function(a, b)
    if rank(a) ~= rank(b) then return rank(a) < rank(b) end
    return a.name < b.name
  end)
  vim.list_extend(entries, extra)
  return disambiguate(entries)
end

local function session_windows(entry)
  local agents = require('muxim.agents')
  local tabline = require('muxim.tabline')
  local windows = {}
  if entry.current then
    local current = vim.api.nvim_get_current_tabpage()
    for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
      local state = agents.tab_state(tab)
      windows[i] = {
        kind = 'window',
        name = tabline.tab_label(tab),
        index = i,
        tab = tab,
        path = entry.path,
        session = entry.name,
        current = tab == current,
        state = state,
        agent = state and agents.MARKS[state] or nil,
      }
    end
    return windows
  end
  for i, tab in ipairs(agents.published(entry.path).tabs) do
    windows[i] = {
      kind = 'window',
      name = tab.name,
      index = tab.index,
      path = entry.path,
      session = entry.name,
      current = tab.current or false,
      state = tab.state,
      agent = tab.state and agents.MARKS[tab.state] or nil,
    }
  end
  return windows
end

local function active_index(windows)
  for _, window in ipairs(windows) do
    if window.current then return window.index end
  end
  return windows[1] and windows[1].index or 1
end

function M.windows(opts)
  opts = opts or {}
  local entries = {}
  for _, session in ipairs(M.sessions(opts.dirs or {})) do
    if session.live and (opts.fleet ~= false or session.current) then
      local windows = session_windows(session)
      session.kind = 'session'
      session.index = active_index(windows)
      entries[#entries + 1] = session
      vim.list_extend(entries, windows)
    end
  end
  return entries
end

function M.mark(entry)
  if entry.current then return '* ' end
  return entry.live and '● ' or '  '
end

function M.ordinal(entry)
  local parts = { entry.name }
  if entry.index then parts[#parts + 1] = tostring(entry.index) end
  if entry.session then parts[#parts + 1] = entry.session end
  if entry.dir then parts[#parts + 1] = short(entry.dir) end
  return table.concat(parts, ' ')
end

local function agent_span(text, entry, spans)
  if not entry.agent then return text end
  local marked = text .. '  ' .. entry.agent
  spans[#spans + 1] = {
    { #text + 2, #marked },
    require('muxim.agents').STATE_GROUPS[entry.state] or 'MuximAgentIdle',
  }
  return marked
end

function M.display(entry)
  local spans = {}
  if entry.kind == 'window' then
    local prefix = entry.current and '  * ' or '    '
    local text = prefix .. entry.index .. ': ' .. entry.name
    return agent_span(text, entry, spans), spans
  end
  local text = M.mark(entry) .. entry.name
  spans[#spans + 1] = { { 0, #text },
    entry.current and 'MuximAgentCurrent'
    or (entry.live and 'MuximAgentSession' or 'MuximAgentIdle') }
  if entry.live == false and entry.dir then
    local head = #text
    text = text .. '  ' .. short(entry.dir)
    spans[#spans + 1] = { { head + 2, #text }, 'MuximAgentIdle' }
  end
  return agent_span(text, entry, spans), spans
end

return M
