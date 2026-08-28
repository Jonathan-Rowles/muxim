local H = dofile('tests/helper.lua')
local keys = require('muxim.keys')

local defaults = keys.defaults()
H.ok(defaults['x'] ~= nil, 'x is a default (kill pane)')
H.ok(defaults['&'] ~= nil, 'ampersand is a default (kill window)')
H.ok(defaults['"'] == nil, 'no split binding: native <C-w>s already covers it')
H.ok(defaults['%'] == nil, 'no vsplit binding: native <C-w>v already covers it')
H.ok(defaults['z'] ~= nil, 'z zooms')
H.ok(defaults[','] ~= nil, 'comma renames window')
H.ok(defaults['?'] ~= nil, 'question mark lists keys')
H.ok(defaults['1'] ~= nil, 'window 1 selectable')
H.ok(defaults['0'] == nil, 'no window 0 binding: tabs are 1-based, tabnext 0 always errors')
H.ok(defaults['<M-Up>'] ~= nil, 'meta-arrow resizes')

local function desc_of(entry) return entry[2] end
H.eq(desc_of(defaults['x']), 'kill pane', 'x is kill pane, matching tmux')
H.eq(desc_of(defaults['&']), 'kill window', 'ampersand is kill window, matching tmux')

keys.setup({ prefix = '<C-g>', keys = { a = function() end, b = false } })
H.eq(keys.prefix, '<C-g>', 'prefix applied')
H.ok(vim.fn.maparg('<C-g>', 'n', false, true).callback ~= nil, 'prefix mapped')
H.ok(keys.bindings()['b'] == false, 'false binding retained in table')

vim.keymap.set('n', '<C-y>', '<cmd>echo "mine"<cr>')
keys.setup({ prefix = '<C-y>', keys = { a = function() end } })
keys.setup({ prefix = '<C-g>', keys = { a = function() end } })
H.ok(vim.fn.maparg('<C-y>', 'n') ~= '', 'user mapping restored after prefix moves away')

vim.keymap.set('n', '<C-e>', function() return '<Esc>' end, { expr = true, replace_keycodes = true })
keys.setup({ prefix = '<C-e>', keys = { a = function() end } })
keys.setup({ prefix = '<C-g>', keys = { a = function() end } })
H.eq(vim.fn.maparg('<C-e>', 'n', false, true).replace_keycodes, 1,
  'restored expr mapping keeps replace_keycodes instead of inserting literal keycode text')
vim.keymap.del('n', '<C-e>')

keys.teardown()
H.eq(keys.prefix, nil, 'teardown clears the prefix')
H.eq(vim.fn.maparg('<C-g>', 'n'), '', 'teardown removes the bare prefix mapping')
H.eq(vim.fn.maparg('<C-g>a', 'n'), '', 'teardown removes the suffix mappings')

local local_buf = vim.api.nvim_create_buf(true, false)
local other_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(local_buf)
vim.keymap.set('n', '<C-t>', '<cmd>echo "local"<cr>', { buffer = local_buf })
keys.setup({ prefix = '<C-t>', keys = { a = function() end } })
keys.setup({ prefix = '<C-g>', keys = { a = function() end } })
vim.api.nvim_set_current_buf(other_buf)
H.eq(vim.fn.maparg('<C-t>', 'n'), '', 'buffer-local mapping never recorded as shadowed')
vim.api.nvim_set_current_buf(local_buf)
H.ok(vim.fn.maparg('<C-t>', 'n') ~= '', 'buffer-local mapping untouched in its own buffer')
H.ok(vim.fn.maparg('<C-g>a', 'n', false, true).callback ~= nil, 'suffix is a real mapping')
H.ok(vim.fn.maparg('<C-g><C-g>', 'n', false, true).callback ~= nil, 'prefix twice is send-prefix')
H.ok(vim.fn.maparg('<C-g>a', 't', false, true).callback ~= nil, 'suffix mapped in terminal mode')

keys.setup({ prefix = '<C-a>', keys = require('muxim.keys').defaults() })

local tabs_before = #vim.api.nvim_list_tabpages()
vim.api.nvim_feedkeys(vim.keycode('<C-a>c'), 'tx', false)
H.eq(#vim.api.nvim_list_tabpages(), tabs_before + 1, 'pressing prefix c opens a new window end to end')
vim.cmd('stopinsert')

vim.cmd('tabfirst')
vim.cmd('enew')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { '41' })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys(vim.keycode('<C-a><C-a>'), 'tx', false)
H.eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], '42', 'prefix twice sends the native increment through')

vim.api.nvim_feedkeys(vim.keycode('<C-a>q'), 'tx', false)
H.eq(vim.fn.reg_recording(), '', 'unknown suffix is swallowed, q does not start recording')
H.eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], '42', 'swallowed suffix touched nothing')

H.finish('keys_spec')
