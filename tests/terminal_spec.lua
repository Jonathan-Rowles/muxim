local H = dofile('tests/helper.lua')
local terminal = require('muxim.terminal')

local file_a = H.runtime_dir() .. '/file-a.txt'
local file_b = H.runtime_dir() .. '/file-b.txt'

vim.cmd('edit ' .. vim.fn.fnameescape(file_a))
local t1 = terminal.open()
vim.cmd('stopinsert')
H.ok(terminal.is_managed(t1), 'terminal.open marks its buffer managed')
vim.cmd('edit ' .. vim.fn.fnameescape(file_a))

vim.cmd('$tabnew')
H.eq(vim.fn.tabpagenr(), vim.fn.tabpagenr('$'), 'new tab appends at end')
local t2 = terminal.open()
vim.cmd('stopinsert')
H.eq(vim.b[t2].muxim_owner_tab, vim.api.nvim_get_current_tabpage(), 'TermOpen tags terminal with owner tab')
vim.cmd('edit ' .. vim.fn.fnameescape(file_b))

H.eq(terminal.registered(), t2, 'registration finds tab 2 hidden terminal')
H.eq(terminal.ensure(), t2, 'ensure reuses it instead of opening a new one')
H.eq(vim.api.nvim_get_current_buf(), t2, 'ensure focuses it')
vim.cmd('stopinsert')
vim.cmd('edit ' .. vim.fn.fnameescape(file_b))

vim.cmd('tabfirst')
vim.t.muxim_terminal = nil
H.eq(terminal.registered(), nil, 'tab 1 has no registration after clearing')
H.eq(terminal.hidden_for_tab(), t1, 'hidden_for_tab finds tab 1 terminal, not tab 2')
H.ok(terminal.hidden_for_tab() ~= t2, 'tab 1 lookup does not steal tab 2 terminal')

vim.cmd('tabnext 2')
vim.cmd('tabclose')
H.ok(vim.wait(2000, function() return not vim.api.nvim_buf_is_loaded(t2) end, 50), 'closed tab terminal is wiped')

local _, visible = terminal.window_in_tab()
H.eq(visible, nil, 'no terminal visible in tab 1 yet')
vim.api.nvim_set_current_buf(t1)
_, visible = terminal.window_in_tab()
H.eq(visible, t1, 'window_in_tab sees the displayed terminal')
H.eq(terminal.current(), t1, 'current() falls back to the visible terminal')

H.finish('terminal_spec')
