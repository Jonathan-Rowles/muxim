local H = dofile('tests/helper.lua')
local agents = require('muxim.agents')
local server = require('muxim.server')
local runtime = require('muxim.runtime')

local path = runtime.socket('fleet-agent')
H.ok(H.spawn_server(path, '.'), 'a second session is running')

local remote_buf = server.remote_expr(path,
  "v:lua.require'muxim.terminal'.open_in_tab('sleep 300')", 5000)
H.ok(tonumber(remote_buf) ~= nil, 'it opened a terminal of its own: ' .. tostring(remote_buf))

server.remote_expr(path,
  ("v:lua.require'muxim.agents'.receive({'v':1,'term':'%s','state':'blocked','detail':'permission prompt'})"):format(remote_buf), 5000)
H.ok(vim.wait(3000, function()
  return agents.published(path).agents[1] ~= nil
end, 100), 'and recorded a blocked agent, published where any session can read it')

H.eq(#agents.tracked(), 0, 'this session has no agents of its own')

local notified
local real_notify = vim.notify
vim.notify = function(msg) notified = msg end
H.eq(agents.focus_blocked(), false, 'focus_blocked has nowhere local to go')
H.contains(notified or '', 'blocked in fleet-agent',
  'but it names the session whose agent is blocked, because the bare '
  .. '"no agent is blocked" is a lie when the fleet has one waiting')
H.contains(notified or '', 'w switches sessions', 'and points at the session picker')
vim.notify = real_notify


local fleet
agents.fleet_view(function(sessions) fleet = sessions end)
H.ok(vim.wait(5000, function() return fleet ~= nil end, 50), 'the fleet view resolves')
local other = vim.tbl_filter(function(s) return s.path == path end, fleet)[1]
H.ok(other ~= nil, 'it sees the other session across processes')
H.eq(other.agents[1].state, 'blocked', 'with its agent state')
H.eq(other.agents[1].detail, 'permission prompt', 'and its detail')

local drawer = require('muxim.drawer')
drawer.open()
local function drawn()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
end
H.ok(vim.wait(5000, function() return drawn():find('permission prompt', 1, true) ~= nil end, 50),
  'and the drawer shows it, read from that session\'s state file')
H.contains(drawn(), runtime.display_name(path), 'labelled with the session it lives in')

local connected
local real_connect = server.connect
server.connect = function(target) connected = target return true end
local asked = false
local real_confirm = vim.fn.confirm
vim.fn.confirm = function() asked = true return 2 end

for line = 1, vim.api.nvim_buf_line_count(0) do
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  if table.concat(vim.api.nvim_buf_get_lines(0, line - 1, line, false)):find('permission prompt') then break end
end
drawer.select()
H.eq(connected, path, 'selecting it goes straight to that session')
H.eq(asked, false, 'without asking again: choosing the row WAS the choice')
vim.fn.confirm = real_confirm
drawer.close()

server.connect = real_connect

local sources = require('muxim.sources')
H.ok(vim.wait(3000, function()
  return agents.published(path).cwd ~= nil
end, 100), 'a session publishes its own cwd')
local remote_session
for _, entry in ipairs(sources.sessions({})) do
  if entry.path == path then remote_session = entry end
end
H.ok(remote_session ~= nil, 'the sessions source lists it')
H.eq(remote_session.dir, agents.published(path).cwd,
  'carrying the directory it was started in, read from its published state')

H.ok(vim.wait(3000, function()
  return #agents.published(path).tabs > 0
end, 100), 'and publishes its tabs')
local fleet_windows = sources.windows()
local remote_session, remote_window
for _, entry in ipairs(fleet_windows) do
  if entry.path == path and entry.kind == 'session' then remote_session = entry end
  if entry.path == path and entry.kind == 'window' and entry.state == 'blocked' then
    remote_window = entry
  end
end
H.ok(remote_session ~= nil, 'the other session gets its own row')
H.ok(remote_window ~= nil, 'with its windows underneath, across processes')
H.eq(remote_window.session, runtime.display_name(path), 'a window knows its session')
H.eq(fleet_windows[1].current, true, 'the session you are attached to comes first')

local previewed, previewed_ft
require('muxim.session').tab_lines_async(remote_window, function(lines, ft)
  previewed, previewed_ft = lines, ft
end)
H.ok(vim.wait(5000, function() return previewed ~= nil end, 50),
  'a window in another session previews its real buffer, fetched from that session')
H.ok(#previewed > 0, 'with content')
H.eq(previewed_ft, '', 'and the filetype that session reports for it')

server.connect = function(target) connected = target return true end
require('muxim.actions').select_window(remote_window)
server.connect = real_connect
H.eq(connected, path, 'choosing it connects to that session')
H.eq(server.remote_expr(path, 'tabpagenr()'), tostring(remote_window.index),
  'after telling that session which tab to show')

local missing = agents.published(H.runtime_dir() .. '/muxim/never-published.sock')
H.eq(type(missing.tabs), 'table', 'a session that has published nothing still reports a tabs table')
H.eq(type(missing.agents), 'table', 'and an agents table')
H.eq(type(missing.terminals), 'table', 'and a terminals table')

local state_file = agents.state_file(path)
local corrupt = io.open(state_file, 'w')
corrupt:write('{ not json')
corrupt:close()
H.eq(type(agents.published(path).tabs), 'table', 'so does one whose state file is corrupt')
H.ok(pcall(sources.windows), 'and the fleet window picker survives it')

os.remove(state_file)
H.ok(pcall(sources.windows),
  'a session listed before it has ever published does not break the window picker: '
  .. 'the socket is claimed at serverstart, the state file is written later')
local still_there = false
for _, entry in ipairs(sources.windows()) do
  if entry.path == path and entry.kind == 'session' then still_there = true end
end
H.ok(still_there, 'and it is still listed, just with no windows under it yet')

local fleet_notices = {}
local real_notify_opt = agents.notify
agents.notify = function(entry) fleet_notices[#fleet_notices + 1] = entry end
agents.unwatch_fleet()
H.eq(agents.watching_fleet(), false, 'not watching the fleet to begin with')
agents.watch_fleet()
H.eq(agents.watching_fleet(), true,
  'and watching afterwards, which checkhealth reports so a session that is NOT watching '
  .. 'is visible rather than merely quiet')
H.eq(#fleet_notices, 0,
  'starting to watch the fleet notifies about NOTHING, even though an agent is already '
  .. 'blocked out there. Otherwise every session you open shouts about every agent that '
  .. 'was already waiting')

local fleet_events = {}
vim.api.nvim_create_autocmd('User', {
  group = vim.api.nvim_create_augroup('fleet_spec_events', { clear = true }),
  pattern = 'MuximAgentState',
  callback = function(args)
    if args.data and args.data.here == false then
      fleet_events[#fleet_events + 1] = args.data
    end
  end,
})

server.remote_expr(path,
  ("v:lua.require'muxim.agents'.receive({'v':1,'term':'%s','state':'working','detail':''})"):format(remote_buf), 5000)
H.ok(vim.wait(5000, function()
  local first = agents.published(path).agents[1]
  return first and first.state == 'working'
end, 100), 'the remote agent goes back to work')
H.ok(vim.wait(8000, function()
  for _, event in ipairs(fleet_events) do
    if event.state == 'working' then return true end
  end
end, 100),
  'EVERY remote transition fires MuximAgentState here, not only blocked, so the drawer '
  .. 'and tabline follow remote agents through working and idle the way they follow local ones')
H.eq(#fleet_notices, 0, 'while working is not something you can act on, so no notification')

server.remote_expr(path,
  ("v:lua.require'muxim.agents'.receive({'v':1,'term':'%s','state':'blocked','detail':'wants to use Bash','name':'claude'})"):format(remote_buf),
  5000)
H.ok(vim.wait(8000, function() return #fleet_notices > 0 end, 100),
  'an agent blocking in ANOTHER session notifies here, driven by the watcher rather than '
  .. 'by the spec polling, which is the whole point: '
  .. 'the session that owns the terminal is not the session you are looking at')
H.eq(fleet_notices[1].here, false, 'the entry says it is not local')
H.eq(fleet_notices[1].buf, nil,
  'and carries NO buf, because there is no buffer here to jump to. The event data says '
  .. 'here=false for the same reason, so a handler can tell the two apart')
H.eq(fleet_notices[1].session, runtime.display_name(path), 'and names the session it is in')
H.eq(fleet_notices[1].detail, 'wants to use Bash', 'carrying the reason across the fleet')

local before = #fleet_notices
agents.fleet_check()
agents.fleet_check()
H.eq(#fleet_notices, before,
  'and it stays notified ONCE: the same edge rule as a local agent, applied per session '
  .. 'and per agent id, so a state file rewritten for any reason cannot re-announce a '
  .. 'wait you already know about')

local published_raw = table.concat(vim.fn.readfile(state_file), '\n')
local function republish()
  local rewrite = io.open(state_file, 'w')
  rewrite:write(published_raw)
  rewrite:close()
end
os.remove(state_file)
agents.fleet_check()
republish()
agents.fleet_check()
H.eq(#fleet_notices, before,
  'a state file MISSING for one pass (a reload unpublishing then republishing) does '
  .. 'not re-announce the same wait when it returns')

local garbled = io.open(state_file, 'w')
garbled:write('{ not json')
garbled:close()
agents.fleet_check()
republish()
agents.fleet_check()
H.eq(#fleet_notices, before, 'and neither does one UNREADABLE for a pass, mid-write')

local real_list = server.list
server.list = function()
  return vim.tbl_filter(function(s) return s.path ~= path end, real_list())
end
agents.fleet_check()
server.list = real_list
agents.fleet_check()
H.eq(#fleet_notices, before,
  'a session absent from the list for one pass keeps its memory while its socket file '
  .. 'still exists, so a session mid-reload cannot re-announce either')

local incarnation = vim.json.decode(published_raw)
incarnation.pid = (incarnation.pid or 0) + 1
local reborn = io.open(state_file, 'w')
reborn:write(vim.json.encode(incarnation))
reborn:close()
agents.fleet_check()
H.eq(#fleet_notices, before + 1,
  'but a NEW session claiming the same socket path does not inherit the dead one\'s '
  .. 'memory: the state file carries the owning pid, and a different pid means this '
  .. 'still-blocked agent is a genuinely new wait, which announces')
republish()
agents.fleet_check()

H.contains(table.concat(agents.log_lines(), '\n'), 'fleet blocked',
  'and every fleet notification is logged, so "I did not get a notification" is a '
  .. 'question the log can answer rather than a guess')

agents.notify = real_notify_opt
agents.unwatch_fleet()

H.ok(H.kill(path), 'the second session is gone')


H.finish('agents_fleet_spec')
