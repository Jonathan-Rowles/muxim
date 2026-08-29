local H = dofile('tests/helper.lua')
local agents = require('muxim.agents')
local terminal = require('muxim.terminal')

local notified
local real_notify = vim.notify
vim.notify = function(msg) notified = msg end

local desktop
local real_desktop = agents.desktop_notify
agents.desktop_notify = function(_, body) desktop = body end
H.eq(agents.notify_desktop, false, 'desktop notifications are opt-in')
agents.notify_desktop = true

local events = {}
vim.api.nvim_create_autocmd('User', {
  pattern = 'MuximAgentState',
  callback = function(args) events[#events + 1] = args.data end,
})

vim.cmd('tabonly')
vim.cmd('only')
local buf = terminal.open_in_tab('sleep 300')
local agent_tab = vim.api.nvim_get_current_tabpage()
vim.cmd('tabfirst')

H.eq(agents.report(buf, 'nonsense'), false, 'an unknown state is refused')
H.eq(agents.report(vim.api.nvim_get_current_buf(), 'blocked'), false, 'a non-terminal buffer is refused')
H.eq(#agents.tracked(), 0, 'and neither is recorded')

notified = nil
H.eq(agents.report(buf, 'blocked', 'permission prompt'), true, 'a terminal accepts a report')
H.eq(agents.state(buf).state, 'blocked', 'the state is kept')
H.eq(agents.state(buf).detail, 'permission prompt', 'with its detail')
H.eq(notified, nil,
  'a session with no UI stays silent: nobody could read it, and a message it cannot '
  .. 'acknowledge is what strands an exit')

local real_uis = vim.api.nvim_list_uis
vim.api.nvim_list_uis = function() return { {} } end
notified = nil
H.eq(agents.report(buf, 'blocked', 'a different prompt'), true, 'a new report with a UI attached')
H.eq(notified, nil,
  'an agent that is ALREADY blocked and changes its reason stays silent. blocked is a '
  .. 'STATE, not an event: permission_prompt then idle_prompt then the same block again '
  .. 'used to flash three times for one unbroken block, and carrying the real message in '
  .. 'the detail made that worse rather than better')

H.eq(agents.report(buf, 'working'), true, 'the agent goes back to work')
notified = nil
H.eq(agents.report(buf, 'blocked', 'a different prompt'), true, 'and blocks again')
H.contains(notified, 'blocked', 'which DOES notify: it is a new edge, not the same wait')
H.contains(notified, 'a different prompt', 'and says what it wants')
H.eq(desktop, nil, 'a focused nvim sends no desktop notification: you are already looking at it')

notified = nil
agents.focused = false
H.eq(agents.report(buf, 'working'), true, 'back to work once more')
vim.api.nvim_set_current_tabpage(agent_tab)
H.eq(vim.api.nvim_get_current_buf(), buf, 'sitting in the agent terminal itself')
H.eq(agents.report(buf, 'blocked', 'while you are away'), true, 'it blocks while nvim has no focus')
H.contains(notified, 'while you are away',
  'notify = unfocused means the EDITOR is unfocused, not merely that another buffer is '
  .. 'current. Sitting in the agent buffer with nvim in a background window is exactly '
  .. 'when the notification matters, and asking only about the current buffer suppressed it')
H.contains(desktop, 'while you are away',
  'and an unfocused nvim ALSO notifies the desktop: vim.notify lands in a window '
  .. 'you are not looking at, which is the same as silence')

desktop = nil
H.eq(agents.report(buf, 'working'), true, 'working again while still unfocused')
agents.notify_desktop = false
H.eq(agents.report(buf, 'blocked', 'quietly'), true, 'and blocking with notify_desktop = false')
H.contains(notified, 'quietly', 'still notifies inside nvim')
H.eq(desktop, nil, 'but stays off the desktop')
agents.notify_desktop = true

notified, desktop = nil, nil
agents.deliver({ state = 'blocked', name = 'claude', session = 'elsewhere', here = false })
H.contains(notified, 'elsewhere', 'a fleet notice still notifies inside nvim while unfocused')
H.eq(desktop, nil,
  'but never the desktop: every unfocused session sees the same fleet edge, and '
  .. 'three sessions raising three OS notifications for one wait breaks the '
  .. 'one-wait-one-notification promise. The session the agent lives in owns the desktop')
agents.focused = true
vim.cmd('tabfirst')

if vim.fn.has('mac') == 1 then
  local argv = agents.desktop_argv('muxim', 'says "hi" and \\') or {}
  H.eq(argv[1], 'osascript', 'macos delivers through osascript')
  H.contains(argv[3], '\\"hi\\"', 'with quotes escaped into the AppleScript string')
  H.contains(argv[3], '\\\\', 'and backslashes too')
elseif vim.fn.executable('notify-send') == 1 then
  local argv = agents.desktop_argv('muxim', '--urgency=critical is blocked <&>') or {}
  H.eq(argv[1], 'notify-send', 'linux delivers through notify-send')
  H.eq(argv[3], '--',
    'with options terminated first: notify-send parses options anywhere in argv, '
    .. 'so an agent named --urgency=critical would otherwise become one')
  H.contains(argv[5], '&amp;', 'and markup characters escaped for body-markup servers')
  H.contains(argv[5], '&lt;', 'all of them')
end
H.ok(pcall(agents.desktop_argv, nil, nil),
  'a nil title or body never throws: the doc tells custom notify functions to call this')
local flattened = agents.desktop_argv('title\nsplit', 'one\ntwo') or {}
H.ok(not table.concat(flattened, ' '):find('\n'),
  'control characters are flattened: a newline splits an AppleScript string literal '
  .. 'mid-statement and the notification silently dies, and internal callers being '
  .. 'one_line-d does not protect the public entry point')

notified = nil
H.eq(agents.report(buf, 'blocked', 'question one\nquestion two'), true,
  'a detail with a newline is accepted')
H.eq(agents.state(buf).detail, 'question one question two',
  'and flattened at the source, because a newline throws in nvim_buf_set_lines '
  .. 'and would break every drawer rendering it')

H.eq(agents.report(buf, 'blocked', 'permission needed', 'claude'), true, 'a report can name its agent')
H.eq(agents.tracked()[1].name, 'claude', 'and the name is what the drawer shows, not the shell')
H.eq(agents.report(buf, 'ended', '', 'codex'), true, 'another agent in the same terminal ending')
H.eq(agents.state(buf) ~= nil, true, 'does not erase the one that is still there')
H.eq(agents.report(buf, 'ended', '', 'claude'), true, 'and the one that is there can end')
H.eq(agents.state(buf), nil, 'which does remove it')
vim.api.nvim_list_uis = real_uis

notified, events = nil, {}
H.eq(agents.report(buf, 'blocked', 'permission prompt'), true, 'restored for the assertions below')
H.eq(#events, 1, 'a report fires User MuximAgentState')
H.eq(events[1].state, 'blocked', 'carrying the state')

H.eq(#agents.blocked(), 1, 'blocked() finds it')
vim.cmd('tabfirst')
H.ok(vim.api.nvim_get_current_buf() ~= buf, 'sitting somewhere else entirely')
H.eq(agents.focus_blocked(), true, 'focus_blocked goes to it')
H.eq(vim.api.nvim_get_current_buf(), buf,
  'landing in the blocked terminal, in its own tab, without opening the drawer')
notified = nil
H.eq(agents.focus_blocked(), true, 'pressed again while sitting in the only blocked agent')
H.contains(notified or '', 'already at the blocked agent',
  'it says so: a silent self-focus is indistinguishable from a dead key, '
  .. 'which is exactly how it was reported')
H.eq(vim.api.nvim_get_current_buf(), buf, 'and stays put')

H.eq(agents.report(buf, 'blocked', '', 'codex'), true, 'a second agent blocks in the SAME terminal')
local second = require('muxim.terminal').open_in_tab()
H.eq(agents.report(second, 'blocked', '', 'gemini'), true, 'a third blocks in a terminal of its own')
H.eq(agents.focus_blocked(), true, 'cycling from the newest terminal')
H.eq(vim.api.nvim_get_current_buf(), buf, 'reaches the doubly-blocked terminal')
notified = nil
H.eq(agents.focus_blocked(), true, 'cycling on from a terminal holding TWO blocked agents')
H.eq(vim.api.nvim_get_current_buf(), second,
  'skips the entry sharing this buffer and reaches the other terminal: rotating '
  .. 'by entry instead of by buffer got stuck here and claimed "already at" it')
H.eq(notified, nil, 'with no false already-here message')
H.eq(agents.report(second, 'ended', '', 'gemini'), true, 'the extra agents end')
H.eq(agents.report(buf, 'ended', '', 'codex'), true, 'both of them')
H.eq(agents.report(buf, 'blocked', 'permission prompt'), true,
  'and the original blocked report stands again for the assertions below')
vim.cmd('bwipeout! ' .. second)
if #vim.api.nvim_list_tabpages() > 2 then pcall(vim.cmd, 'tabclose') end
vim.cmd('tabfirst')
H.eq(agents.tab_mark(agent_tab), '!', 'the owning tab is marked')
H.eq(agents.tab_mark(vim.api.nvim_get_current_tabpage()), nil, 'other tabs are not')
H.contains(require('muxim.tabline').render(), '!', 'the tabline shows the mark')
local sources = require('muxim.sources')
local windows = sources.windows()
H.eq(windows[1].kind, 'session', 'the window picker leads with the session, tmux-style')
local agent_row
for _, entry in ipairs(windows) do
  if entry.tab == agent_tab then agent_row = entry end
end
H.ok(agent_row ~= nil, 'the blocked tab is a row under it')
H.contains(sources.display(agent_row), '!', 'showing its mark')

notified = nil
vim.api.nvim_set_current_tabpage(agent_tab)
terminal.focus(buf)
agents.report(buf, 'blocked', 'input needed')
H.eq(notified, nil, 'a blocked agent you are already looking at stays quiet')
vim.cmd('tabfirst')

agents.notify = false
notified = nil
agents.report(buf, 'blocked')
H.eq(notified, nil, 'notify = false silences it entirely')
agents.notify = 'unfocused'

agents.report(buf, 'working')
H.eq(agents.tab_mark(agent_tab), '~', 'working marks differently')

local quiet = terminal.open_in_tab('sleep 300')
vim.api.nvim_buf_set_var(quiet, 'muxim_owner_tab', agent_tab)
agents.report(quiet, 'idle')
H.eq(agents.tab_mark(agent_tab), '~',
  'a tab with an idle agent AND a working one is marked for the working one, not left blank')
agents.clear(quiet)
vim.api.nvim_buf_delete(quiet, { force = true })
H.eq(#agents.blocked(), 0, 'and is not blocked')

agents.report(buf, 'blocked', 'permission prompt')
local drawer = require('muxim.drawer')

vim.cmd('tabfirst')
H.eq(drawer.is_open(), false, 'the drawer starts closed')
H.eq(drawer.toggle(), true, 'toggling opens it')
H.eq(vim.bo.filetype, drawer.FILETYPE, 'and leaves you in the drawer')
local function drawn()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
end
H.ok(vim.wait(5000, function() return drawn():find('permission prompt', 1, true) ~= nil end, 50),
  'and fills in without blocking you')
local shown = drawn()
H.contains(shown, 'permission prompt', 'which lists the blocked agent')
H.contains(shown, '!', 'marked as blocked')
H.contains(shown, '* ', 'and marks the session you are in')
H.eq(vim.api.nvim_win_get_width(0), drawer.WIDTH, 'at a fixed width')

local blocked_row
for line = 1, vim.api.nvim_buf_line_count(0) do
  if vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]:find('permission prompt', 1, true) then
    blocked_row = line
  end
end
local marks = vim.api.nvim_buf_get_extmarks(0, drawer.NAMESPACE,
  { blocked_row - 1, 0 }, { blocked_row - 1, -1 }, { details = true })
H.eq(marks[1] and marks[1][4].hl_group, 'MuximAgentBlocked',
  'a blocked row is highlighted as blocked, so the drawer is not one flat colour')
H.ok(vim.api.nvim_get_hl(0, { name = 'MuximAgentBlocked' }).link ~= nil,
  'and the group is a default link a colourscheme can own')

local before = #vim.api.nvim_tabpage_list_wins(0)
agents.report(buf, 'working')
H.ok(vim.wait(5000, function() return drawn():find('~', 1, true) ~= nil end, 50),
  'a report redraws the open drawer, without you asking')
H.eq(#vim.api.nvim_tabpage_list_wins(0), before, 'and does not open a second one')

for line = 1, vim.api.nvim_buf_line_count(0) do
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  if table.concat(vim.api.nvim_buf_get_lines(0, line - 1, line, false)):find('~') then break end
end
drawer.select()
H.eq(vim.api.nvim_get_current_tabpage(), agent_tab, 'selecting an agent goes to its tab')
H.eq(vim.api.nvim_get_current_buf(), buf, 'and into its terminal')

H.eq(drawer.is_open(), false,
  'the drawer is a window, so it stays in the tab you opened it in, like any split')
H.eq(drawer.toggle(), true, 'and opens here when you ask for it here')
H.eq(drawer.toggle(), true, 'toggling again closes it')
H.eq(drawer.is_open(), false, 'so it is a toggle, not a one-way door')

vim.api.nvim_create_autocmd('FileType', {
  pattern = drawer.FILETYPE,
  callback = function(args)
    vim.keymap.set('n', 'q', function() end, { buffer = args.buf, desc = 'the user won' })
  end,
})
vim.api.nvim_buf_delete(drawer.buffer(), { force = true })
drawer.open()
local q_desc
for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, 'n')) do
  if map.lhs == 'q' then q_desc = map.desc end
end
H.eq(q_desc, 'the user won',
  "an ftplugin map wins, because the drawer sets its keymaps BEFORE the filetype "
  .. 'that runs the user code')
drawer.close()

agents.report(buf, 'blocked', 'permission prompt')
vim.api.nvim_set_current_tabpage(agent_tab)
vim.cmd('enew')
vim.cmd('tabfirst')
vim.cmd('only')
H.eq(#vim.fn.win_findbuf(buf), 0, 'the agent terminal is showing in no window at all')
drawer.open()
H.ok(vim.wait(5000, function() return drawn():find('permission prompt', 1, true) ~= nil end, 50),
  'the drawer lists it anyway')
for line = 1, vim.api.nvim_buf_line_count(0) do
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  if vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]:find('permission prompt', 1, true) then
    break
  end
end
drawer.select()
H.eq(vim.api.nvim_get_current_buf(), buf,
  'and selecting it lands in the terminal rather than silently leaving you where you were')

agents.report(buf, 'working')
drawer.close()

H.contains(table.concat(vim.fn.readfile(agents.state_file(require('muxim.server').self_path)), ''),
  'working', 'the session publishes its agents to disk for other sessions to read')

agents.clear(buf)
drawer.open()
H.ok(vim.wait(5000, function() return drawn():find('(no agents)', 1, true) ~= nil end, 50),
  'a session with nothing running is still listed, saying so plainly')
drawer.close()

agents.report(buf, 'blocked')
vim.api.nvim_buf_delete(buf, { force = true })
H.eq(#agents.tracked(), 0, 'a closed terminal drops out of the list')

local ended_buf = terminal.open_in_tab('sleep 300')
vim.cmd('tabfirst')
H.eq(agents.report(ended_buf, 'idle', 'waiting for you'), true, 'an agent that has only just started reports idle')
H.eq(#agents.tracked(), 1, 'so it is visible before it has done anything')
H.eq(agents.report(ended_buf, 'ended'), true, 'and reports when it exits')
H.eq(#agents.tracked(), 0, 'which removes it, rather than leaving a ghost behind')
vim.api.nvim_buf_delete(ended_buf, { force = true })

agents.COMMANDS = { sleep = true }
local found = terminal.open_in_tab('sleep 300')
vim.wait(400)
local fleet
agents.fleet_view(function(sessions) fleet = sessions end)
H.ok(vim.wait(5000, function() return fleet ~= nil end, 50), 'the fleet view resolves')
local mine = vim.tbl_filter(function(s) return s.current end, fleet)[1]
H.ok(mine ~= nil, 'and includes this session')
local running = vim.tbl_filter(function(a) return a.buf == found end, mine.agents)[1]
H.ok(running ~= nil, 'an agent RUNNING in a terminal is listed even though it never reported')
H.eq(running.state, 'running', 'as running')
H.eq(running.name, 'sleep', 'named by the process actually running, not the shell around it')
H.eq(running.detail, 'no state reported yet', 'and honest that no hook has spoken for it')
H.eq(#agents.blocked(), 0, 'discovery never invents a state: it is not blocked')
H.contains(table.concat(vim.fn.readfile(agents.state_file(require('muxim.server').self_path)), ''),
  tostring(vim.b[found].terminal_job_pid),
  'and the session publishes its terminal pids, so other sessions can do the same join')
vim.api.nvim_buf_delete(found, { force = true })
agents.COMMANDS = { claude = true, codex = true, pi = true, opencode = true, aider = true }

local reports = table.concat(agents.log_lines(), '\n')
H.contains(reports, 'blocked term=', 'every accepted report is logged, so silence is provable')
H.contains(reports, 'detail=permission prompt', 'with its detail')
agents.report(99999, 'blocked')
H.contains(table.concat(agents.log_lines(), '\n'), 'no such live terminal',
  'a report for a terminal this session does not have says so')
agents.report(1, 'working on it')
H.contains(table.concat(agents.log_lines(), '\n'), 'the FIRST argument is the state',
  'and a state/detail mix-up names the mistake instead of vanishing')

agents.setup(false)
notified = nil
H.eq(agents.enabled, false, 'agents = false turns it off')
H.eq(agents.publish(), false, 'so nothing is published for other sessions to read')
H.eq(require('muxim.drawer').open(), false, 'and the drawer refuses rather than showing a dead list')
H.contains(notified, 'agent watching is off', 'saying why')
agents.setup({})

local guard = terminal.open_in_tab('sleep 300')
vim.wait(300)
agents.report(guard, 'working', '', 'claude', 'sess-a')
agents.report(guard, 'working', '', 'claude', 'sess-a', { id = 'kid', type = 'Explore' })
agents.report(guard, 'ended', '', 'claude', 'sess-a', { id = 'kid' })
H.eq(#agents.agents_in(guard), 1,
  'a sub-agent whose SubagentStop carries no agent_type is still removed. Entries are '
  .. 'keyed by id, so the old "a different agent ended" guard must not apply to them: it '
  .. 'compared Explore against claude and kept a finished child working forever')

agents.report(guard, 'blocked', 'the second claude', 'claude', 'sess-b')
H.eq(#agents.agents_in(guard), 1,
  'a top-level agent reporting under a NEW session id replaces the old one rather than '
  .. 'sitting beside it. A /clear rotates the session id without a SessionEnd, and two '
  .. 'phantom claude rows would drive the tabline mark forever')
H.eq(agents.agents_in(guard)[1].session, 'sess-b', 'the survivor is the one still reporting')

agents.report(guard, 'working', '', 'claude', 'sess-b', { id = 'kid2', type = 'Plan' })
H.eq(#agents.agents_in(guard), 2, 'with its own children')
agents.report(guard, 'working', '', 'codex', 'sess-c')
H.eq(#agents.agents_in(guard), 3,
  'while a DIFFERENT agent in the same terminal is left alone: only the same name is '
  .. 'treated as the same agent under a new id')
agents.clear(guard)
vim.api.nvim_buf_delete(guard, { force = true })

local events = {}
local seen_here = vim.api.nvim_create_autocmd('User', {
  pattern = 'MuximAgentState',
  callback = function(args) events[#events + 1] = args.data end,
})
local flagged = terminal.open_in_tab('sleep 300')
vim.wait(300)
agents.report(flagged, 'blocked', 'x', 'claude', 'sess-d')
H.eq(events[#events].here, true,
  'a local state change says so, and carries buf, because a handler that jumps to the '
  .. 'agent needs to know whether there is a buffer here to jump to')
H.eq(events[#events].buf, flagged, 'with the buffer')
vim.api.nvim_del_autocmd(seen_here)
agents.clear(flagged)
vim.api.nvim_buf_delete(flagged, { force = true })

local drawer_rows = require('muxim.drawer').ordered({
  { id = 'p1', name = 'claude', state = 'idle' },
  { id = 'c2', parent = 'p1', name = 'Plan', state = 'working' },
  { id = 'p2', name = 'codex', state = 'working' },
  { id = 'c1', parent = 'p1', name = 'Explore', state = 'blocked' },
  { id = 'c9', parent = 'gone', name = 'Orphan', state = 'working' },
})
H.eq(#drawer_rows, 5, 'the drawer orders every agent it was given')
H.eq(drawer_rows[1].name .. ',' .. drawer_rows[2].name .. ',' .. drawer_rows[3].name,
  'claude,Plan,Explore', 'each parent is followed by its own children')
H.eq(drawer_rows[4].name, 'codex', 'before the next top-level agent')
H.eq(drawer_rows[5].name, 'Orphan',
  'and a child whose parent is NOT in the list is still shown, at the top level: the '
  .. 'published state file is a flat list so an older session, or one mid-reload, can '
  .. 'hand us a child without its parent, and dropping it would hide a live agent')

local tree = terminal.open_in_tab('sleep 300')
vim.wait(300)
local parent_session = 'parent-session'
agents.report(tree, 'working', '', 'claude', parent_session)
agents.report(tree, 'working', '', 'claude', parent_session,
  { id = 'agent-1', type = 'Explore' })
H.eq(#agents.agents_in(tree), 2, 'a terminal can hold an agent AND its sub-agent')
H.eq(agents.agents_in(tree)[1].parent, nil, 'the top-level agent is listed first')
H.eq(agents.agents_in(tree)[2].name, 'Explore', 'and the child is named by its type')
H.eq(agents.agents_in(tree)[2].parent, parent_session, 'and knows whose child it is')

agents.report(tree, 'idle', 'waiting for you', 'claude', parent_session)
H.eq(agents.state(tree).state, 'working',
  'THE case the probe found: a real claude fires Stop while its sub-agent is still '
  .. 'running, so the parent goes idle with live work underneath it. state() is a '
  .. 'ROLLUP over the terminal, so the terminal still reads working and the tabline '
  .. 'mark, tab_state and <prefix>A need no changes at all')

agents.report(tree, 'blocked', 'the child wants you', 'claude', parent_session,
  { id = 'agent-1', type = 'Explore' })
H.eq(agents.state(tree).state, 'blocked', 'a blocked CHILD makes the terminal blocked')
H.eq(agents.state(tree).name, 'Explore', 'and the rollup names the one that wants you')

agents.report(tree, 'idle', 'waiting for you', 'claude', parent_session)
H.eq(agents.reconcile(tree, parent_session, { 'agent-1' }), false,
  'a Stop whose task list still names the child prunes nothing')
H.eq(agents.reconcile(tree, parent_session, {}), true,
  'and a Stop whose task list is empty prunes it')
H.eq(#agents.agents_in(tree), 1,
  'which is how a sub-agent that dies without a SubagentStop is cleaned up: the state '
  .. 'is reconciled against a snapshot every turn rather than rebuilt from a stream of '
  .. 'events that can be missed')

agents.report(tree, 'working', '', 'claude', parent_session,
  { id = 'agent-2', type = 'Plan' })
H.eq(#agents.agents_in(tree), 2, 'a second sub-agent arrives')
agents.report(tree, 'ended', '', 'claude', parent_session)
H.eq(agents.state(tree), nil,
  'and the parent ending takes its children with it, so a session that exits cannot '
  .. 'leave orphan rows behind')
agents.clear(tree)
vim.api.nvim_buf_delete(tree, { force = true })

local server = require('muxim.server')
if server.self_path then
  local live = terminal.open_in_tab('sleep 300')
  vim.wait(300)
  local state_file = agents.state_file(server.self_path)
  os.remove(state_file)
  H.eq(vim.uv.fs_stat(state_file), nil, 'with no published state on disk')
  H.eq(agents.report(live, 'blocked', 'published by the event'), true, 'a live agent reports')
  H.ok(vim.uv.fs_stat(state_file) ~= nil,
    'a report still publishes, but report() no longer calls publish itself: setup() '
    .. 'SUBSCRIBES it to MuximAgentState, the same event the drawer already used. A '
    .. 'subscription that silently fails to register is this feature\'s favourite bug, '
    .. 'so it is asserted through the file rather than trusted')
  os.remove(state_file)
  vim.api.nvim_exec_autocmds('User', { pattern = 'MuximAgentState', data = {} })
  H.ok(vim.uv.fs_stat(state_file) ~= nil,
    'and the event ALONE is enough to publish, which is what makes it a subscription '
    .. 'rather than a coincidence')
  agents.clear(live)
  vim.api.nvim_buf_delete(live, { force = true })
end

vim.notify = real_notify
local silent_sessions = {
  { current = true, agents = { { name = 'claude', state = 'running', buf = 1 } } },
  { current = false, agents = { { name = 'codex', state = 'running', buf = 1 } } },
}
H.eq(#agents.unwired(silent_sessions), 1,
  'an agent discovered by ps that has never reported is "not wired": muxim can see it '
  .. 'running and cannot hear from it')
H.eq(agents.unwired(silent_sessions)[1].name, 'claude', 'and it is the one in THIS session')
H.eq(#agents.unwired({ { current = true, agents = { { name = 'claude', state = 'blocked' } } } }), 0,
  'an agent that reports is not')

drawer.open()
H.eq(vim.fn.exists('#muxim_drawer'), 1,
  'the drawer keeps its autocmd group ALIVE while it is open: it once created the '
  .. 'group and then deleted it five lines later, and every spec still passed')
local drawer_autocmds = #vim.api.nvim_get_autocmds({ group = 'muxim_drawer' })
H.ok(drawer_autocmds >= 4, 'with its ColorScheme, VimLeavePre, User and WinClosed handlers')
H.eq(#vim.api.nvim_get_autocmds({ group = 'muxim_drawer', pattern = 'MuximAgentState' }), 1,
  'including the one that repaints when an agent reports')
drawer.close()
H.eq(vim.fn.exists('#muxim_drawer'), 0, 'and drops the group when it closes')

vim.cmd('tabonly')
vim.cmd('only')
drawer.open()
vim.cmd('only')
H.eq(#vim.api.nvim_tabpage_list_wins(0), 1, 'the drawer alone in the only window of the only tab')
H.eq(#vim.api.nvim_list_tabpages(), 1, 'and the only tab')
vim.api.nvim_win_set_cursor(0, { 1, 0 })
drawer.select()
H.eq(#vim.api.nvim_list_tabpages(), 1,
  'selecting from it does not close the last window, which would take the tab with it')

drawer.setup({ highlights = function() vim.api.nvim_set_hl(0, 'MuximAgentBlocked', {}) end })
H.eq(drawer.open() ~= false, true,
  'a highlights function that returns nothing still opens the drawer, rather than '
  .. 'throwing out of pairs()')
drawer.close()
drawer.setup({ highlights = {} })

local real_format = drawer.format
drawer.setup({ format = function() return nil end })
drawer.open()
vim.wait(300)
local rendered = table.concat(vim.api.nvim_buf_get_lines(drawer.buffer(), 0, -1, false), '\n')
H.ok(rendered:find('nil', 1, true) == nil,
  'a format function that returns nothing renders a name, not the literal "nil"')
drawer.close()
drawer.format = real_format

H.eq(agents.command_name('.claude-unwrapp'), 'claude',
  'a nix-wrapped binary is recognised, and Linux ps truncates comm to 15 characters, '
  .. 'so the suffix it is named after is not even there to match')
H.eq(agents.command_name('.claude-wrapped'), 'claude', 'the untruncated form works too')
H.eq(agents.command_name('claude-helper'), nil, 'and an unrelated command is not an agent')

local saved_commands, saved_marks = agents.COMMANDS, agents.MARKS
agents.setup({ commands = { 'crush' } })
H.eq(agents.COMMANDS.crush, true, 'commands accepts a list')
agents.setup({ commands = { claude = false, codex = true } })
H.eq(agents.COMMANDS.claude, false, 'and a map, where false means OFF rather than on')
agents.setup({ marks = { blocked = 'X' } })
H.eq(agents.MARKS.blocked, 'X', 'marks are merged over the defaults')
H.eq(agents.MARKS.working, '~', 'leaving the ones you did not name alone')
require('muxim.drawer').setup({ width = 20, side = 'left' })
H.eq(drawer.WIDTH, 20, 'the drawer takes a width')
H.eq(drawer.SIDE, 'left', 'and a side')
drawer.setup({ width = 34, side = 'right' })
agents.COMMANDS, agents.MARKS = saved_commands, saved_marks

local captured
local phone = require('muxim.terminal').open_in_tab('sleep 300')
agents.setup({ notify = function(entry) captured = entry end })
H.eq(#vim.api.nvim_list_uis(), 0, 'this session has no UI')
desktop = nil
agents.focused = false
H.eq(agents.report(phone, 'blocked', 'ring my phone', 'claude'), true, 'a blocked report')
H.ok(captured ~= nil,
  'a notify FUNCTION still fires with no UI: the rule is about vim.notify, and a '
  .. 'detached session is exactly where a user callback earns its keep')
H.eq(captured and captured.name, 'claude', 'and it receives the agent name')
H.eq(desktop, nil,
  'and it replaces delivery ENTIRELY, desktop half included, even unfocused: the doc '
  .. 'says so, and the function can call agents.desktop_notify itself to keep it')
agents.focused = true
agents.setup({ notify = 'unfocused' })
agents.notify_desktop = false
agents.desktop_notify = real_desktop

agents.report('9\nFAKE  forged log line', 'blocked')
agents.report(buf, 'bogus\nFAKE  forged log line')
local forged = 0
for _, line in ipairs(agents.log_lines()) do
  if line:sub(1, 4) == 'FAKE' then forged = forged + 1 end
end
H.eq(forged, 0, 'a newline in any argument cannot forge a line in agents.log')

local repeats = 0
local repeat_group = vim.api.nvim_create_augroup('muxim_spec_repeats', { clear = true })
vim.api.nvim_create_autocmd('User', {
  pattern = 'MuximAgentState', group = repeat_group,
  callback = function() repeats = repeats + 1 end,
})
agents.report(phone, 'working', '', 'claude')
agents.report(phone, 'working', '', 'claude')
agents.report(phone, 'working', '', 'claude')
H.eq(repeats, 1,
  'the same state reported three times is ONE change: a user with both the settings '
  .. 'hooks and the plugin directory gets every event twice, and the log, the drawer '
  .. 'and the notification must not double')
vim.api.nvim_del_augroup_by_id(repeat_group)

agents.report(phone, 'blocked', string.rep('x', 5000), 'claude')
H.ok(#agents.state(phone).detail <= agents.DETAIL_MAX,
  'a detail is capped, so one hostile report cannot put 5KB into the log, the drawer '
  .. 'and the notification')

local dead = require('muxim.terminal').open_in_tab('sh -c "exit 0"')
H.ok(vim.wait(3000, function()
  return not require('muxim.terminal').job_is_running(dead)
end, 50), 'a terminal whose job has exited')
H.eq(vim.bo[dead].buftype, 'terminal', 'still looks like a terminal buffer')
H.eq(agents.report(dead, 'blocked', 'too late'), false,
  'and a report arriving after it died is refused rather than becoming a permanent ghost')
local published_dead = false
for _, term in ipairs(agents.terminals()) do
  if term.buf == dead then published_dead = true end
end
H.eq(published_dead, false, 'and it is not published to the fleet either')
vim.cmd('tabfirst')

local exit_probe = H.runtime_dir() .. '/exit-report.txt'
local probe_path = require('muxim.runtime').socket('exit-guard')
H.ok(H.spawn_server(probe_path, '.'), 'a session to quit while an agent reports into it')
local probe_ok, probe_chan = pcall(vim.fn.sockconnect, 'pipe', probe_path, { rpc = true })
H.ok(probe_ok and probe_chan > 0, 'connected to it')
vim.fn.rpcrequest(probe_chan, 'nvim_exec_lua', ([[
  local term = require('muxim.terminal').open()
  vim.api.nvim_create_autocmd('VimLeavePre', { callback = function()
    local accepted = require('muxim.agents').report(term, 'blocked', 'during the exit')
    local out = io.open(%q, 'w')
    out:write(tostring(accepted) .. ' exiting=' .. tostring(vim.v.exiting))
    out:close()
  end })
]]):format(exit_probe), {})
vim.fn.rpcnotify(probe_chan, 'nvim_exec_lua', 'vim.schedule(function() pcall(vim.cmd, "qall!") end)', {})
H.ok(vim.wait(5000, function() return vim.uv.fs_stat(exit_probe) ~= nil end, 50),
  'it reports from VimLeavePre on the way out')
local probe_file = io.open(exit_probe, 'r')
local probe_result = probe_file:read('*a')
probe_file:close()
H.contains(probe_result, 'false',
  'and the report is REFUSED during an exit: this codebase has been wedged three times '
  .. 'by work done near a quit')

for _, group in ipairs({ 'MuximAgentBlocked', 'MuximAgentWorking', 'MuximPreviewHeading',
  'MuximPreviewJob', 'MuximPreviewPath' }) do
  H.ok(next(vim.api.nvim_get_hl(0, { name = group })) ~= nil,
    group .. ' is defined by setup(), not only when the drawer first opens')
end

H.finish('agents_spec')
