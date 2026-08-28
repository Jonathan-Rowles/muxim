local H = dofile('tests/helper.lua')
local session = require('muxim.session')
local agents = require('muxim.agents')

local children, commands, _, elapsed = agents.process_scan()
H.ok(vim.tbl_count(commands) > 0, 'the process scan reads the process table synchronously')
local self_pid = vim.uv.os_getpid()
H.eq(commands[self_pid], 'nvim', 'and finds this process')
H.ok(elapsed[self_pid] ~= nil, 'with how long it has been running')

vim.cmd('tabonly')
vim.cmd('$tabnew')
require('muxim').adopt_foreign_terminals = true
local terminal_tab = vim.api.nvim_get_current_tabpage()
vim.cmd('terminal sleep 300')
local term_buf = vim.api.nvim_get_current_buf()
H.ok(vim.wait(3000, function() return vim.b[term_buf].terminal_job_pid ~= nil end, 50),
  'a terminal running a long job is open')

children, commands, _, elapsed = agents.process_scan()
local name, since, busy = agents.running_in(children, commands, elapsed,
  tonumber(vim.b[term_buf].terminal_job_pid))
H.eq(name, 'sleep', 'running_in names the process in a terminal, not the terminal')
H.ok(since ~= nil, 'and how long it has been running')
H.eq(busy, true, 'and says it is busy, because it is not sitting at a shell prompt')

local info = vim.json.decode(session.info())
H.eq(info.cwd, vim.fn.fnamemodify(vim.fn.getcwd(-1, -1), ':~'), 'the info carries the session root')
H.eq(#info.windows, #vim.api.nvim_list_tabpages(), 'one entry per window')
local window
for _, w in ipairs(info.windows) do
  if w.current then window = w end
end
H.eq(window.jobs[1].name, 'sleep', 'the window reports what is running in its terminal')
H.eq(window.jobs[1].busy, true, 'and that it is busy')

agents.receive({ v = 1, term = tostring(term_buf), state = 'blocked', detail = 'permission needed' })
H.drain()
info = vim.json.decode(session.info())
for _, w in ipairs(info.windows) do
  if w.current then window = w end
end
H.eq(window.agents[1] and window.agents[1].state, 'blocked', 'a reported agent rides along')

local lines, marks = session.render(info)
local text = table.concat(lines, '\n')
H.contains(text, 'sleep', 'the rendered preview shows the running job')
H.contains(text, 'permission needed', 'and the agent detail')
local groups = {}
for _, mark in ipairs(marks) do groups[mark.group] = true end
H.ok(groups.MuximAgentBlocked, 'the blocked agent is highlighted')
H.ok(groups.MuximPreviewJob, 'the running job is highlighted')
H.ok(groups.MuximPreviewHeading, 'and the session name is a heading')
for _, mark in ipairs(marks) do
  H.ok(lines[mark.line] ~= nil and mark.end_col <= #lines[mark.line],
    'every mark lands inside the line it points at')
end

vim.cmd('edit /tmp/muxim-preview-unsaved.txt')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'not written' })
info = vim.json.decode(session.info())
H.eq(#info.modified, 1, 'an unsaved buffer is reported')
H.contains(table.concat(session.render(info), '\n'), 'unsaved', 'and shown under its own heading')
vim.bo.modified = false

local previewed
session.preview_async({ path = require('muxim.server').self_path }, function(l) previewed = l end)
H.ok(vim.wait(2000, function() return previewed ~= nil end, 20),
  'preview_async renders the current session without a round trip')

vim.api.nvim_set_current_tabpage(terminal_tab)
pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
vim.cmd('tabonly')
local long = {}
for i = 1, 200 do long[i] = 'line ' .. i end
vim.api.nvim_buf_set_lines(0, 0, -1, false, long)
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(win, { 150, 0 })

local small = session.window_view(win, 6)
H.eq(#small.lines, 6, 'a preview takes as many lines as the preview window is tall')
H.eq(small.lines[small.cursor], 'line 150',
  'and re-anchors so the cursor line is inside it, not the top of the buffer')
local big = session.window_view(win, 40)
H.eq(#big.lines, 40, 'a taller preview window gets more lines')
H.eq(big.lines[big.cursor], 'line 150', 'still holding the cursor line')
H.eq(big.total, 200, 'and reports the real buffer length')

vim.api.nvim_win_set_cursor(win, { 200, 0 })
local tail = session.window_view(win, 10)
H.eq(#tail.lines, 10, 'at the end of a buffer the window is still full')
H.eq(tail.lines[#tail.lines], 'line 200', 'showing the last line')

local short = session.window_view(win, 500)
H.eq(#short.lines, 200, 'a preview window taller than the buffer is not padded')

local decoded = vim.json.decode(session.tab_lines(1, 8))
H.eq(#decoded.lines, 8, 'tab_lines honours the height it is given')
H.ok(decoded.cursor ~= nil, 'and says where the cursor sits in what it returned')

H.eq(session.fit('short', 40), 'short', 'a line narrower than the preview is untouched')
H.eq(vim.fn.strdisplaywidth(session.fit(string.rep('x', 300), 40)), 40,
  'a long line is cut to exactly the preview width')
H.contains(session.fit(string.rep('x', 300), 40), '…', 'and says it was cut')
H.eq(vim.fn.strdisplaywidth(session.fit(string.rep('ü', 80), 30)), 30,
  'multibyte lines are cut by display width, not bytes')
H.eq(vim.fn.strdisplaywidth(session.fit('\ttabbed ' .. string.rep('y', 90), 24)), 24,
  'and a tab counts for the cells it occupies')
H.eq(session.fit('abcdef', 1), '…', 'a one-cell preview still fits')

vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep('z', 500), 'tail' })
local narrow = session.window_view(vim.api.nvim_get_current_win(), 4, 32)
H.eq(vim.fn.strdisplaywidth(narrow.lines[1]), 32,
  'window_view fits every line to the width it is given')
H.eq(#vim.json.decode(session.tab_lines(1, 3, 20)).lines, 2,
  'tab_lines never pads a buffer shorter than the preview window')
H.eq(vim.fn.strdisplaywidth(vim.json.decode(session.tab_lines(1, 3, 20)).lines[1]), 20,
  'and applies it in the session that owns the buffer, so the wire carries no waste')

local terminal = require('muxim.terminal')
vim.cmd('tabonly')
local orphan_buf = terminal.open_in_tab('sleep 300')
local owner_tab = vim.api.nvim_get_current_tabpage()
H.ok(vim.wait(3000, function() return vim.b[orphan_buf].terminal_job_pid ~= nil end, 50),
  'a managed terminal is running in its own tab')
agents.report(orphan_buf, 'blocked', 'permission needed', 'claude')
H.drain()
vim.cmd('tabnew')
vim.cmd('buffer ' .. orphan_buf)
vim.api.nvim_set_current_tabpage(owner_tab)
vim.cmd('tabclose')
H.eq(terminal.owner(orphan_buf), nil,
  'showing a terminal in a second tab and closing the first leaves it with no owner tab')
local orphaned
for _, entry in ipairs(agents.tracked()) do
  if entry.buf == orphan_buf then orphaned = entry end
end
H.ok(orphaned ~= nil and orphaned.tab == nil, 'and it is still tracked, with a nil tab')
local ok_info, raw = pcall(session.info)
H.ok(ok_info, 'session.info() survives that: indexing a table with a nil key throws in Lua, '
  .. 'so one orphaned agent used to break the whole session preview')
H.ok(ok_info and vim.json.decode(raw) ~= nil, 'and still returns usable JSON')
pcall(vim.api.nvim_buf_delete, orphan_buf, { force = true })

vim.cmd('tabonly')
vim.cmd('vsplit')
local counted = vim.json.decode(session.info()).windows[1]
H.eq(counted.panes, 2, 'a pane is a window in that tab, and a split makes two')
local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
  relative = 'editor', row = 1, col = 1, width = 10, height = 3,
})
H.eq(vim.json.decode(session.info()).windows[1].panes, 2,
  'a floating window is not a pane: the drawer or a picker being open must not '
  .. 'change what the preview says about the session')
vim.api.nvim_win_close(float, true)
vim.cmd('only')

H.finish('preview_spec')
