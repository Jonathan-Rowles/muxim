local H = dofile('tests/helper.lua')
local claude = require('muxim.agents.claude')
local agents = require('muxim.agents')
local terminal = require('muxim.terminal')

vim.env.CLAUDE_CONFIG_DIR = H.runtime_dir() .. '/claude-config'
vim.fn.mkdir(vim.env.CLAUDE_CONFIG_DIR, 'p', tonumber('700', 8))
H.contains(claude.settings_path(), H.runtime_dir(), 'the spec writes to its own settings file, never yours')

local function write_settings(text)
  local file = io.open(claude.settings_path(), 'w')
  file:write(text)
  file:close()
end

local function read_settings()
  return vim.json.decode(table.concat(vim.fn.readfile(claude.settings_path()), '\n'))
end

write_settings([[{
  "model": "opus",
  "statusLine": { "type": "command", "command": "bash ~/status.sh" },
  "hooks": {
    "SessionEnd": [ { "hooks": [ { "type": "command", "command": "somebody-elses-hook" } ] } ]
  }
}]])

H.eq(claude.installed(), false, 'nothing is installed to begin with')

local ok, detail = claude.install()
H.eq(ok, true, 'install reports success: ' .. tostring(detail))
H.eq(claude.installed(), true, 'and installed() agrees')

local settings = read_settings()
H.eq(settings.model, 'opus', 'unrelated settings survive')
H.eq(settings.statusLine.command, 'bash ~/status.sh', 'including nested ones')

local matchers = {}
for _, entry in ipairs(settings.hooks.Notification) do
  matchers[entry.matcher] = entry.hooks[1].command
end
H.contains(matchers.permission_prompt or '', "'blocked'",
  'permission_prompt reports blocked: it is what an INTERACTIVE claude emits when it wants you')
H.contains(matchers.permission_prompt or '', 'permission needed', 'with a reason')
H.contains(matchers.idle_prompt or '', "'blocked'",
  'and idle_prompt covers the agent that has gone quiet waiting')
H.contains(matchers.agent_needs_input or '', "'blocked'",
  'agent_needs_input is kept for background agents, which is the only band that emits it')
H.contains(matchers.agent_completed or '', "'done'", 'agent_completed reports done')
H.contains(settings.hooks.PermissionRequest[1].hooks[1].command, "'blocked'",
  'PermissionRequest blocks too, and unlike the notification it knows WHICH tool')
H.eq(settings.hooks.PermissionRequest[1].matcher, nil, 'for every tool, so it is unmatched')

local seen_events = {}
for _, event in ipairs(claude.EVENTS) do
  local key = event.event .. '/' .. tostring(event.matcher)
  H.eq(seen_events[key], nil, 'no event is declared twice: ' .. key)
  seen_events[key] = true
end
for event in pairs(settings.hooks) do
  local ours = 0
  for _, entry in ipairs(settings.hooks[event]) do
    if claude.is_ours(entry) then ours = ours + 1 end
  end
  local want = 0
  for _, declared in ipairs(claude.EVENTS) do
    if declared.event == event then want = want + 1 end
  end
  H.eq(ours, want, ('%s is installed exactly as often as it is declared'):format(event))
end
H.contains(settings.hooks.PermissionRequest[1].hooks[1].command, "'blocked'",
  'PermissionRequest blocks too, and unlike the notification it knows WHICH tool')
H.eq(settings.hooks.PermissionRequest[1].matcher, nil, 'for every tool, so it is unmatched')

H.contains(settings.hooks.StopFailure[1].hooks[1].command, "'idle'",
  'StopFailure ends the WORKING state too. Stop has a sibling for the failure path and '
  .. 'muxim subscribed only Stop, so an agent whose turn died sat at "working" forever, '
  .. 'which is the same silence that hid the missing Stop')
H.eq(settings.hooks.StopFailure[1].matcher, nil,
  'unmatched, because every failure reason should end the turn')

H.contains(settings.hooks.PermissionDenied[1].hooks[1].command, "'working'",
  'a denial hands control back to the agent, so it UNBLOCKS the PermissionRequest row '
  .. 'instead of leaving it stuck at blocked')
H.eq(settings.hooks.PermissionDenied[1].matcher, nil, 'whatever the tool was')

H.contains(settings.hooks.PreToolUse[1].hooks[1].command, "'working'",
  'a tool starting reports working. PreToolUse fires BEFORE permission evaluation, so '
  .. 'for the granted tool itself the unblock comes from its PostToolUse; PreToolUse '
  .. 'covers every later tool in the turn')
H.contains(settings.hooks.PostToolUse[1].hooks[1].command, "'working'",
  'nothing fires AT a grant, so the granted tool finishing is the earliest signal after '
  .. 'one, and blocked stops showing for the rest of a long turn')
H.contains(settings.hooks.PostToolUseFailure[1].hooks[1].command, "'working'",
  'and a tool failing says the same, because its Post sibling does not fire then. All '
  .. 'three carry no detail on purpose: consecutive reports dedup in report(), so a turn '
  .. 'with thirty tool calls publishes the working transition once, not thirty times')

H.contains(settings.hooks.Elicitation[1].hooks[1].command, "'blocked'",
  'an MCP server asking for input is a real blocked cause muxim could not see at all')
H.contains(settings.hooks.ElicitationResult[1].hooks[1].command, "'working'",
  'and answering it, however it was answered, unblocks')

H.contains(settings.hooks.PreCompact[1].hooks[1].command, "'compacting'",
  'compaction is OBSERVABLE rather than inferred: an auto-compaction corrupted state '
  .. 'on 2026-08-25 with nothing visible anywhere')
H.eq(settings.hooks.PreCompact[1].matcher, nil, 'both triggers compact the same way')
local post_compact = {}
for _, entry in ipairs(settings.hooks.PostCompact) do
  post_compact[entry.matcher] = entry.hooks[1].command
end
H.contains(post_compact.auto or '', "'working'",
  'auto-compaction happens mid-turn, so when it ends the agent is still working')
H.contains(post_compact.manual or '', "'idle'",
  'manual /compact happens while waiting, so when it ends the agent is idle again. '
  .. 'Splitting on a matcher is safe: the 2.1.247 bundle matches PreCompact and '
  .. 'PostCompact on e.trigger, alongside Notification on e.notification_type')

H.eq(claude.read({ hook_event_name = 'StopFailure', error = 'billing_error' }).detail,
  'billing_error',
  'a failed turn says WHY, out of the payload rather than a hardcoded string. Observed '
  .. 'from a real run: error=billing_error, and Stop did NOT fire alongside it')
H.eq(claude.read({ hook_event_name = 'Stop', last_assistant_message = 'all green' }).detail,
  'all green', 'and a finished turn shows what the agent actually said')
H.eq(claude.read({ hook_event_name = 'Notification', message = 'needs input' }).detail,
  'needs input', 'and a notification shows its real message')
H.eq(claude.read({ hook_event_name = 'Stop' }).detail, nil,
  'a missing field falls back to the detail the hook was given')
H.eq(claude.read({ hook_event_name = 'Stop', last_assistant_message = { 'nope' } }).detail, nil,
  'a field of the wrong type is ignored rather than crashing the report')

H.eq(claude.read({ hook_event_name = 'PermissionRequest', tool_name = 'Bash' }).detail,
  'wants to use Bash',
  'a permission request names the tool, so a blocked row stops saying "permission '
  .. 'needed" and starts saying what it is waiting to do')
H.eq(claude.read({ hook_event_name = 'PermissionRequest' }).detail, nil,
  'and with no tool_name it falls back to the static detail rather than saying '
  .. '"wants to use " and nothing')

H.eq(claude.read({ hook_event_name = 'PermissionRequest', tool_name = 'Bash' }).detail,
  'wants to use Bash',
  'a permission request names the tool, so a blocked row stops saying "permission '
  .. 'needed" and starts saying what it is waiting to do')
H.eq(claude.read({ hook_event_name = 'PermissionRequest' }).detail, nil,
  'and with no tool_name it falls back to the static detail rather than saying '
  .. '"wants to use " and nothing')

H.eq(claude.read({ hook_event_name = 'PermissionDenied', tool_name = 'Bash' }).detail,
  'denied Bash', 'a denial names the tool that was refused')
H.eq(claude.read({ hook_event_name = 'Elicitation', message = 'Pick a region' }).detail,
  'Pick a region', 'an elicitation shows what the MCP server actually asked')

local started = claude.read({
  hook_event_name = 'SubagentStart',
  session_id = 'parent-1', agent_id = 'a045c6a6a98c0ea17', agent_type = 'Explore',
})
H.eq(started.sub.id, 'a045c6a6a98c0ea17', 'a sub-agent is identified by agent_id')
H.eq(started.sub.type, 'Explore',
  'and named by agent_type, which a real run confirmed is the FRIENDLY name, so the '
  .. 'drawer can say Explore rather than claude')
H.eq(claude.read({ hook_event_name = 'Stop', session_id = 'parent-1' }).sub, nil,
  'while the top-level agent has no agent_id at all')

local live = claude.read({
  hook_event_name = 'Stop',
  session_id = 'parent-1',
  background_tasks = {
    { id = 'a045c6a6a98c0ea17', type = 'subagent', status = 'running' },
    { id = 'cron-1', type = 'monitor', status = 'running' },
  },
})
H.eq(#live.children, 1, 'every Stop carries a SNAPSHOT of the live children')
H.eq(live.children[1], 'a045c6a6a98c0ea17', 'naming only the subagents among them')
H.eq(claude.read({ hook_event_name = 'SubagentStop' }).subagent_event, true,
  'a Subagent event is FLAGGED as one even when its id is missing, so a payload dropped '
  .. 'for size cannot make SubagentStop look like the whole session ending and delete '
  .. 'the parent along with every child')
H.eq(claude.read({ hook_event_name = 'Stop' }).subagent_event, nil, 'while Stop is not one')
H.eq(claude.read({ hook_event_name = 'SubagentStop', agent_id = 'x' }).children, nil,
  'and only Stop is treated as a snapshot: at SubagentStop the list still shows the '
  .. 'agent that just stopped, so reconciling there would keep a dead child forever')

H.eq(agents.receive('nonsense'), '', 'a non-table delivery is refused and still returns cleanly')
agents.receive({ v = 2, term = '999', state = 'blocked', detail = 'x', name = '' })
H.drain()
H.eq(agents.state(999), nil, 'an envelope with an unknown version is ignored whole')
agents.receive({ v = 1, state = 'blocked', detail = 'x', name = '' })
H.drain()
H.eq(agents.state(999), nil, 'and so is one with no terminal to attribute')

local faults_before = #agents.log_lines()
agents.receive({ v = 1, term = '998', state = 'working', detail = 'from the argument',
  name = '', fault = 'payload of 9999999 bytes is over the cap' })
H.drain()
H.contains(table.concat(agents.log_lines(), '\n'), 'hook fault term=998',
  'a transport fault is logged with its reason, never silent')
H.ok(#agents.log_lines() > faults_before, 'as a new log line')

local notification_entry = settings.hooks.Notification[1]
H.eq(notification_entry.hooks[1].async, true,
  'hooks are async, so a wedged session can never stall the agent waiting on --remote-expr')
H.ok(notification_entry.hooks[1].timeout ~= nil, 'and bounded by a timeout')

local command = matchers.permission_prompt or ''
H.contains(command, '${MUXIM_HOOK:-',
  'the command resolves the hook through the variable muxim exports into its terminals')
local real_home = vim.env.HOME
vim.env.HOME = vim.fn.fnamemodify(agents.hook_path(), ':h:h:h:h')
H.contains(agents.hook_command_path(), '$HOME/',
  'a hook under $HOME is written $HOME-relative and UNEXPANDED, so one install works '
  .. 'on every machine that syncs the settings file')
H.ok(agents.hook_command_path():find(vim.env.HOME, 1, true) == nil,
  'with the current machine\'s home written nowhere in it')
vim.env.HOME = '/nowhere-near-the-data-dir'
H.eq(agents.hook_command_path(), agents.hook_path(),
  'and a hook outside $HOME stays absolute rather than pretending to be portable')
vim.env.HOME = real_home
H.contains(command, "'claude'", 'and it names the agent, so the drawer stops saying zsh')

local matcher_names = {}
for _, entry in ipairs(settings.hooks.SessionStart or {}) do
  matcher_names[#matcher_names + 1] = entry.matcher
end
H.eq(matcher_names[1], 'startup|resume|fork',
  'SessionStart is matched, so an auto-compaction cannot mark a working agent idle')
local end_matchers = {}
for _, entry in ipairs(settings.hooks.SessionEnd or {}) do
  if claude.is_ours(entry) then end_matchers[#end_matchers + 1] = entry.matcher end
end
H.eq(end_matchers[1], 'logout|prompt_input_exit|other',
  'and SessionEnd is matched, so /clear does not make muxim forget a live agent')
local function our_command(event)
  for _, entry in ipairs(settings.hooks[event] or {}) do
    if claude.is_ours(entry) then return entry.hooks[1].command end
  end
  return ''
end
H.contains(our_command('Stop'), "'idle'",
  'Stop ends the WORKING state, because it fires when an assistant turn ends and '
  .. 'nothing else does: without it a report of "working" stands until the 60s idle '
  .. 'notification or the session ends, which is what Jon saw')
H.contains(our_command('SessionStart'), "'idle'",
  'SessionStart reports idle, so a freshly started agent is visible before it does anything')
H.contains(our_command('SessionEnd'), "'ended'",
  'and SessionEnd removes it rather than leaving it listed forever')

local foreign = 0
for _, entry in ipairs(settings.hooks.SessionEnd) do
  if not claude.is_ours(entry) then foreign = foreign + 1 end
end
H.eq(foreign, 1, "somebody else's hook on the same event is left alone")

claude.install()
local twice = read_settings()
local ours = 0
for _, entry in ipairs(twice.hooks.SessionEnd) do
  if claude.is_ours(entry) then ours = ours + 1 end
end
H.eq(ours, 1, 'installing twice leaves one entry, not two')

H.ok(vim.uv.fs_stat(agents.hook_path()) ~= nil, 'the hook script is written')
H.eq(bit.band(vim.uv.fs_stat(agents.hook_path()).mode, tonumber('777', 8)), tonumber('700', 8),
  'executable and private')
local script = table.concat(vim.fn.readfile(agents.hook_path()), '\n')
H.contains(script, 'MUXIM_SERVER', 'and reports through the session socket')
H.ok(script:find(vim.v.progpath, 1, true) == nil,
  'with no hardcoded nvim path, so moving nvim cannot stale it')
H.contains(script, '"${MUXIM_NVIM:-nvim}"',
  'the client runs through MUXIM_NVIM, which inside a muxim terminal is always the real '
  .. 'binary rather than whatever PATH resolves')

vim.cmd('tabonly')
vim.cmd('only')
local buf = terminal.open_in_tab(
  'sh -c "echo TERM_ID=$MUXIM_TERM; echo NVIM_AT=$MUXIM_NVIM; echo SERVER=$MUXIM_SERVER; sleep 300"')
H.ok(vim.wait(3000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find('TERM_ID=', 1, true) ~= nil
end, 50), 'the terminal ran')
local output = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
H.contains(output, 'TERM_ID=' .. buf, 'a managed terminal carries its own id in the environment')
H.contains(output, 'NVIM_AT=' .. vim.v.progpath, 'and the nvim the hook should talk to')
H.contains(output, 'SERVER=' .. require('muxim.server').self_path,
  'and the socket of the session that OWNS it, not whatever it inherited')

local server = require('muxim.server')
H.ok(server.self_path ~= nil, 'this session owns a socket for the hook to talk to')
local hook_code
vim.system({ '/bin/sh', agents.hook_path(), 'blocked', 'input needed' }, {
  text = true,
  stdin = '{"hook_event_name":"Notification"}',
  env = { MUXIM_SERVER = server.self_path, MUXIM_TERM = tostring(buf), MUXIM_NVIM = vim.v.progpath },
}, function(out) hook_code = out.code end)
H.ok(vim.wait(5000, function() return hook_code ~= nil end, 50), 'the hook script finishes')
H.eq(hook_code, 0, 'exiting 0, so it can never block the agent')
H.ok(vim.wait(3000, function() return agents.state(buf) ~= nil end, 50),
  'the hook reported into this session over RPC')
H.eq(agents.state(buf).state, 'blocked', 'with the state it was given')
H.eq(agents.state(buf).detail, 'input needed', 'and the detail, spaces intact')

agents.clear(buf)
local nasty = 'it said "done" and then \'quit\'\nsecond line'
local payload_code
vim.system({ '/bin/sh', agents.hook_path(), 'idle', 'waiting for you', 'claude' }, {
  text = true,
  stdin = vim.json.encode({
    hook_event_name = 'Stop',
    session_id = 'session-abc',
    last_assistant_message = nasty,
  }),
  env = { MUXIM_SERVER = server.self_path, MUXIM_TERM = tostring(buf), MUXIM_NVIM = vim.v.progpath },
}, function(out) payload_code = out.code end)
H.ok(vim.wait(5000, function() return payload_code ~= nil end, 50), 'the hook with a payload finishes')
H.ok(vim.wait(3000, function() return agents.state(buf) ~= nil end, 50), 'and reports')
H.eq(agents.state(buf).detail, 'it said "done" and then \'quit\' second line',
  'the DETAIL is what the agent actually said, with both quote characters and a newline '
  .. 'in it, carried as a structured msgpack value end to end: no shell quoting layer '
  .. 'ever touches it')
H.eq(agents.state(buf).session, 'session-abc',
  'and the session id comes from the payload as a FIELD, not from a regex over the JSON')

agents.clear(buf)
local big_code
vim.system({ '/bin/sh', agents.hook_path(), 'working', 'from the argument', 'claude' }, {
  text = true,
  stdin = vim.json.encode({
    hook_event_name = 'Stop',
    last_assistant_message = string.rep('x', agents.PAYLOAD_MAX + 1),
  }),
  env = { MUXIM_SERVER = server.self_path, MUXIM_TERM = tostring(buf), MUXIM_NVIM = vim.v.progpath },
}, function(out) big_code = out.code end)
H.ok(vim.wait(5000, function() return big_code ~= nil end, 50), 'a payload too big to pass finishes')
H.ok(vim.wait(3000, function() return agents.state(buf) ~= nil end, 50),
  'and still reports, because the STATE is an argument and never depended on the payload')
H.eq(agents.state(buf).detail, 'from the argument',
  'falling back to the detail it was given rather than sending a truncated JSON that '
  .. 'would decode as garbage')
H.contains(table.concat(agents.log_lines(), '\n'), 'is over the ' .. agents.PAYLOAD_MAX,
  'and the drop is LOGGED with its size. The old sh transport dropped it silently, and '
  .. 'its base64 expansion could exceed Linux MAX_ARG_STRLEN and lose the whole event; '
  .. 'msgpack over the socket has no argument-length cliff, so the cap is only a '
  .. 'sanity bound')

agents.clear(buf)
local garbage_code
vim.system({ '/bin/sh', agents.hook_path(), 'working', 'still told', 'claude' }, {
  text = true,
  stdin = 'not json at all',
  env = { MUXIM_SERVER = server.self_path, MUXIM_TERM = tostring(buf), MUXIM_NVIM = vim.v.progpath },
}, function(out) garbage_code = out.code end)
H.ok(vim.wait(5000, function() return garbage_code ~= nil end, 50), 'a garbage payload finishes')
H.ok(vim.wait(3000, function() return agents.state(buf) ~= nil end, 50), 'and still reports')
H.eq(agents.state(buf).detail, 'still told', 'from its arguments')
H.contains(table.concat(agents.log_lines(), '\n'), 'unparseable payload',
  'and the parse failure is logged, never swallowed')

agents.clear(buf)
local deep = { hook_event_name = 'Stop', session_id = 'deep-1', last_assistant_message = 'the flat fields survive' }
local node = deep
for _ = 1, 30 do
  node.tool_input = {}
  node = node.tool_input
end
local deep_code
vim.system({ '/bin/sh', agents.hook_path(), 'idle', 'waiting for you', 'claude' }, {
  text = true,
  stdin = vim.json.encode(deep),
  env = { MUXIM_SERVER = server.self_path, MUXIM_TERM = tostring(buf), MUXIM_NVIM = vim.v.progpath },
}, function(out) deep_code = out.code end)
H.ok(vim.wait(5000, function() return deep_code ~= nil end, 50), 'a deeply nested payload finishes')
H.ok(vim.wait(3000, function() return agents.state(buf) ~= nil end, 50),
  'and reports rather than dying in the server msgpack unpacker, which aborts the whole '
  .. 'channel around 28 levels')
H.eq(agents.state(buf).session, 'deep-1',
  'keeping the flat fields: session and detail come through, only the nested tables are shed')
H.eq(agents.state(buf).detail, 'the flat fields survive', 'detail included')
H.contains(table.concat(agents.log_lines(), '\n'), 'nested past',
  'and the shedding is logged')

agents.clear(buf)
local broken_code
vim.system({ '/bin/sh', agents.hook_path(), 'blocked', 'x', 'claude' }, {
  text = true,
  stdin = '{}',
  env = { MUXIM_SERVER = server.self_path, MUXIM_TERM = tostring(buf), MUXIM_NVIM = '/nonexistent/nvim' },
}, function(out) broken_code = out.code end)
H.ok(vim.wait(5000, function() return broken_code ~= nil end, 50), 'a broken MUXIM_NVIM finishes')
H.eq(broken_code, 0, 'exiting 0, so Claude Code never sees a failing hook even with no client to run')
H.contains(table.concat(vim.fn.readfile(vim.fn.fnamemodify(server.self_path, ':h') .. '/agents.log'), '\n'),
  'client failed',
  'and the guard logs the failure itself, since the client never ran to log anything')

agents.clear(buf)
agents.receive({ v = 1, term = tostring(buf), state = 'blocked', detail = 'guarding',
  name = 'claude', payload = { hook_event_name = 'PermissionRequest', session_id = 'parent-9' } })
H.drain()
H.eq(agents.state(buf).state, 'blocked', 'a parent is reported')
agents.receive({ v = 1, term = tostring(buf), state = 'ended', detail = '',
  name = 'claude', payload = { hook_event_name = 'SubagentStop' } })
H.drain()
H.eq(agents.state(buf) and agents.state(buf).state, 'blocked',
  'a SubagentStop whose id was shed cannot end the parent: the flag alone stops it')
H.contains(table.concat(agents.log_lines(), '\n'), 'cannot say WHICH child',
  'and the refusal is logged')

agents.clear(buf)
agents.receive({ v = 1, term = tostring(buf), state = 'working', detail = '',
  name = 'claude', payload = { hook_event_name = 'UserPromptSubmit', session_id = vim.NIL } })
H.drain()
H.eq(agents.state(buf).state, 'working', 'a JSON null session id still reports')
H.eq(agents.state(buf).session, nil,
  'as the terminal itself, never under the literal string vim.NIL')
agents.clear(buf)

agents.clear(buf)
local shell_buf = terminal.open_in_tab()
vim.wait(500)
terminal.send(shell_buf, agents.hook_path() .. " done ''")
H.ok(vim.wait(5000, function() return agents.state(shell_buf) ~= nil end, 50),
  'the hook typed at a real shell prompt reports instead of hanging on its tty')
H.eq(agents.state(shell_buf).state, 'done', 'with the state it was given there')
vim.api.nvim_buf_delete(shell_buf, { force = true })

agents.clear(buf)
local bare_code
vim.system({ '/bin/sh', agents.hook_path(), 'blocked', '' }, { text = true, stdin = '{}' },
  function(out) bare_code = out.code end)
H.ok(vim.wait(5000, function() return bare_code ~= nil end, 50),
  'a hook outside a muxim terminal finishes')
H.eq(bare_code, 0, 'exiting 0 as well')
H.eq(agents.state(buf), nil, 'and reports nothing, because it has nowhere to report')

local partial = read_settings()
for i, entry in ipairs(partial.hooks.Notification) do
  if entry.matcher == 'agent_completed' then table.remove(partial.hooks.Notification, i) end
end
write_settings(vim.json.encode(partial))
H.eq(claude.installed(), false,
  'deleting one matcher by hand is not "installed": a half install would silently never report done')
claude.install()
H.eq(claude.installed(), true, 'and installing again repairs it')

write_settings('')
H.ok(claude.read_settings() ~= nil, 'an empty settings file parses rather than reading as corruption')
H.eq(vim.tbl_isempty(claude.read_settings()), true, 'as an empty table')
local ok_empty = claude.install()
H.eq(ok_empty, true, 'so install works on a settings file that is empty, which is a common state')
H.eq(claude.installed(), true, 'and the hooks land in it')

H.eq(claude.uninstall(), true, 'uninstall succeeds')
local after = read_settings()
H.eq(claude.installed(), false, 'and installed() says so')
H.eq(after.hooks, nil, 'and every hook of ours is gone from it')
H.ok(vim.uv.fs_stat(agents.hook_path()) ~= nil,
  'the hook script STAYS: it is muxim\'s own, the plugin directory references it too, '
  .. 'and setup() would rewrite it on the next start anyway')

local real_home_install = vim.env.HOME
vim.env.HOME = vim.fn.fnamemodify(agents.hook_path(), ':h:h:h:h')
claude.install()
local portable = read_settings().hooks.SessionStart[1].hooks[1].command
vim.env.HOME = real_home_install
H.contains(portable, '${MUXIM_HOOK:-$HOME/',
  'the command WRITTEN TO DISK carries $HOME unexpanded, which is the whole fix: '
  .. 'a settings file shared between two machines has to resolve on both')
H.ok(portable:find(vim.fn.fnamemodify(agents.hook_path(), ':h:h:h:h'), 1, true) == nil,
  'and no machine-local absolute path survives in it')

local only_hooks = H.runtime_dir() .. '/claude-hooks-only'
vim.fn.mkdir(only_hooks, 'p', tonumber('700', 8))
local hooks_only_file = io.open(only_hooks .. '/settings.json', 'w')
hooks_only_file:write('{"hooks":{}}')
hooks_only_file:close()
claude.install(only_hooks)
claude.uninstall(only_hooks)
local emptied = io.open(only_hooks .. '/settings.json', 'r')
local emptied_body = vim.trim(emptied:read('*a'))
emptied:close()
H.eq(emptied_body, '{}',
  'uninstalling the last hook leaves a JSON OBJECT, not the array [] that an empty '
  .. 'Lua table encodes to, which Claude Code would refuse to read')

local link_dir = H.runtime_dir() .. '/claude-linked'
vim.fn.mkdir(link_dir, 'p', tonumber('700', 8))
vim.uv.fs_symlink(claude.settings_path(), link_dir .. '/settings.json')
claude.install(link_dir)
local link_stat = vim.uv.fs_lstat(link_dir .. '/settings.json')
H.eq(link_stat and link_stat.type, 'link',
  'a settings.json that is a symlink into a dotfiles repo stays a symlink, '
  .. 'because that is exactly how a shared settings file gets shared')

H.eq(claude.is_ours({ hooks = { { type = 'command', command = 'echo muxim/agent-hook' } } }), false,
  'a hook that merely MENTIONS the path is not ours, so install cannot eat it')

H.eq(agents.shell_init_is_current(), true, 'setup() writes a shell init file muxim owns')
local init_body = table.concat(vim.fn.readfile(agents.shell_init_path()), '\n')
H.contains(init_body, 'command claude --plugin-dir "$MUXIM_CLAUDE_PLUGIN"',
  'defining a passthrough wrapper, so an agent TYPED at a prompt is covered by one '
  .. 'line in a shell rc instead of an entry in the user\'s Claude settings')
H.ok(init_body:find(vim.env.HOME or '/home', 1, true) == nil,
  'with no machine-local path in it, so the same file works on both machines')
local init_probe = vim.system({ 'sh', '-n', agents.shell_init_path() }, { text = true }):wait()
H.eq(init_probe.code, 0, 'and it is POSIX sh, so bash and zsh can both source it')

local argv_probe = H.runtime_dir() .. '/argv-probe.sh'
vim.fn.writefile({
  'command() {',
  '  if [ "$1" = "claude" ]; then shift; for a in "$@"; do printf "%s|" "$a"; done',
  '  else builtin command "$@"; fi',
  '}',
  '. "$MUXIM_SHELL_INIT"',
  'claude -p "two words"',
}, argv_probe)
local wrong = {}
for _, shell in ipairs({ 'sh', 'bash', 'zsh' }) do
  if vim.fn.executable(shell) == 1 then
    local run = vim.system({ shell, argv_probe }, { text = true, env = {
      MUXIM_SHELL_INIT = agents.shell_init_path(),
      MUXIM_CLAUDE_PLUGIN = '/some/dir',
      PATH = vim.env.PATH,
    } }):wait()
    if vim.trim(run.stdout or '') ~= '--plugin-dir|/some/dir|-p|two words|' then
      wrong[#wrong + 1] = shell .. ': ' .. vim.trim(run.stdout or '')
    end
  end
end
H.eq(table.concat(wrong, ' '), '',
  'the wrapper passes SEPARATE arguments in every shell. zsh does not word-split an '
  .. 'unquoted expansion, so ${VAR:+--plugin-dir "$VAR"} arrives as ONE argument and '
  .. 'claude dies with "unknown option". A stub using "$*" cannot see that: this '
  .. 'probe prints real argv')

local plugin = claude.plugin_dir()
H.eq(claude.plugin_is_current(), true, 'setup() writes a Claude plugin directory muxim owns')
H.ok(vim.uv.fs_stat(plugin .. '/.claude-plugin/plugin.json') ~= nil, 'with a manifest')
local plugin_hooks = vim.json.decode(
  table.concat(vim.fn.readfile(plugin .. '/hooks/hooks.json'), '\n'))
H.eq(plugin_hooks.hooks.Notification[1].matcher, 'permission_prompt',
  'carrying the same events as the settings install')
H.eq(plugin_hooks.hooks.Notification[1].hooks[1].command,
  read_settings().hooks.Notification[1].hooks[1].command,
  'and the identical command, because both channels are built from one place')
local plugin_body = table.concat(vim.fn.readfile(plugin .. '/hooks/hooks.json'), '\n')
local order = {}
for key in plugin_body:gmatch('"(%u%a+)"%s*:') do
  if key:match('^%u') and #key > 6 then order[#order + 1] = key end
end
local sorted = vim.deepcopy(order)
table.sort(sorted)
H.eq(table.concat(order, ','), table.concat(sorted, ','),
  'the plugin JSON is written with sorted keys, so two machines and two nvim '
  .. 'processes produce the SAME bytes: vim.json.encode does not promise key order, '
  .. 'and an unstable body would mean rewriting the file on every single startup')

H.contains(table.concat(claude.launch_argv({ '-p', 'hi' }), ' '), '--plugin-dir ' .. plugin,
  'launching an agent through muxim passes that directory, so nothing outside muxim '
  .. 'is written or needed at all')
local plugin_file = io.open(plugin .. '/hooks/hooks.json', 'a')
plugin_file:write('\n')
plugin_file:close()
H.eq(claude.plugin_is_current(), false, 'a plugin that drifted from the code is detected')
agents.setup({})
H.eq(claude.plugin_is_current(), true, 'and rewritten by the next setup()')

os.remove(agents.hook_path())
H.eq(vim.uv.fs_stat(agents.hook_path()), nil, 'with no hook script on this machine at all')
agents.setup({})
H.ok(vim.uv.fs_stat(agents.hook_path()) ~= nil,
  'setup() writes it, so a settings file synced from another machine finds a hook '
  .. 'here without anyone running :MuximAgentSetup again')
H.eq(agents.hook_is_current(), true, 'and it is the current one')

local drifted = io.open(agents.hook_path(), 'a')
drifted:write('# written by an older muxim\n')
drifted:close()
H.eq(agents.hook_is_current(), false, 'a script that drifted from the code')
agents.setup({})
H.eq(agents.hook_is_current(), true, 'is rewritten by the next setup(), so it cannot go stale')

local malformed = H.runtime_dir() .. '/claude-malformed'
vim.fn.mkdir(malformed, 'p', tonumber('700', 8))
local malformed_file = io.open(malformed .. '/settings.json', 'w')
malformed_file:write('{"hooks":{"Notification":[null,12]}}')
malformed_file:close()
local reads_ok, reads = pcall(claude.installed, malformed)
H.eq(reads_ok, true, 'a stray null in a hooks array does not throw out of installed()')
H.eq(reads, false, 'it simply reads as not installed, so checkhealth still runs')

local extra = H.runtime_dir() .. '/claude-extra-account'
vim.fn.mkdir(extra, 'p', tonumber('700', 8))
agents.setup({ claude = { config_dirs = { extra } } })
local known = claude.config_dirs()
H.eq(#known, 2, 'a second account is a config dir muxim knows about')
H.eq(known[2], extra, 'and it is the one that was configured')
agents.setup({ claude = { config_dirs = {} } })

local second = H.runtime_dir() .. '/claude-second-account'
vim.fn.mkdir(second, 'p', tonumber('700', 8))
claude.install()
claude.install(second)
claude.uninstall(second)
H.ok(vim.uv.fs_stat(agents.hook_path()) ~= nil,
  'uninstalling one account leaves the hook script alone')
H.eq(claude.installed(), true, 'and the other account is still installed')

local elsewhere = ('{"hooks":{"SessionStart":[{"matcher":"startup|resume|fork","hooks":[{"type":"command",'
  .. '"command":"\'/Users/someone-else/.local/share/nvim/muxim/agent-hook\' idle \'\' claude"}]}]}}')
write_settings(elsewhere)
local foreign_entry = read_settings().hooks.SessionStart[1]
H.eq(claude.is_ours(foreign_entry), true,
  'an entry written by muxim on ANOTHER machine is still recognised as ours, '
  .. 'because identity is a stable marker and not an absolute path')
H.eq(claude.installed(), false, 'it does not count as installed here')
H.eq(#claude.stale_entries(), 1, 'and checkhealth can name it as pointing nowhere on this machine')
claude.install()
local replaced = read_settings()
H.eq(#replaced.hooks.SessionStart, 1,
  'installing replaces it instead of piling a second set beside it')
H.ok(replaced.hooks.SessionStart[1].hooks[1].command:find('/Users/someone-else', 1, true) == nil,
  'and the dead path is gone')
H.eq(#claude.stale_entries(), 0, 'with nothing stale left to report')

local script_file = io.open(agents.hook_path(), 'a')
script_file:write('# written by an older muxim\n')
script_file:close()
H.eq(agents.hook_is_current(), false, 'a hook script that drifted from the code is detected')
H.eq(claude.installed(), false, 'and that alone means "not installed", so an upgrade self-heals')
claude.install()
H.eq(agents.hook_is_current(), true, 'installing rewrites it')
H.eq(claude.installed(), true, 'and everything agrees again')

local settings_target = claude.settings_path()
vim.uv.fs_chmod(settings_target, tonumber('600', 8))
claude.install()
H.eq(bit.band(vim.uv.fs_stat(settings_target).mode, tonumber('777', 8)), tonumber('600', 8),
  'a private settings file stays private: the rewrite carries its mode across')

write_settings('{ this is not json }')
local refused, why = claude.install()
H.eq(refused, false, 'install refuses to touch a settings file it cannot parse')
H.contains(why, 'not valid JSON', 'and says why')
H.eq(table.concat(vim.fn.readfile(claude.settings_path()), '\n'), '{ this is not json }',
  'leaving the file exactly as it found it')

vim.api.nvim_buf_delete(buf, { force = true })
H.finish('agent_hooks_spec')
