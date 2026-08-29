local M = {}

local health = vim.health

local function check_version()
  health.start('Neovim')
  if vim.fn.has('nvim-0.12') == 1 then
    health.ok('Neovim ' .. tostring(vim.version()) .. ' (0.12+ required)')
  else
    health.error('Neovim 0.12+ required', 'muxim needs the :connect command to attach to sessions')
  end
  if vim.fn.exists(':connect') == 2 then
    health.ok(':connect is available')
  else
    health.error(':connect is not available in this build')
  end
end

local function check_runtime_dir()
  health.start('Runtime directory')
  local runtime = require('muxim.runtime')
  local ok, dir = pcall(runtime.dir)
  if not ok then
    health.error('runtime directory unusable: ' .. dir)
    return
  end
  if runtime.is_fallback_dir() then
    health.warn(dir .. ' (no XDG_RUNTIME_DIR, using a shared temp directory)',
      'sockets here survive logout and depend on the temp directory surviving cleanup')
  else
    health.ok(dir)
  end
  local stat = vim.uv.fs_stat(dir)
  if stat then
    local mode = bit.band(stat.mode, tonumber('777', 8))
    if mode == tonumber('700', 8) then
      health.ok('mode 0700, owned by you')
    else
      health.warn(('mode %o (expected 0700)'):format(mode),
        'other users may be able to reach your sockets')
    end
  end
  local probe = dir .. '/health-probe'
  local fd = vim.uv.fs_open(probe, 'w', tonumber('600', 8))
  if fd then
    vim.uv.fs_close(fd)
    vim.uv.fs_unlink(probe)
    health.ok('writable')
  else
    health.error('not writable')
  end
  local budget = runtime.name_budget()
  if budget >= 8 then
    health.ok(('%d bytes of socket-name budget (sun_path is %d here)'):format(budget, runtime.SUN_PATH_MAX))
  else
    health.error(('runtime directory path leaves only %d bytes for socket names'):format(budget),
      'libuv truncates sun_path silently; sockets would be unreachable')
  end
end

local function check_progpath()
  health.start('Server binary')
  local progpath = vim.v.progpath
  if vim.uv.fs_stat(progpath) then
    local result = vim.system({ progpath, '--version' }, { text = true }):wait()
    local first = vim.split(result.stdout or '', '\n')[1] or ''
    health.ok(progpath .. ' (' .. first .. ')')
  else
    health.error(progpath .. ' does not exist',
      'spawned sessions run this binary; a moved or deleted nvim breaks spawning')
  end
end

local function check_sockets()
  health.start('Sockets')
  local runtime = require('muxim.runtime')
  local server = require('muxim.server')
  local paths = runtime.sockets()
  if #paths == 0 then
    health.ok('no sockets in ' .. runtime.dir())
    return
  end
  for _, path in ipairs(paths) do
    if server.is_live(path) then
      health.ok('live:  ' .. path)
    else
      health.warn('stale: ' .. path, 'run :MuximClean to remove stale sockets')
    end
  end
end

local function check_foreign_sockets()
  health.start('Sockets outside muxim')
  local xdg = vim.env.XDG_RUNTIME_DIR
  if not xdg or xdg == '' then
    health.info('no XDG_RUNTIME_DIR to scan')
    return
  end
  local ok, iter = pcall(vim.fs.dir, xdg)
  if not ok then
    health.info('cannot read ' .. xdg)
    return
  end
  local server = require('muxim.server')
  local dead = {}
  for entry, kind in iter do
    local path = xdg .. '/' .. entry
    if kind ~= 'directory' and entry:sub(-5) == '.sock' and not server.is_live(path) then
      dead[#dead + 1] = path
    end
  end
  if #dead == 0 then
    health.ok('no dead sockets in ' .. xdg)
    return
  end
  for _, path in ipairs(dead) do
    health.warn('dead: ' .. path,
      'left by a session that died; :MuximClean does not reach outside the muxim directory, delete it by hand')
  end
end

local function check_quit_log()
  local lines = require('muxim.server').log_lines()
  if #lines == 0 then return end
  health.start('Quitting')
  for i = #lines, math.max(1, #lines - 4), -1 do
    health.info(lines[i])
  end
  health.info('full log: ' .. require('muxim.runtime').dir() .. '/quit.log')
end

local function check_claim()
  health.start('This instance')
  local server = require('muxim.server')
  if vim.g.muxim_nested then
    health.warn('nested instance ($NVIM is set): setup() bailed before claiming a socket',
      'pass setup({ nested = true }) to override, if you know why')
    return
  end
  if not server.self_path then
    health.error('no socket claimed (server.self_path is nil)',
      'setup() did not run, or every claim attempt failed; check :messages')
    return
  end
  if vim.tbl_contains(vim.fn.serverlist(), server.self_path) then
    health.ok('attached as ' .. server.self_path)
  else
    health.error(server.self_path .. ' is recorded but missing from serverlist()')
  end
  local env = vim.env.MUXIM_SERVER
  if env == server.self_path then
    health.ok('$MUXIM_SERVER agrees')
  else
    health.warn(('$MUXIM_SERVER is %s'):format(env or 'unset'),
      'jobs started before setup() ran inherit the wrong value')
  end
end

local function check_picker()
  health.start('Picker')
  local pickers = require('muxim.pickers')
  local configured = pickers.backend
  if type(configured) == 'table' then
    health.ok('custom backend table configured')
    return
  end
  if type(configured) == 'string' then
    if pcall(require, 'muxim.pickers.' .. configured) then
      health.ok("backend '" .. configured .. "' (configured)")
    else
      health.error(("configured backend '%s' does not exist"):format(configured),
        'falls back to vim.ui.select at call time')
    end
    return
  end
  if pcall(require, 'telescope') then
    health.ok('backend: telescope (auto-detected)')
  else
    health.ok('backend: vim.ui.select (telescope not installed)')
  end
end

local function check_agent_wiring()
  local agents = require('muxim.agents')
  for _, vendor in ipairs(agents.vendors()) do
    if vendor.health then
      vendor.health(health)
    end
  end
  if agents.shell_init_is_current() then
    health.ok('agents you TYPE are wired if your shell rc has: '
      .. '[ -n "$MUXIM_SHELL_INIT" ] && . "$MUXIM_SHELL_INIT"')
  else
    health.warn('the shell init file is missing or stale', 'it is rewritten by setup()')
  end
  if not vim.uv.fs_stat(agents.hook_path()) then
    health.warn(agents.hook_path() .. ' is missing', 'run :MuximAgentSetup')
  elseif not agents.hook_is_current() then
    health.warn(agents.hook_path() .. ' was written by an older muxim',
      'run :MuximAgentSetup to rewrite it')
  else
    health.ok(agents.hook_path())
  end
end

local function check_agent_coverage()
  local agents = require('muxim.agents')
  local terminals = agents.terminals()
  local mute = 0
  for _, term in ipairs(terminals) do
    if not term.reports then mute = mute + 1 end
  end
  health.info(('%d terminal%s here, %d can report'):format(
    #terminals, #terminals == 1 and '' or 's', #terminals - mute))
  if mute > 0 then
    health.warn(('%d terminal%s carr%s no $MUXIM_TERM, so nothing in %s can report'):format(
      mute, mute == 1 and '' or 's', mute == 1 and 'ies' or 'y', mute == 1 and 'it' or 'them'),
      'muxim injects it at jobstart, so this is a terminal opened another way, or one '
      .. 'opened before this session claimed its socket')
  end
end

local function check_agents()
  health.start('Agents')
  local agents = require('muxim.agents')
  if not agents.enabled then
    health.info('agent watching is off (agents = false)')
    return
  end
  check_agent_wiring()
  check_agent_coverage()
  local tracked = agents.tracked()
  local blocked = agents.blocked()
  health.ok(('%d agent%s reporting here, %d blocked'):format(
    #tracked, #tracked == 1 and '' or 's', #blocked))
  health.info('notify: ' .. tostring(agents.notify))
  if not agents.notify_desktop then
    health.info('desktop notifications are off (notify_desktop = false, the default)')
  elseif agents.desktop_argv('muxim', 'probe') then
    health.ok('a desktop notification command is available for when nvim is unfocused')
  else
    health.warn('no desktop notification command',
      'install notify-send (libnotify) so a blocked agent reaches you when nvim is unfocused')
  end
  if not agents.notify_fleet then
    health.info('agents in other sessions do not notify here (notify_fleet = false)')
  elseif type(agents.watching_fleet) ~= 'function' then
    health.warn('this session loaded an older muxim than the one on disk',
      'reload it with :ConfigReload, or restart it')
  elseif agents.watching_fleet() then
    health.ok(('watching %d other session%s, so an agent blocking there notifies here')
      :format(agents.fleet_size(), agents.fleet_size() == 1 and '' or 's'))
  else
    health.warn('not watching the other sessions',
      'an agent blocking elsewhere will not notify you here. Reload this session')
  end
  if not agents.can_discover then
    health.warn('no usable `ps`, so agents that have not reported cannot be discovered',
      'hook-reported state still works; only "running" rows are missing')
  end
  local reports = agents.log_lines()
  if #reports == 0 then
    health.warn('nothing has ever reported on this machine',
      'Claude Code reloads settings into running agents, so a missing report means '
      .. 'the hook never ran: check the paths above')
  else
    for i = #reports, math.max(1, #reports - 2), -1 do
      health.info(reports[i])
    end
  end
end

local function check_keys()
  health.start('Keys')
  local keys = require('muxim.keys')
  if not keys.prefix then
    health.warn('no prefix mapped (keys = false, or setup() has not run)')
    return
  end
  for _, mode in ipairs({ 'n', 't' }) do
    local map = vim.fn.maparg(keys.prefix, mode, false, true)
    if map and map.desc == 'muxim prefix' then
      health.ok(('prefix %s mapped in %s mode'):format(keys.prefix, mode))
    else
      health.error(('prefix %s in %s mode is %s'):format(
        keys.prefix, mode,
        (map and map.lhs) and 'mapped by something else' or 'not mapped'),
        'another plugin mapped over it after setup()')
    end
  end
end

local function check_tabline()
  health.start('Tabline')
  local ours = require('muxim.tabline').EXPR
  if vim.o.tabline == ours then
    health.ok('tabline is muxim')
  elseif vim.o.tabline == '' then
    health.warn('tabline is unset (tabline = false, or setup() has not run)')
  else
    health.warn('tabline was taken over: ' .. vim.o.tabline,
      'a statusline/tabline plugin loaded after muxim')
  end
end

local function section(name, check)
  local ok, err = pcall(check)
  if ok then return true end
  health.error(('the %s check itself failed: %s'):format(name, err),
    'that is a bug in muxim, and every check after it still ran')
  return false
end

function M.check()
  section('Neovim', check_version)
  section('runtime directory', check_runtime_dir)
  section('server binary', check_progpath)
  section('socket', check_sockets)
  section('foreign socket', check_foreign_sockets)
  section('quit log', check_quit_log)
  section('claim', check_claim)
  section('picker', check_picker)
  section('agents', check_agents)
  section('keys', check_keys)
  section('tabline', check_tabline)
end

return M
