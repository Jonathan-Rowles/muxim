local H = dofile('tests/helper.lua')
local sources = require('muxim.sources')
local server = require('muxim.server')
local session = require('muxim.session')
local agents = require('muxim.agents')

local entries = sources.sessions({})
H.ok(#entries > 0, 'sessions source lists running servers')
local current
for _, entry in ipairs(entries) do
  if entry.current then current = entry end
end
H.ok(current ~= nil, 'current session flagged')
H.eq(current.path, server.self_path, 'current entry carries our socket')
H.eq(sources.mark(current), '* ', 'current session marked with star')
H.eq(current.dir, agents.session_cwd(), 'a live session carries its own cwd')

local cwd = vim.fn.getcwd(-1, -1)
local merged = sources.sessions({ vim.fn.expand('~/Downloads'), cwd })
H.eq(merged[1].current, true, 'the attached session sorts first')
local downloads
for _, entry in ipairs(merged) do
  if entry.name == 'Downloads' then downloads = entry end
end
H.ok(downloads ~= nil, 'a project directory with no server still appears')
H.eq(downloads.live, false, 'and is marked as not running')
H.eq(sources.mark(downloads), '  ', 'a dead session is unmarked')
H.ok(not sources.ordinal(downloads):find('not running', 1, true),
  'the picker never matches on invisible status text')
H.contains((sources.display(downloads)), '~/Downloads',
  'a dead project row shows the directory it matches on')
H.eq(#sources.sessions({ cwd }), #sources.sessions({}),
  'a directory whose session is already live is not listed twice')

sources.project_dirs = { vim.fn.expand('~/Downloads') }
local configured = sources.sessions()
local found = false
for _, entry in ipairs(configured) do
  if entry.name == 'Downloads' then found = true end
end
H.ok(found, 'sessions() with no argument uses the configured project dirs')
sources.project_dirs = {}

local text = sources.display(current)
H.contains(text, '* ', 'display includes mark')
local _, spans = sources.display(current)
H.eq(spans[1][2], 'MuximAgentCurrent', 'the attached session is highlighted')
H.contains(sources.ordinal(current), vim.fn.fnamemodify(current.dir, ':~'),
  'a session matches on its directory, not only its name')

local windows = sources.windows({ fleet = false })
H.eq(#windows, #vim.api.nvim_list_tabpages() + 1,
  'windows source is a tree: one session row, then a row per tab')
H.eq(windows[1].kind, 'session', 'the session comes first, as its own row')
H.eq(windows[2].kind, 'window', 'with its windows underneath')
H.ok(windows[2].tab ~= nil, 'window entry carries tabpage handle')
H.eq(windows[1].index, windows[2].index,
  'the session row points at its active window, so hovering it previews that')
H.eq(sources.display(windows[2]):sub(1, 4), '  * ',
  'the window you are in is starred, and indented under its session')
H.eq(sources.display(windows[1]):sub(1, 2), '* ', 'the session row is not')

local blocked = {
  kind = 'window', name = 'notes', index = 4, path = '/tmp/muxim-sources-spec.sock',
  session = 'notes', state = 'blocked', agent = '!',
}
local row, row_spans = sources.display(blocked)
H.eq(row:sub(1, 4), '    ', 'a window you are not in is indented under its session')
H.contains(row, '4: notes', 'a window row is numbered')
H.contains(row, '!', 'and carries the agent mark')
local groups = {}
for _, span in ipairs(row_spans) do groups[span[2]] = true end
H.ok(groups.MuximAgentBlocked, 'a blocked agent mark is highlighted')
H.contains(sources.ordinal(blocked), 'notes', 'a window matches on its session name')
H.ok(not sources.ordinal(blocked):find('blocked', 1, true),
  'agent state is not searchable: the picker matches what the row shows')

local lines = H.lines(server.self_path)
H.ok(lines ~= nil and #lines > 0, 'sync lines wrapper returns our own summary')
H.eq(table.concat(H.lines(H.runtime_dir() .. '/nope.sock') or {}, ''), 'not running', 'missing socket previews as not running')

vim.cmd('tabnew')
vim.cmd('tcd /tmp')
H.contains(session.summary(), vim.fn.fnamemodify(vim.fn.getcwd(-1, -1), ':~'),
  'the summary reports the session root, not the tab-local cwd')
vim.cmd('tabclose')

local got
session.lines_async({ path = server.self_path }, function(l, done)
  if done then got = l end
end)
H.ok(vim.wait(2000, function() return got ~= nil end, 20), 'lines_async resolves for self')

H.finish('sources_spec')
