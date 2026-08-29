local agents = require('muxim.agents')
local fsutil = require('muxim.fsutil')

local M = {}

M.name = 'claude'

M.title = 'Claude Code'

M.EVENTS = {
  { event = 'PermissionRequest', state = 'blocked', detail = 'permission needed' },
  { event = 'PermissionDenied', state = 'working', detail = '' },
  { event = 'Notification', matcher = 'permission_prompt', state = 'blocked', detail = 'permission needed' },
  { event = 'Notification', matcher = 'idle_prompt', state = 'blocked', detail = 'waiting for you' },
  { event = 'Notification', matcher = 'agent_needs_input', state = 'blocked', detail = 'input needed' },
  { event = 'Notification', matcher = 'agent_completed', state = 'done', detail = '' },
  { event = 'Elicitation', state = 'blocked', detail = 'input needed' },
  { event = 'ElicitationResult', state = 'working', detail = '' },
  { event = 'UserPromptSubmit', state = 'working', detail = '' },
  { event = 'PreToolUse', state = 'working', detail = '' },
  { event = 'PostToolUse', state = 'working', detail = '' },
  { event = 'PostToolUseFailure', state = 'working', detail = '' },
  { event = 'PreCompact', state = 'working', detail = 'compacting' },
  { event = 'PostCompact', matcher = 'auto', state = 'working', detail = '' },
  { event = 'PostCompact', matcher = 'manual', state = 'idle', detail = 'waiting for you' },
  { event = 'Stop', state = 'idle', detail = 'waiting for you' },
  { event = 'StopFailure', state = 'idle', detail = 'the turn failed' },
  { event = 'SubagentStart', state = 'working', detail = '' },
  { event = 'SubagentStop', state = 'ended', detail = '' },
  { event = 'SessionStart', matcher = 'startup|resume|fork', state = 'idle', detail = 'waiting for you' },
  { event = 'SessionEnd', matcher = 'logout|prompt_input_exit|other', state = 'ended', detail = '' },
}

M.HOOK_TIMEOUT = 10

M.PAYLOAD_DETAIL = {
  StopFailure = 'error',
  Notification = 'message',
  Stop = 'last_assistant_message',
  PermissionRequest = 'tool_name',
  PermissionDenied = 'tool_name',
  Elicitation = 'message',
}

M.DETAIL_PREFIX = {
  PermissionRequest = 'wants to use ',
  PermissionDenied = 'denied ',
}

local function text(value)
  return type(value) == 'string' and value or nil
end

local function subagent(payload)
  if not text(payload.agent_id) then return nil end
  return { id = payload.agent_id, type = text(payload.agent_type) }
end

local function live_children(payload)
  if type(payload.background_tasks) ~= 'table' then return nil end
  local ids = {}
  for _, task in ipairs(payload.background_tasks) do
    if type(task) == 'table' and task.type == 'subagent' and type(task.id) == 'string' then
      ids[#ids + 1] = task.id
    end
  end
  return ids
end

local function detail_for(payload)
  local field = M.PAYLOAD_DETAIL[payload.hook_event_name]
  local said = field and text(payload[field])
  if not said then return nil end
  return (M.DETAIL_PREFIX[payload.hook_event_name] or '') .. said
end

local SUBAGENT_EVENTS = { SubagentStart = true, SubagentStop = true }

function M.read(payload)
  return {
    detail = detail_for(payload),
    sub = subagent(payload),
    subagent_event = SUBAGENT_EVENTS[payload.hook_event_name] or nil,
    children = payload.hook_event_name == 'Stop' and live_children(payload) or nil,
  }
end

M.MARKER = 'muxim/agent-hook'

M.extra_config_dirs = {}

function M.setup(opts)
  M.extra_config_dirs = opts and opts.config_dirs or {}
end

function M.default_config_dir()
  local dir = vim.env.CLAUDE_CONFIG_DIR
  if dir and dir ~= '' then
    return dir
  end
  return vim.fn.expand('~/.claude')
end

function M.settings_path(dir)
  return (dir or M.default_config_dir()) .. '/settings.json'
end

function M.config_dirs()
  local dirs, seen = {}, {}
  local function add(dir)
    if dir and dir ~= '' and not seen[dir] then
      seen[dir] = true
      dirs[#dirs + 1] = dir
    end
  end
  add(M.default_config_dir())
  for _, dir in ipairs(M.extra_config_dirs) do
    add(vim.fn.expand(dir))
  end
  return dirs
end

local function sh_quote(text)
  return "'" .. (tostring(text):gsub("'", "'\\''")) .. "'"
end

local function command_for(event)
  return ('"${MUXIM_HOOK:-%s}" %s %s %s'):format(
    agents.hook_command_path(), sh_quote(event.state), sh_quote(event.detail), sh_quote(M.name))
end

local function program_word(command)
  local quote = command:sub(1, 1)
  if quote == '"' or quote == "'" then
    return command:match('^' .. quote .. '(.-)' .. quote) or command
  end
  return command:match('^(%S+)') or command
end

local function hook_target(command)
  local word = program_word(command)
  local path = word:match('^%${MUXIM_HOOK:%-(.*)}$') or word
  return (path:gsub('^%$HOME', vim.env.HOME or ''))
end

local INDENT = '  '

local function key_order(raw)
  local order, seen, position = {}, {}, 0
  for key in (raw or ''):gmatch('"([^"]+)"%s*:') do
    position = position + 1
    if not seen[key] then
      seen[key] = position
      order[key] = position
    end
  end
  return order
end

local function sorted_keys(value, order)
  local keys = vim.tbl_keys(value)
  table.sort(keys, function(a, b)
    local rank_a, rank_b = order[a], order[b]
    if rank_a and rank_b then return rank_a < rank_b end
    if rank_a then return true end
    if rank_b then return false end
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function encode(value, depth, order)
  if value == vim.NIL or value == nil then return 'null' end
  if type(value) ~= 'table' then return vim.json.encode(value) end

  local pad = INDENT:rep(depth + 1)
  local closing = INDENT:rep(depth)
  if vim.islist(value) then
    if #value == 0 then return '[]' end
    local parts = {}
    for _, item in ipairs(value) do
      parts[#parts + 1] = pad .. encode(item, depth + 1, order)
    end
    return '[\n' .. table.concat(parts, ',\n') .. '\n' .. closing .. ']'
  end

  local keys = sorted_keys(value, order)
  if #keys == 0 then return '{}' end
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = pad .. vim.json.encode(tostring(key)) .. ': '
      .. encode(value[key], depth + 1, order)
  end
  return '{\n' .. table.concat(parts, ',\n') .. '\n' .. closing .. '}'
end

function M.plugin_dir()
  return vim.fn.stdpath('data') .. '/muxim/claude-plugin'
end

local function plugin_files()
  local hooks = {}
  for _, event in ipairs(M.EVENTS) do
    hooks[event.event] = hooks[event.event] or {}
    local entry = {
      hooks = { {
        type = 'command',
        command = command_for(event),
        async = true,
        timeout = M.HOOK_TIMEOUT,
      } },
    }
    if event.matcher then
      entry.matcher = event.matcher
    end
    table.insert(hooks[event.event], entry)
  end
  return {
    ['.claude-plugin/plugin.json'] = encode({
      name = 'muxim',
      version = '1.0.0',
      description = 'Reports agent state to the muxim session that owns this terminal',
    }, 0, {}) .. '\n',
    ['hooks/hooks.json'] = encode({ hooks = hooks }, 0, {}) .. '\n',
  }
end

function M.plugin_is_current()
  for name, body in pairs(plugin_files()) do
    if not fsutil.matches(M.plugin_dir() .. '/' .. name, body) then return false end
  end
  return true
end

function M.write_plugin()
  for name, body in pairs(plugin_files()) do
    if not fsutil.write_atomic(M.plugin_dir() .. '/' .. name, body) then return false end
  end
  return true
end

function M.ensure()
  if not M.plugin_is_current() then
    M.write_plugin()
  end
end

function M.env()
  return { MUXIM_CLAUDE_PLUGIN = M.plugin_dir() }
end

function M.wired(argv)
  return argv:find(M.plugin_dir(), 1, true) ~= nil
end

function M.shell_init()
  return table.concat({
    'claude() {',
    '  if [ -n "${MUXIM_CLAUDE_PLUGIN:-}" ]; then',
    '    command claude --plugin-dir "$MUXIM_CLAUDE_PLUGIN" "$@"',
    '  else',
    '    command claude "$@"',
    '  fi',
    '}',
  }, '\n')
end

function M.launch_argv(extra)
  local argv = { 'claude', '--plugin-dir', M.plugin_dir() }
  for _, value in ipairs(extra or {}) do
    argv[#argv + 1] = value
  end
  return argv
end

function M.launch(extra)
  if vim.fn.executable('claude') ~= 1 then
    return nil, 'no `claude` on PATH'
  end
  if not M.write_plugin() then
    return nil, 'could not write ' .. M.plugin_dir() .. ', so the agent would start unwired'
  end
  return M.launch_argv(extra)
end

function M.is_ours(entry)
  local hooks = type(entry) == 'table' and entry.hooks or nil
  if type(hooks) ~= 'table' then return false end
  for _, hook in ipairs(hooks) do
    if type(hook) == 'table' and type(hook.command) == 'string'
        and program_word(hook.command):find(M.MARKER, 1, true) then
      return true
    end
  end
  return false
end

local function is_current(entry, event)
  local hooks = type(entry) == 'table' and entry.hooks or nil
  if type(hooks) ~= 'table' then return false end
  for _, hook in ipairs(hooks) do
    if type(hook) == 'table' and hook.command == command_for(event) then
      return true
    end
  end
  return false
end

local function without_ours(list)
  local kept = {}
  for _, entry in ipairs(list or {}) do
    if not M.is_ours(entry) then
      kept[#kept + 1] = entry
    end
  end
  return kept
end

function M.read_settings(dir)
  local raw = fsutil.read(M.settings_path(dir)) or ''
  if vim.trim(raw) == '' then return {} end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= 'table' then return nil end
  if next(decoded) ~= nil and vim.islist(decoded) then return nil end
  return decoded
end

local function write_settings(settings, dir)
  local target = M.settings_path(dir)
  local order = key_order(fsutil.read(target) or '')
  local stat = vim.uv.fs_stat(target)
  vim.fn.mkdir(vim.fn.fnamemodify(target, ':h'), 'p', tonumber('700', 8))
  target = vim.uv.fs_realpath(target) or target
  local body = next(settings) == nil and '{}' or encode(settings, 0, order)
  local mode = stat and bit.band(stat.mode, tonumber('777', 8)) or tonumber('600', 8)
  return fsutil.write_atomic(target, body .. '\n', mode)
end

function M.installed(dir)
  local settings = M.read_settings(dir)
  if not settings or type(settings.hooks) ~= 'table' then return false end
  for _, event in ipairs(M.EVENTS) do
    local found = false
    for _, entry in ipairs(settings.hooks[event.event] or {}) do
      if type(entry) == 'table' and entry.matcher == event.matcher and is_current(entry, event) then
        found = true
      end
    end
    if not found then return false end
  end
  return agents.hook_is_current()
end

function M.has_entries(dir)
  local settings = M.read_settings(dir)
  if not settings or type(settings.hooks) ~= 'table' then return false end
  for _, entries in pairs(settings.hooks) do
    for _, entry in ipairs(entries or {}) do
      if M.is_ours(entry) then return true end
    end
  end
  return false
end

function M.stale_entries(dir)
  local settings = M.read_settings(dir)
  if not settings or type(settings.hooks) ~= 'table' then return {} end
  local stale = {}
  for _, entries in pairs(settings.hooks) do
    for _, entry in ipairs(entries or {}) do
      if M.is_ours(entry) then
        for _, hook in ipairs(entry.hooks or {}) do
          local path = type(hook.command) == 'string' and hook_target(hook.command) or nil
          if path and not vim.uv.fs_stat(path) then
            stale[#stale + 1] = path
          end
        end
      end
    end
  end
  return stale
end

function M.health(health)
  if M.plugin_is_current() then
    health.ok('agents muxim starts are wired with no setup at all (' .. M.plugin_dir() .. ')')
  else
    health.warn('the plugin directory is missing or stale', 'it is rewritten by setup()')
  end
  for _, dir in ipairs(M.config_dirs()) do
    local path = M.settings_path(dir)
    if M.read_settings(dir) == nil then
      health.warn(path .. ' is not valid JSON',
        'muxim will refuse to install hooks rather than damage it')
    elseif M.installed(dir) then
      health.ok('Claude Code hooks installed in ' .. path)
    elseif M.has_entries(dir) then
      health.warn('the muxim hooks in ' .. path .. ' are not what muxim writes today',
        'an older muxim, or a hand edit. :MuximAgentSetup ' .. dir .. ' replaces them')
    else
      health.info('no muxim hooks in ' .. path,
        'not needed if you start agents with the prefix key or source the shell init; '
        .. ':MuximAgentSetup ' .. dir .. ' is the fallback')
    end
    for _, stale in ipairs(M.stale_entries(dir)) do
      health.error(path .. ' points at ' .. stale .. ', which does not exist here',
        'an install from another machine. Run :MuximAgentSetup ' .. dir .. ' to replace it')
    end
  end
end

function M.install(dir)
  local settings = M.read_settings(dir)
  if not settings then
    return false, M.settings_path(dir) .. ' is not valid JSON, refusing to touch it'
  end
  if not agents.write_hook() then
    return false, 'could not write ' .. agents.hook_path()
  end
  settings.hooks = type(settings.hooks) == 'table' and settings.hooks or {}
  local cleaned = {}
  for _, event in ipairs(M.EVENTS) do
    if not cleaned[event.event] then
      cleaned[event.event] = true
      settings.hooks[event.event] = without_ours(settings.hooks[event.event])
    end
    local entry = {
      hooks = { {
        type = 'command',
        command = command_for(event),
        async = true,
        timeout = M.HOOK_TIMEOUT,
      } },
    }
    if event.matcher then
      entry.matcher = event.matcher
    end
    table.insert(settings.hooks[event.event], entry)
  end
  if not write_settings(settings, dir) then
    return false, 'could not write ' .. M.settings_path(dir)
  end
  return true, M.settings_path(dir)
end

function M.uninstall(dir)
  local settings = M.read_settings(dir)
  if not settings then
    return false, M.settings_path(dir) .. ' is not valid JSON, refusing to touch it'
  end
  if type(settings.hooks) ~= 'table' then
    return true, M.settings_path(dir)
  end
  for event, entries in pairs(settings.hooks) do
    local kept = without_ours(entries)
    settings.hooks[event] = #kept > 0 and kept or nil
  end
  if vim.tbl_isempty(settings.hooks) then
    settings.hooks = nil
  end
  if not write_settings(settings, dir) then
    return false, 'could not write ' .. M.settings_path(dir)
  end
  return true, M.settings_path(dir)
end

return M
