local H = dofile('tests/helper.lua')
local tabline = require('muxim.tabline')
local server = require('muxim.server')
local session = require('muxim.session')

local render = tabline.render()
H.ok(render:match('%d%d:%d%d %d%d%-%a+%-%d%d') ~= nil, 'clock rendered in tmux format')
local full = server.self_path and require('muxim.runtime').name_from_socket(server.self_path)
local name = full and (full:match('^%x%x%x%x%x%x%-(.+)$') or full)
H.ok(name and render:find(name, 1, true) ~= nil, 'server name rendered')
H.ok(full == name or not render:find(full, 1, true), 'digest stripped from rendered server name')

local weird = H.runtime_dir() .. '/cover%20letter.txt'
local f = io.open(weird, 'w')
f:write('x')
f:close()
vim.cmd('edit ' .. vim.fn.fnameescape(weird))
render = tabline.render()
H.contains(render, 'cover%%20letter.txt', 'percent in file name escaped for tabline')

vim.cmd('terminal')
vim.cmd('stopinsert')
local summary = session.summary()
H.contains(summary, 'term: ', 'summary labels terminal buffers')
H.contains(summary, 'cover%20letter.txt', 'summary lists file buffers')

os.remove(weird)

vim.cmd('tabonly')
vim.cmd('edit /tmp/muxim-tabline-probe.txt')
local labelled = require('muxim.tabline').tab_label(vim.api.nvim_get_current_tabpage())
local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
  relative = 'editor', row = 1, col = 1, width = 10, height = 3,
})
H.eq(require('muxim.tabline').tab_label(vim.api.nvim_get_current_tabpage()), labelled,
  'a focused floating window does not rename the tab')
vim.api.nvim_win_close(float, true)

local subscribed = vim.api.nvim_get_autocmds({
  group = 'muxim_tabline_redraw', event = 'User', pattern = 'MuximAgentState',
})
H.eq(#subscribed, 1,
  'the tabline REDRAWS ITSELF on an agent state change rather than being redrawn by '
  .. 'agents.lua reaching into it. The subscription is asserted because a listener that '
  .. 'silently fails to register looks exactly like a feature nobody uses')

vim.o.showtabline = 0
tabline.teardown()
H.eq(vim.o.showtabline, 0,
  'teardown never clobbers a showtabline the user set by hand after setup: it restores '
  .. 'only over the value muxim itself applied')
tabline.setup({})
H.eq(vim.o.showtabline, 2, 'and a fresh setup takes the option again')

H.finish('tabline_spec')
