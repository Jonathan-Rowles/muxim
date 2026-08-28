local M = {}

M.STATES = { working = true, blocked = true, done = true, idle = true, ended = true }

M.MARKS = { blocked = '!', working = '~', done = '+' }

M.STATE_GROUPS = {
  blocked = 'MuximAgentBlocked',
  working = 'MuximAgentWorking',
  done = 'MuximAgentDone',
  idle = 'MuximAgentIdle',
  running = 'MuximAgentRunning',
}

M.enabled = true

M.notify = 'unfocused'

M.focused = true

M.notify_fleet = true

function M.may_notify()
  if not M.notify then return false end
  if type(M.notify) == 'function' then return true end
  return #vim.api.nvim_list_uis() > 0
end

local function should_notify(entry, was)
  if entry.state ~= 'blocked' or was == 'blocked' then return false end
  if not M.may_notify() then return false end
  if type(M.notify) == 'function' then return true end
  if M.notify == 'unfocused' then
    if not M.focused then return true end
    return not entry.here or vim.api.nvim_get_current_buf() ~= entry.buf
  end
  return true
end

local fleet_seen = {}
local fleet_handle = nil

local reported = {}

local observed = {}

local SELF = 'self'

local STATE_RANK = { blocked = 1, working = 2, done = 3, running = 4, idle = 5 }

local function more_urgent(a, b)
  if not b then return true end
  return (STATE_RANK[a.state] or 9) < (STATE_RANK[b.state] or 9)
end

local function log(line)
  local ok, dir = pcall(require('muxim.runtime').dir)
  if not ok then return false end
  local file = io.open(dir .. '/agents.log', 'a')
  if not file then return false end
  file:write(('%s  %s  %s\n'):format(
    os.date('%Y-%m-%d %H:%M:%S'), require('muxim.server').self_name(), line))
  file:close()
  return true
end

function M.log_lines()
  local ok, dir = pcall(require('muxim.runtime').dir)
  if not ok then return {} end
  local file = io.open(dir .. '/agents.log', 'r')
  if not file then return {} end
  local lines = {}
  for line in file:lines() do
    lines[#lines + 1] = line
  end
  file:close()
  return lines
end

M.VENDORS = { 'claude' }

local function vendor_module(name)
  local ok, module = pcall(require, 'muxim.agents.' .. name)
  if ok and type(module) == 'table' and module.name == name then
    return module
  end
  return nil
end

function M.vendors()
  local list = {}
  for _, name in ipairs(M.VENDORS) do
    local module = vendor_module(name)
    if module then
      list[#list + 1] = module
    end
  end
  return list
end

function M.vendor(name)
  for _, module in ipairs(M.vendors()) do
    if module.name == name then
      return module
    end
  end
  return nil
end

M.PAYLOAD_MAX = 1048576

M.PAYLOAD_DEPTH = 20

function M.hook_path()
  return vim.fn.stdpath('data') .. '/muxim/agent-hook'
end

function M.hook_lua_path()
  return M.hook_path() .. '.lua'
end

function M.hook_command_path()
  local path = M.hook_path()
  local home = vim.env.HOME
  if home and home ~= '' and path:sub(1, #home + 1) == home .. '/' then
    return '$HOME/' .. path:sub(#home + 2)
  end
  return path
end

function M.hook_script()
  return table.concat({
    '#!/bin/sh',
    '# Written by muxim. Reports agent state to the muxim session that owns this',
    '# terminal, and does nothing at all anywhere else.',
    '[ -n "${MUXIM_SERVER:-}" ] || exit 0',
    '[ -n "${MUXIM_TERM:-}" ] || exit 0',
    '[ ! -t 0 ] || exec </dev/null',
    '"${MUXIM_NVIM:-nvim}" -l "' .. M.hook_lua_path() .. '" "$@" >/dev/null 2>&1'
      .. ' || printf \'%s  hook  client failed term=%s\\n\''
      .. ' "$(date \'+%Y-%m-%d %H:%M:%S\')" "$MUXIM_TERM"'
      .. ' >>"${MUXIM_SERVER%/*}/agents.log" 2>/dev/null',
    'exit 0',
    '',
  }, '\n')
end

function M.hook_lua()
  local body = [[
-- Written by muxim. Decodes one hook event from stdin and delivers it to the
-- owning session over msgpack-rpc.
local server = vim.env.MUXIM_SERVER
local term = vim.env.MUXIM_TERM
if not server or server == '' or not term or term == '' then return end

local function log(reason)
  local line = ('%s  hook  %s term=%s\n'):format(
    os.date('%Y-%m-%d %H:%M:%S'), reason, term)
  for _, dir in ipairs({ server:match('^(.*)/'), vim.fn.stdpath('data') .. '/muxim' }) do
    local file = dir and io.open(dir .. '/agents.log', 'a')
    if file then
      file:write(line)
      file:close()
      return
    end
  end
end

local function depth_of(value, depth)
  if type(value) ~= 'table' or depth >= @DEPTH@ then return depth end
  local deepest = depth
  for _, inner in pairs(value) do
    local below = depth_of(inner, depth + 1)
    if below > deepest then deepest = below end
    if deepest >= @DEPTH@ then break end
  end
  return deepest
end

local event = {
  v = 1,
  term = term,
  state = arg[1] or '',
  detail = arg[2] or '',
  name = arg[3] or '',
}

local raw = io.read('*a') or ''
if raw ~= '' then
  if #raw > @CAP@ then
    event.fault = ('payload of %d bytes is over the @CAP@ cap'):format(#raw)
  else
    local ok, decoded = pcall(vim.json.decode, raw)
    if ok and type(decoded) == 'table' and not vim.islist(decoded) then
      if depth_of(decoded, 1) >= @DEPTH@ then
        local flat = {}
        for key, value in pairs(decoded) do
          if type(value) ~= 'table' then flat[key] = value end
        end
        event.payload = flat
        event.fault = 'payload nested past @DEPTH@ levels, kept only its flat fields'
      else
        event.payload = decoded
      end
    else
      event.fault = ('unparseable payload of %d bytes'):format(#raw)
    end
  end
end

local ok, chan = pcall(vim.fn.sockconnect, 'pipe', server, { rpc = true })
if not ok or chan == 0 then
  log('unreachable')
  return
end
local delivered, err = pcall(vim.rpcrequest, chan, 'nvim_exec_lua',
  'return require("muxim.agents").receive(...)', { event })
if not delivered then
  log('rejected ' .. (tostring(err):gsub('%s+', ' ')):sub(1, 200))
end
pcall(vim.fn.chanclose, chan)
]]
  return (body:gsub('@CAP@', tostring(M.PAYLOAD_MAX)):gsub('@DEPTH@', tostring(M.PAYLOAD_DEPTH)))
end

local function atomic_write(target, body)
  vim.fn.mkdir(vim.fn.fnamemodify(target, ':h'), 'p', tonumber('700', 8))
  local tmp = target .. '.tmp.' .. vim.uv.os_getpid()
  local file = io.open(tmp, 'w')
  if not file then return false end
  local ok = file:write(body) and file:close()
  if not ok then
    os.remove(tmp)
    return false
  end
  vim.uv.fs_chmod(tmp, tonumber('700', 8))
  if not vim.uv.fs_rename(tmp, target) then
    os.remove(tmp)
    return false
  end
  return true
end

function M.write_hook()
  return atomic_write(M.hook_lua_path(), M.hook_lua())
    and atomic_write(M.hook_path(), M.hook_script())
end

function M.shell_init_path()
  return vim.fn.stdpath('data') .. '/muxim/shell-init.sh'
end

function M.shell_init()
  local lines = {
    '# Written by muxim. Sourced from your shell rc, it puts the nvim wrapper back',
    '# in front after the rc rebuilt PATH, and makes an agent you type report into',
    '# the muxim session that owns the terminal. Outside muxim the variables are',
    '# unset and every wrapper is a plain passthrough.',
    'if [ -n "${MUXIM_BIN:-}" ] && [ -x "$MUXIM_BIN/nvim" ]; then',
    '  case "$PATH" in',
    '    "$MUXIM_BIN":*) ;;',
    '    *) PATH="$MUXIM_BIN:$PATH" ;;',
    '  esac',
    'fi',
  }
  for _, vendor in ipairs(M.vendors()) do
    if vendor.shell_init then
      lines[#lines + 1] = vendor.shell_init()
    end
  end
  lines[#lines + 1] = ''
  return table.concat(lines, '\n')
end

function M.write_shell_init()
  local target = M.shell_init_path()
  vim.fn.mkdir(vim.fn.fnamemodify(target, ':h'), 'p', tonumber('700', 8))
  local tmp = target .. '.tmp.' .. vim.uv.os_getpid()
  local file = io.open(tmp, 'w')
  if not file then return false end
  local ok = file:write(M.shell_init()) and file:close()
  if not ok or not vim.uv.fs_rename(tmp, target) then
    os.remove(tmp)
    return false
  end
  return true
end

function M.shell_init_is_current()
  local file = io.open(M.shell_init_path(), 'r')
  if not file then return false end
  local body = file:read('*a')
  file:close()
  return body == M.shell_init()
end

function M.wrapper_dir()
  return vim.fn.stdpath('data') .. '/muxim/bin'
end

function M.wrapper_path()
  return M.wrapper_dir() .. '/nvim'
end

function M.wrapper_script()
  local deny = { '-*', '*/.git/*', '.git/*' }
  for _, suffix in ipairs(require('muxim.remote').BLOCKING_SUFFIXES) do
    deny[#deny + 1] = '*' .. suffix
  end
  return table.concat({
    '#!/bin/sh',
    '# Written by muxim. First on PATH inside muxim terminals, it routes files',
    '# and directories to the session that owns the terminal instead of nesting',
    '# a second editor. Flags, version-control message files, and callers',
    '# outside muxim get the real nvim.',
    'self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)',
    'passthrough() {',
    '  [ -n "${MUXIM_NVIM:-}" ] && exec "$MUXIM_NVIM" "$@"',
    '  cleaned=""',
    '  old_ifs=$IFS',
    '  IFS=:',
    '  for dir in $PATH; do',
    '    [ "$dir" = "$self_dir" ] || cleaned=${cleaned:+$cleaned:}$dir',
    '  done',
    '  IFS=$old_ifs',
    '  PATH=$cleaned',
    '  exec nvim "$@"',
    '}',
    '[ -n "${NVIM:-}" ] || passthrough "$@"',
    'for arg in "$@"; do',
    '  case $arg in',
    '    ' .. table.concat(deny, '|') .. ') passthrough "$@" ;;',
    '  esac',
    'done',
    'abs() {',
    '  case $1 in',
    '    /*) printf %s "$1" ;;',
    '    *) printf %s "$PWD/${1#./}" ;;',
    '  esac',
    '}',
    'client="${MUXIM_NVIM:-nvim}"',
    'opened_dir=0',
    'for arg in "$@"; do',
    '  if [ -d "$arg" ]; then',
    '    opened_dir=1',
    '    dir_esc=$(abs "$arg" | sed "s/\'/\'\'/g")',
    '    "$client" --server "$NVIM" --remote-expr "v:lua.require\'muxim.remote\'.open_dir(\'$dir_esc\')" >/dev/null 2>&1',
    '  fi',
    'done',
    'file_count=0',
    'for arg in "$@"; do',
    '  [ -d "$arg" ] && continue',
    '  set -- "$@" "$(abs "$arg")"',
    '  file_count=$((file_count + 1))',
    'done',
    'if [ "$file_count" -gt 0 ]; then',
    '  shift $(($# - file_count))',
    '  "$client" --server "$NVIM" --remote-expr "v:lua.require\'muxim.remote\'.prepare()" >/dev/null 2>&1',
    '  "$client" --server "$NVIM" --remote "$@"',
    'elif [ "$opened_dir" -eq 0 ]; then',
    '  "$client" --server "$NVIM" --remote-expr "v:lua.require\'muxim.remote\'.focus()" >/dev/null 2>&1',
    'fi',
    'exit 0',
    '',
  }, '\n')
end

function M.write_wrapper()
  local target = M.wrapper_path()
  vim.fn.mkdir(vim.fn.fnamemodify(target, ':h'), 'p', tonumber('700', 8))
  local tmp = target .. '.tmp.' .. vim.uv.os_getpid()
  local file = io.open(tmp, 'w')
  if not file then return false end
  local ok = file:write(M.wrapper_script()) and file:close()
  if not ok then
    os.remove(tmp)
    return false
  end
  vim.uv.fs_chmod(tmp, tonumber('700', 8))
  if not vim.uv.fs_rename(tmp, target) then
    os.remove(tmp)
    return false
  end
  return true
end

function M.wrapper_is_current()
  local file = io.open(M.wrapper_path(), 'r')
  if not file then return false end
  local body = file:read('*a')
  file:close()
  return body == M.wrapper_script()
end

local function file_matches(path, body)
  local file = io.open(path, 'r')
  if not file then return false end
  local existing = file:read('*a')
  file:close()
  return existing == body
end

function M.hook_is_current()
  return file_matches(M.hook_path(), M.hook_script())
    and file_matches(M.hook_lua_path(), M.hook_lua())
end

local function state_dir()
  local dir = require('muxim.runtime').dir() .. '/agents'
  vim.fn.mkdir(dir, 'p', tonumber('700', 8))
  return dir
end

function M.state_file(path)
  return state_dir() .. '/' .. vim.fn.fnamemodify(path, ':t') .. '.json'
end

function M.terminals()
  local terminal = require('muxim.terminal')
  local list = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if terminal.is_terminal(buf) and vim.b[buf].terminal_job_pid
        and terminal.job_is_running(buf) then
      list[#list + 1] = {
        buf = buf,
        pid = tonumber(vim.b[buf].terminal_job_pid),
        reports = vim.b[buf].muxim_agent_env == true,
      }
    end
  end
  return list
end

function M.session_cwd()
  return vim.fn.getcwd(-1, -1)
end

function M.tabs()
  local tabline = require('muxim.tabline')
  local current = vim.api.nvim_get_current_tabpage()
  local entries = M.tracked()
  local list = {}
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    list[i] = {
      index = i,
      name = tabline.tab_label(tab),
      state = M.tab_state(tab, entries),
      current = tab == current,
    }
  end
  return list
end

function M.publish()
  if not M.enabled or vim.v.exiting ~= vim.NIL then return false end
  local server = require('muxim.server')
  if not server.self_path then return false end
  local agents = {}
  for _, entry in ipairs(M.tracked()) do
    agents[#agents + 1] = {
      buf = entry.buf, name = entry.name, state = entry.state, detail = entry.detail,
      id = entry.id, parent = entry.parent,
    }
  end
  local target = M.state_file(server.self_path)
  local tmp = target .. '.tmp'
  local file = io.open(tmp, 'w')
  if not file then return false end
  local ok = file:write(vim.json.encode({
    pid = vim.uv.os_getpid(),
    cwd = M.session_cwd(),
    tabs = M.tabs(),
    agents = agents,
    terminals = M.terminals(),
  })) and file:close()
  if not ok then
    os.remove(tmp)
    return false
  end
  return vim.uv.fs_rename(tmp, target) and true or false
end

function M.unpublish()
  local server = require('muxim.server')
  if server.self_path then
    os.remove(M.state_file(server.self_path))
  end
end

local function nothing_published()
  return { tabs = {}, agents = {}, terminals = {} }
end

function M.published(path)
  local file = io.open(M.state_file(path), 'r')
  if not file then return nothing_published(), false end
  local raw = file:read('*a')
  file:close()
  local ok, decoded = pcall(vim.json.decode, raw or '')
  if not ok or type(decoded) ~= 'table' then return nothing_published(), false end
  return {
    pid = type(decoded.pid) == 'number' and decoded.pid or nil,
    cwd = type(decoded.cwd) == 'string' and decoded.cwd or nil,
    tabs = type(decoded.tabs) == 'table' and decoded.tabs or {},
    agents = type(decoded.agents) == 'table' and decoded.agents or {},
    terminals = type(decoded.terminals) == 'table' and decoded.terminals or {},
  }, true
end

function M.fleet_check(quiet)
  local server = require('muxim.server')
  local runtime = require('muxim.runtime')
  local fresh = {}
  for _, entry in ipairs(server.list()) do
    if entry.path ~= server.self_path then
      local state, readable = M.published(entry.path)
      local remembered = fleet_seen[entry.path]
      if not readable then
        fresh[entry.path] = remembered
      else
        local previous = (remembered and remembered.pid == state.pid) and remembered.agents or {}
        local now = {}
        local named_by_id = {}
        for _, agent in ipairs(state.agents or {}) do
          if agent.id then named_by_id[tostring(agent.id)] = agent.name end
        end
        for _, agent in ipairs(state.agents or {}) do
          local id = tostring(agent.id or agent.buf or agent.name or '?')
          now[id] = agent.state
          if agent.state ~= previous[id] and not quiet then
            local named = runtime.display_name(entry.path)
            if agent.state == 'blocked' then
              log(('fleet %s %s %s'):format(agent.state, named, tostring(agent.name)))
            end
            local notice = {
              state = agent.state, detail = agent.detail, name = agent.name,
              parent = agent.parent,
              parent_name = agent.parent and named_by_id[tostring(agent.parent)] or nil,
              session = named, path = entry.path, here = false,
            }
            if should_notify(notice, previous[id]) then
              M.deliver(notice)
            end
            vim.api.nvim_exec_autocmds('User', {
              pattern = 'MuximAgentState',
              data = notice,
            })
          end
        end
        fresh[entry.path] = { pid = state.pid, agents = now }
      end
    end
  end
  for path, remembered in pairs(fleet_seen) do
    if fresh[path] == nil and path ~= server.self_path and vim.uv.fs_stat(path) then
      fresh[path] = remembered
    end
  end
  fleet_seen = fresh
  return true
end

function M.watching_fleet()
  return fleet_handle ~= nil
end

function M.fleet_size()
  local server = require('muxim.server')
  local others = 0
  for _, entry in ipairs(server.list()) do
    if entry.path ~= server.self_path then others = others + 1 end
  end
  return others
end

function M.watch_fleet()
  if fleet_handle or not M.notify_fleet then return false end
  if not require('muxim.server').self_path then return false end
  M.fleet_check(true)
  fleet_handle = M.watch(function()
    local ok, err = pcall(M.fleet_check)
    if not ok then
      log('fleet check failed: ' .. tostring(err))
    end
  end)
  return fleet_handle ~= nil
end

function M.unwatch_fleet()
  if not fleet_handle then return false end
  pcall(function() fleet_handle:stop() end)
  pcall(function() fleet_handle:close() end)
  fleet_handle = nil
  return true
end

function M.watch(callback)
  local handle = vim.uv.new_fs_event()
  if not handle then return nil end
  local ok = pcall(function()
    handle:start(state_dir(), {}, vim.schedule_wrap(function() callback() end))
  end)
  if not ok then
    pcall(function() handle:close() end)
    return nil
  end
  return handle
end

M.COMMANDS = { claude = true, codex = true, pi = true, opencode = true, aider = true }

function M.command_name(command)
  if not command then return nil end
  local name = (command:gsub('^%.', ''))
  if M.COMMANDS[name] then return name end
  local wrapped = name:match('^(.-)%-u?n?wrapp')
  if wrapped and M.COMMANDS[wrapped] then return wrapped end
  return nil
end

M.SCAN_DEPTH = 4

local function walk_processes(children, pid, visit)
  local frontier, depth = { pid }, 0
  while #frontier > 0 and depth < M.SCAN_DEPTH do
    local next_frontier = {}
    for _, parent in ipairs(frontier) do
      for _, child in ipairs(children[parent] or {}) do
        if visit(child) then return end
        next_frontier[#next_frontier + 1] = child
      end
    end
    frontier = next_frontier
    depth = depth + 1
  end
end

M.can_discover = true

local function executable_name(command, args)
  local name = vim.fn.fnamemodify(vim.trim(command), ':t')
  if M.command_name(name) then return name end
  local argv0 = (args or ''):match('^%S+')
  return argv0 and vim.fn.fnamemodify(argv0, ':t') or name
end

M.PS_ARGV = { 'ps', '-Awwo', 'pid=,ppid=,etime=,comm=,args=' }

local function parse_ps(output)
  local children, commands, argv, elapsed = {}, {}, {}, {}
  for line in (output or ''):gmatch('[^\n]+') do
    local pid, ppid, etime, command, args =
        line:match('^%s*(%d+)%s+(%d+)%s+([%d:%-]+)%s+(%S+)%s*(.*)$')
    if pid then
      pid, ppid = tonumber(pid), tonumber(ppid)
      children[ppid] = children[ppid] or {}
      table.insert(children[ppid], pid)
      commands[pid] = executable_name(command, args)
      argv[pid] = args or ''
      elapsed[pid] = etime
    end
  end
  return children, commands, argv, elapsed
end

function M.process_tree(callback)
  local ok = pcall(vim.system, M.PS_ARGV, { text = true }, function(out)
    local children, commands, argv, elapsed = {}, {}, {}, {}
    if out.code == 0 then
      children, commands, argv, elapsed = parse_ps(out.stdout)
    end
    vim.schedule(function() callback(children, commands, argv, elapsed) end)
  end)
  if not ok then
    M.can_discover = false
    vim.schedule(function() callback({}, {}) end)
  end
end

function M.process_scan()
  local ok, output = pcall(vim.fn.system, M.PS_ARGV)
  if not ok or vim.v.shell_error ~= 0 then return {}, {}, {}, {} end
  return parse_ps(output)
end

local SHELLS = { zsh = true, bash = true, sh = true, fish = true, dash = true, ksh = true }

function M.running_in(children, commands, elapsed, pid)
  local name, owner = commands[pid], pid
  walk_processes(children, pid, function(child)
    if commands[child] and not SHELLS[commands[child]] then
      name, owner = commands[child], child
    end
  end)
  if not name then return nil end
  return name, (elapsed or {})[owner], not SHELLS[name]
end

function M.agent_in(children, commands, pid)
  local own = M.command_name(commands[pid])
  if own then return own, pid end
  local found, owner
  walk_processes(children, pid, function(child)
    local command = M.command_name(commands[child])
    if command then
      found, owner = command, child
      return true
    end
  end)
  return found, owner
end

function M.fleet_view(callback)
  local server = require('muxim.server')
  local runtime = require('muxim.runtime')
  local sessions = {}
  for _, entry in ipairs(server.list()) do
    local mine = entry.path == server.self_path
    local state = mine
        and { agents = M.tracked(), terminals = M.terminals() }
        or M.published(entry.path)
    sessions[#sessions + 1] = {
      path = entry.path,
      name = runtime.display_name(entry.path),
      current = mine,
      agents = state.agents,
      terminals = state.terminals,
    }
  end
  M.process_tree(function(children, commands, argv)
    for _, session in ipairs(sessions) do
      local reported_bufs = {}
      for _, agent in ipairs(session.agents) do
        reported_bufs[agent.buf or -1] = true
      end
      for _, term in ipairs(session.terminals) do
        local command, agent_pid
        if term.pid then command, agent_pid = M.agent_in(children, commands, term.pid) end
        if command and not reported_bufs[term.buf] then
          local vendor = M.vendor(command)
          local wired = true
          if vendor and vendor.wired then
            wired = vendor.wired((argv or {})[agent_pid] or '')
          end
          session.agents[#session.agents + 1] = {
            buf = term.buf,
            name = command,
            state = 'running',
            detail = 'no state reported yet',
            wired = wired,
          }
        end
      end
      table.sort(session.agents, function(a, b)
        if (a.state == 'blocked') ~= (b.state == 'blocked') then return a.state == 'blocked' end
        if (a.state == 'running') ~= (b.state == 'running') then return b.state == 'running' end
        return (a.buf or 0) < (b.buf or 0)
      end)
    end
    callback(sessions)
  end)
end

local function terminal_valid(buf)
  local terminal = require('muxim.terminal')
  if not terminal.is_terminal(buf) then return false end
  return terminal.job_is_running(buf)
end

local function label(buf)
  return require('muxim.terminal').label(buf) or 'agent'
end

M.DETAIL_MAX = 200

local function one_line(text)
  if text == nil then return nil end
  local trimmed = vim.trim((tostring(text):gsub('%c', ' '):gsub('%s+', ' ')))
  if trimmed == '' then return nil end
  if #trimmed > M.DETAIL_MAX then
    trimmed = trimmed:sub(1, M.DETAIL_MAX - 3) .. '...'
  end
  return trimmed
end

function M.who(entry)
  local named = entry.name or 'an agent'
  if entry.parent_name and entry.parent_name ~= named then
    return entry.parent_name .. '/' .. named
  end
  return named
end

function M.where(entry)
  if not entry.here then
    return entry.session and (' in ' .. entry.session) or ''
  end
  return entry.tab and (' in tab ' .. entry.tab) or ''
end

function M.deliver(entry)
  if type(M.notify) == 'function' then
    pcall(M.notify, entry)
    return true
  end
  vim.notify(('muxim: %s is blocked%s%s'):format(
    M.who(entry), M.where(entry),
    entry.detail and (' (' .. entry.detail .. ')') or ''), vim.log.levels.WARN)
  return true
end

local function tab_number(buf)
  local tab = require('muxim.terminal').owner(buf)
  return tab and vim.api.nvim_tabpage_get_number(tab) or nil
end

local function announce(buf, state, detail, name)
  vim.api.nvim_exec_autocmds('User', {
    pattern = 'MuximAgentState',
    data = { buf = buf, state = state, detail = detail, name = name, here = true },
  })
end

function M.report(term, state, detail, name, session, sub)
  if vim.v.exiting ~= vim.NIL then return false end
  local buf = tonumber(term)
  term, state = one_line(term), one_line(state)
  detail, name, session = one_line(detail), one_line(name), one_line(session)
  if not M.STATES[state] then
    log(('ignored term=%s state=%s: unknown state, the FIRST argument is the state'):format(
      tostring(term), tostring(state)))
    return false
  end
  if not buf or not terminal_valid(buf) then
    log(('ignored term=%s state=%s: no such live terminal in this session'):format(
      tostring(term), state))
    return false
  end
  local id = sub and sub.id or session or SELF
  local parent = sub and session or nil
  if sub and sub.type then name = one_line(sub.type) end
  local agents_here = reported[buf] or {}
  if not sub and state ~= 'ended' then
    local replaced = {}
    for other_id, other in pairs(agents_here) do
      if other_id ~= id and not other.parent and other.name == name then
        replaced[#replaced + 1] = other_id
      end
    end
    for _, other_id in ipairs(replaced) do
      agents_here[other_id] = nil
      for child_id, child in pairs(agents_here) do
        if child.parent == other_id then agents_here[child_id] = nil end
      end
      log(('replaced term=%d %s: %s reports under a new id'):format(buf, other_id, tostring(name)))
    end
  end
  local current = agents_here[id]
  if current and current.state == state and current.detail == detail
      and current.name == name then
    return true
  end
  local was = current and current.state or nil
  log(('%s term=%d%s%s%s'):format(state, buf,
    name and (' name=' .. name) or '',
    parent and (' under=' .. parent) or '',
    detail and (' detail=' .. detail) or ''))
  if state == 'ended' then
    if id == SELF and current and name and current.name and current.name ~= name then
      log(('kept term=%d: a different agent ended, %s is still there'):format(buf, current.name))
      return true
    end
    agents_here[id] = nil
    for child_id, entry in pairs(agents_here) do
      if entry.parent == id then agents_here[child_id] = nil end
    end
    reported[buf] = next(agents_here) ~= nil and agents_here or nil
  else
    agents_here[id] = {
      id = id, state = state, detail = detail, name = name,
      session = session, parent = parent, at = vim.uv.hrtime(),
    }
    reported[buf] = agents_here
  end
  local under = parent and agents_here[parent]
  local notice = {
    buf = buf, state = state, detail = detail,
    name = name or label(buf), tab = tab_number(buf),
    parent = parent, parent_name = under and under.name or nil,
    session = require('muxim.server').self_name(), here = true,
  }
  if should_notify(notice, was) then
    M.deliver(notice)
  end
  announce(buf, state, detail, name)
  return true
end

function M.receive(event)
  if vim.v.exiting ~= vim.NIL then return '' end
  if type(event) ~= 'table' or event.v ~= 1 or event.term == nil then return '' end
  vim.schedule(function()
    local term = tostring(event.term)
    if event.fault then
      log(('hook fault term=%s: %s'):format(term, tostring(event.fault)))
    end
    local payload = type(event.payload) == 'table' and event.payload or {}
    local state = tostring(event.state or '')
    local detail = tostring(event.detail or '')
    local name = tostring(event.name or '')
    local session = type(payload.session_id) == 'string' and payload.session_id or nil
    local read = {}
    local vendor = M.vendor(name)
    if vendor and vendor.read then
      local ok, said = pcall(vendor.read, payload)
      if ok and type(said) == 'table' then read = said end
    end
    if read.subagent_event and not read.sub then
      log(('ignored term=%s: a sub-agent event with no id cannot say WHICH child, and '
        .. 'treating it as the parent would end the whole agent'):format(term))
      return
    end
    if read.detail and read.detail ~= '' then detail = read.detail end
    M.report(term, state, detail, name, session, read.sub)
    if read.children then
      M.reconcile(tonumber(term), session, read.children)
    end
  end)
  return ''
end

function M.clear(buf)
  local had = reported[buf]
  reported[buf] = nil
  observed[buf] = nil
  if had and vim.v.exiting == vim.NIL then
    local named
    for _, entry in pairs(had) do named = named or entry.name end
    announce(buf, 'ended', nil, named)
  end
end

local function live_agents(buf)
  local agents_here = reported[buf]
  if not agents_here then return nil end
  if not terminal_valid(buf) then
    reported[buf] = nil
    observed[buf] = nil
    return nil
  end
  return agents_here
end

function M.agents_in(buf)
  local agents_here = live_agents(buf)
  if not agents_here then return {} end
  local list = {}
  for _, entry in pairs(agents_here) do
    list[#list + 1] = entry
  end
  table.sort(list, function(a, b)
    if (a.parent == nil) ~= (b.parent == nil) then return a.parent == nil end
    return tostring(a.id) < tostring(b.id)
  end)
  return list
end

function M.state(buf)
  local agents_here = live_agents(buf)
  if not agents_here then return nil end
  local best
  for _, entry in pairs(agents_here) do
    if more_urgent(entry, best) then best = entry end
  end
  return best
end

function M.reconcile(buf, parent, live)
  local agents_here = reported[buf]
  if not agents_here or not parent then return false end
  local keep = {}
  for _, id in ipairs(live or {}) do keep[tostring(id)] = true end
  local pruned = false
  for id, entry in pairs(agents_here) do
    if entry.parent == parent and not keep[tostring(id)] then
      agents_here[id] = nil
      pruned = true
      log(('pruned term=%d %s: gone from the parent\'s task list'):format(buf, tostring(id)))
    end
  end
  if pruned then
    reported[buf] = next(agents_here) ~= nil and agents_here or nil
    announce(buf, 'ended', nil, nil)
  end
  return pruned
end

M.SWEEP_MS = 5000

local last_sweep = nil

local function sweepable(agents_here)
  for _, entry in pairs(agents_here) do
    if entry.name and M.command_name(entry.name) then return true end
  end
  return false
end

local function agent_names_under(children, commands, pid)
  local names = {}
  local own = M.command_name(commands[pid])
  if own then names[own] = true end
  walk_processes(children, pid, function(child)
    local name = M.command_name(commands[child])
    if name then names[name] = true end
  end)
  return names
end

function M.sweep(done)
  if not M.SWEEP_MS or vim.v.exiting ~= vim.NIL then
    if done then done(false) end
    return false
  end
  local now = vim.uv.hrtime() / 1e6
  if M.SWEEP_MS > 0 and last_sweep and now - last_sweep < M.SWEEP_MS then
    if done then done(false) end
    return false
  end
  local terminal = require('muxim.terminal')
  local candidates = {}
  for buf, agents_here in pairs(reported) do
    if sweepable(agents_here) and terminal.is_terminal(buf) and terminal.job_is_running(buf) then
      local pid = tonumber(vim.b[buf].terminal_job_pid)
      if pid then candidates[#candidates + 1] = { buf = buf, pid = pid } end
    end
  end
  if #candidates == 0 then
    if done then done(false) end
    return false
  end
  last_sweep = now
  local started = vim.uv.hrtime()
  M.process_tree(function(children, commands)
    if next(children) == nil then
      if done then done(false) end
      return
    end
    local swept = false
    for _, candidate in ipairs(candidates) do
      local agents_here = reported[candidate.buf]
      if agents_here then
        local present = agent_names_under(children, commands, candidate.pid)
        local seen = observed[candidate.buf] or {}
        observed[candidate.buf] = seen
        for name in pairs(present) do seen[name] = true end
        for id, entry in pairs(agents_here) do
          local command = not entry.parent and entry.name and M.command_name(entry.name)
          if command and seen[command] and not present[command]
              and (not entry.at or entry.at < started) then
            agents_here[id] = nil
            for child_id, child in pairs(agents_here) do
              if child.parent == id then agents_here[child_id] = nil end
            end
            log(('swept term=%d %s: the %s process this scan once saw under pid %d is gone')
              :format(candidate.buf, tostring(id), command, candidate.pid))
            announce(candidate.buf, 'ended', nil, entry.name)
            swept = true
          end
        end
        if next(agents_here) == nil then reported[candidate.buf] = nil end
      end
    end
    if done then done(swept) end
  end)
  return true
end

function M.tracked()
  local entries = {}
  for buf in pairs(reported) do
    for _, entry in ipairs(M.agents_in(buf)) do
      entries[#entries + 1] = {
        buf = buf,
        id = entry.id,
        parent = entry.parent,
        tab = require('muxim.terminal').owner(buf),
        name = entry.name or label(buf),
        state = entry.state,
        detail = entry.detail,
      }
    end
  end
  table.sort(entries, function(a, b)
    if (a.state == 'blocked') ~= (b.state == 'blocked') then
      return a.state == 'blocked'
    end
    if a.buf ~= b.buf then return a.buf < b.buf end
    if (a.parent == nil) ~= (b.parent == nil) then return a.parent == nil end
    return tostring(a.id) < tostring(b.id)
  end)
  return entries
end

function M.blocked()
  return vim.tbl_filter(function(entry) return entry.state == 'blocked' end, M.tracked())
end

function M.unwired(sessions)
  local silent = {}
  for _, session in ipairs(sessions or {}) do
    if session.current then
      for _, agent in ipairs(session.agents) do
        local vendor = M.vendor(agent.name)
        if agent.state == 'running' and not agent.wired and vendor and vendor.install then
          silent[#silent + 1] = agent
        end
      end
    end
  end
  return silent
end

function M.wire_up(name)
  local written = {}
  for _, vendor in ipairs(M.vendors()) do
    if vendor.install and (not name or vendor.name == name) then
      for _, dir in ipairs(vendor.config_dirs()) do
        local ok, detail = vendor.install(dir)
        if not ok then
          vim.notify('muxim: ' .. tostring(detail), vim.log.levels.ERROR)
          return false
        end
        written[#written + 1] = detail
      end
    end
  end
  if #written == 0 then
    vim.notify('muxim: ' .. (name or 'no agent muxim knows about')
      .. ' has nothing to install, they report as soon as muxim starts them')
    return true
  end
  vim.notify('muxim: agent hooks installed into ' .. table.concat(written, ', ')
    .. '. Restart the agent, or open the next one with the prefix key.')
  return true
end

local function fleet_blocked()
  local server = require('muxim.server')
  local runtime = require('muxim.runtime')
  for _, entry in ipairs(server.list()) do
    if entry.path ~= server.self_path then
      local state, readable = M.published(entry.path)
      if readable then
        for _, agent in ipairs(state.agents or {}) do
          if agent.state == 'blocked' then
            return runtime.display_name(entry.path), agent.name
          end
        end
      end
    end
  end
end

function M.focus_blocked()
  local blocked = M.blocked()
  if #blocked == 0 then
    local session, name = fleet_blocked()
    if session then
      vim.notify(('muxim: %s is blocked in %s, not here; %sw switches sessions'):format(
        name or 'an agent', session, require('muxim.keys').prefix or '<prefix>'))
    else
      vim.notify('muxim: no agent is blocked')
    end
    return false
  end
  local current = vim.api.nvim_get_current_buf()
  local from = 0
  for index, entry in ipairs(blocked) do
    if entry.buf == current then
      from = index
      break
    end
  end
  local target
  for offset = 1, #blocked do
    local entry = blocked[(from + offset - 1) % #blocked + 1]
    if entry.buf ~= current then
      target = entry
      break
    end
  end
  if not target then
    vim.notify('muxim: already at the blocked agent')
    return true
  end
  for _, win in ipairs(vim.fn.win_findbuf(target.buf)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(win))
      vim.api.nvim_set_current_win(win)
      return true
    end
  end
  if target.tab and vim.api.nvim_tabpage_is_valid(target.tab) then
    vim.api.nvim_set_current_tabpage(target.tab)
  end
  if vim.bo.buftype ~= '' or vim.bo.modified then
    vim.cmd('split')
  end
  vim.api.nvim_set_current_buf(target.buf)
  return true
end

function M.tab_state(tab, entries)
  local state
  for _, entry in ipairs(entries or M.tracked()) do
    if entry.tab == tab and entry.state then
      if not state or (STATE_RANK[entry.state] or 9) < (STATE_RANK[state] or 9) then
        state = entry.state
      end
    end
  end
  return state
end

function M.tab_mark(tab)
  local state = M.tab_state(tab)
  return state and M.MARKS[state] or nil
end

function M.env(buf)
  local self_path = require('muxim.server').self_path
  if not M.enabled or not self_path then return nil end
  local env = {}
  for _, vendor in ipairs(M.vendors()) do
    if vendor.env then
      env = vim.tbl_extend('force', env, vendor.env() or {})
    end
  end
  local extra = {
    MUXIM_TERM = tostring(buf),
    MUXIM_SERVER = self_path,
    MUXIM_NVIM = vim.v.progpath,
    MUXIM_HOOK = M.hook_path(),
    MUXIM_SHELL_INIT = M.shell_init_path(),
  }
  local bin = M.wrapper_dir()
  local path = vim.env.PATH
  if path and vim.uv.fs_stat(M.wrapper_path()) then
    extra.MUXIM_BIN = bin
    if path:sub(1, #bin + 1) ~= bin .. ':' then
      extra.PATH = bin .. ':' .. path
    end
  end
  return vim.tbl_extend('force', env, extra)
end

function M.setup(opts)
  if opts == false then
    M.enabled = false
    M.unwatch_fleet()
    M.unpublish()
    return
  end
  opts = opts or {}
  M.enabled = true
  if opts.notify ~= nil then
    M.notify = opts.notify
  end
  if opts.notify_fleet ~= nil then
    M.notify_fleet = opts.notify_fleet
  end
  if opts.commands then
    M.COMMANDS = {}
    for key, value in pairs(opts.commands) do
      if type(key) == 'string' then
        M.COMMANDS[key] = value ~= false
      else
        M.COMMANDS[value] = true
      end
    end
  end
  if opts.marks then
    M.MARKS = vim.tbl_extend('force', M.MARKS, opts.marks)
  end
  if opts.drawer then
    require('muxim.drawer').setup(opts.drawer)
  end
  if not M.hook_is_current() then
    M.write_hook()
  end
  for _, vendor in ipairs(M.vendors()) do
    if vendor.setup then
      vendor.setup(opts[vendor.name])
    end
    if vendor.ensure then
      vendor.ensure()
    end
  end
  if not M.shell_init_is_current() then
    M.write_shell_init()
  end
  if not M.wrapper_is_current() then
    M.write_wrapper()
  end
  local group = vim.api.nvim_create_augroup('muxim_agents', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'MuximAgentState',
    callback = function()
      pcall(M.publish)
      pcall(M.sweep)
    end,
  })
  vim.api.nvim_create_autocmd({ 'FocusGained', 'FocusLost' }, {
    group = group,
    callback = function(args)
      M.focused = args.event == 'FocusGained'
      if M.focused then pcall(M.sweep) end
    end,
  })
  vim.api.nvim_create_autocmd('TermClose', {
    group = group,
    callback = function(args) M.clear(args.buf) end,
  })
  vim.api.nvim_create_autocmd('TermOpen', {
    group = group,
    callback = function()
      if vim.v.exiting ~= vim.NIL then return end
      pcall(M.publish)
    end,
  })
  vim.api.nvim_create_autocmd({ 'TabNew', 'TabClosed', 'TabEnter', 'BufWinEnter' }, {
    group = group,
    callback = function()
      if vim.v.exiting ~= vim.NIL then return end
      pcall(M.publish)
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      pcall(M.unpublish)
      pcall(M.unwatch_fleet)
    end,
  })
  M.unwatch_fleet()
  M.watch_fleet()
  for _, vendor in ipairs(M.vendors()) do
    if vendor.attach then
      vendor.attach(group)
    end
  end
  M.publish()
end

return M
