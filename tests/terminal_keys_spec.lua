local H = dofile('tests/helper.lua')
local terminal = require('muxim.terminal')

vim.cmd('$tabnew')
local buf = terminal.open()
vim.cmd('stopinsert')
H.ok(vim.wait(3000, function() return vim.b[buf].terminal_job_pid ~= nil end, 50), 'terminal started')

local suffix = vim.fn.maparg('<C-a>c', 't', false, true)
H.ok(suffix.callback ~= nil, 'the t-mode suffix binding is a callback')
local tabs_before = #vim.api.nvim_list_tabpages()
suffix.callback()
vim.wait(1200)
H.eq(#vim.api.nvim_list_tabpages(), tabs_before + 1, 'the t-mode wrapper runs the binding')
H.eq(vim.bo.buftype, 'terminal', 'and prefix c produced a terminal window')
vim.cmd('stopinsert')
vim.cmd('tabclose')

local prefix_twice = vim.fn.maparg('<C-a><C-a>', 't', false, true)
H.ok(prefix_twice.callback ~= nil, 'prefix twice is bound in terminal mode')

local sent
local real_chan_send = vim.api.nvim_chan_send
local real_get_mode = vim.api.nvim_get_mode
vim.api.nvim_get_mode = function() return { mode = 't', blocking = false } end
vim.api.nvim_chan_send = function(chan, data) sent = { chan = chan, data = data } end
vim.api.nvim_set_current_buf(buf)
prefix_twice.callback()
vim.api.nvim_get_mode = real_get_mode
vim.api.nvim_chan_send = real_chan_send

H.ok(sent ~= nil, 'in terminal mode the prefix is written to the channel, not fed to nvim')
H.eq(sent and sent.data, vim.keycode('<C-a>'), 'and the literal prefix byte is what goes through')
H.eq(sent and sent.chan, vim.bo[buf].channel, 'to the terminal own channel')

H.finish('terminal_keys_spec')
