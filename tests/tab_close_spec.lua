local H = dofile('tests/helper.lua')

require('muxim').adopt_foreign_terminals = true
require('muxim').keep_busy_terminals = false
local keys = require('muxim.keys')
H.ok(vim.fn.maparg('<C-a>', 'n', false, true).callback ~= nil, 'prefix mapped in normal mode')
H.ok(vim.fn.maparg('<C-a>', 't', false, true).callback ~= nil, 'prefix mapped in terminal mode')
H.ok(vim.fn.maparg('<C-a>x', 'n', false, true).callback ~= nil, 'suffixes are real mappings, visible to :map')
H.ok(keys.bindings()['x'] ~= nil, 'x bound (tmux kill-pane)')
H.ok(keys.bindings()['&'] ~= nil, 'ampersand bound (tmux kill-window)')
H.ok(keys.bindings()['c'] ~= nil, 'c bound (tmux new-window)')

vim.cmd('$tabnew')
vim.cmd('terminal')
local tA = vim.api.nvim_get_current_buf()
local pA = vim.b[tA].terminal_job_pid
local tabA = vim.api.nvim_get_current_tabpage()
vim.cmd('stopinsert')
H.eq(vim.bo[tA].bufhidden, 'hide', 'TermOpen sets bufhidden hide')
H.eq(vim.b[tA].muxim_owner_tab, tabA, 'TermOpen tags owner tab')
vim.cmd('enew')

vim.cmd('$tabnew')
vim.cmd('terminal')
local tB = vim.api.nvim_get_current_buf()
local pB = vim.b[tB].terminal_job_pid
vim.cmd('stopinsert')
vim.fn.chansend(vim.b[tB].terminal_job_id, 'sleep 999\n')
local child = H.child_pid_of(pB)
H.ok(child ~= '', 'child process started in terminal')

vim.cmd('tabclose')
H.ok(vim.wait(2000, function() return not vim.api.nvim_buf_is_loaded(tB) end, 50), 'tab close wipes its terminal buffer')
H.ok(vim.wait(2000, function() return not H.pid_alive(pB) end, 50), 'tab close kills terminal shell')
H.ok(vim.wait(2000, function() return not H.pid_alive(child) end, 50), 'tab close kills child process')
H.ok(vim.api.nvim_buf_is_loaded(tA), 'hidden terminal owned by another tab survives')

vim.cmd('$tabnew')
local tabC = vim.api.nvim_get_current_tabpage()
vim.api.nvim_set_current_buf(tA)
H.eq(vim.b[tA].muxim_owner_tab, tabA, 'displaying terminal keeps its original owner tab')

vim.api.nvim_set_current_tabpage(tabC)
vim.cmd('enew')
vim.cmd('tabclose')
local wipe_pass_done = false
vim.schedule(function() wipe_pass_done = true end)
vim.wait(2000, function() return wipe_pass_done end, 10)
H.ok(vim.api.nvim_buf_is_loaded(tA), 'terminal survives closing a tab that merely displayed it')

vim.api.nvim_set_current_tabpage(tabA)
vim.cmd('tabclose')
H.ok(vim.wait(2000, function() return not vim.api.nvim_buf_is_loaded(tA) end, 50), 'hidden terminal dies with its owner tab')
H.ok(vim.wait(2000, function() return not H.pid_alive(pA) end, 50), 'owner tab close kills its shell')

H.finish('tab_close_spec')
