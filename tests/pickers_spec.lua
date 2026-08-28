local H = dofile('tests/helper.lua')
local pickers = require('muxim.pickers')

local captured
local pick_index
local real_select = vim.ui.select
vim.ui.select = function(entries, opts, on_choice)
  captured = { entries = entries, prompt = opts.prompt, format_item = opts.format_item }
  on_choice(pick_index and entries[pick_index] or nil)
end

local notified
local real_notify = vim.notify
vim.notify = function(msg, level)
  notified = { msg = msg, level = level }
end

pickers.backend = 'select'

vim.cmd('tabonly')
vim.cmd('$tabnew')
vim.cmd('$tabnew')
local tabs = vim.api.nvim_list_tabpages()
H.eq(#tabs, 3, 'three tabs for the window picker')

pick_index = nil
pickers.windows()
H.eq(#captured.entries, 4, 'the window picker offers a session row, then one per tab')
H.eq(captured.entries[1].kind, 'session', 'the session leads, tmux-style')
H.eq(captured.prompt, 'Choose window', 'window picker prompt')
H.contains(captured.format_item(captured.entries[2]), '1:', 'entries are formatted through sources.display')

vim.api.nvim_set_current_tabpage(tabs[1])
pick_index = 4
pickers.windows()
H.eq(vim.api.nvim_get_current_tabpage(), tabs[3], 'choosing a window switches to that tab')

pick_index = nil
captured = nil
pickers.windows()
H.ok(captured ~= nil, 'cancelling still opened the picker')
H.eq(vim.api.nvim_get_current_tabpage(), tabs[3], 'cancelling leaves the current tab alone')

captured = nil
pickers.sessions({})
H.ok(captured ~= nil, 'the session picker offers the sessions source')
H.eq(captured.prompt, 'Choose session', 'session picker prompt')

local sources = require('muxim.sources')
local real_sessions = sources.sessions
sources.sessions = function() return {} end
notified = nil
captured = nil
pickers.sessions({})
H.eq(captured, nil, 'an empty list does not open a picker')
H.contains(notified.msg, 'Nothing to choose', 'it warns instead')
H.eq(notified.level, vim.log.levels.WARN, 'at warning level')
sources.sessions = real_sessions

notified = nil
pickers.backend = 'does-not-exist'
pick_index = nil
captured = nil
pickers.windows()
H.contains(notified.msg, 'no picker backend', 'an unknown backend is reported')
H.ok(captured ~= nil, 'and it falls back to the select backend rather than failing')

pickers.backend = { windows = function() return 'from table backend' end }
H.eq(pickers.windows(), 'from table backend', 'a table backend is used directly')

pickers.backend = { }
captured = nil
pickers.windows()
H.ok(captured ~= nil, 'a backend missing an entry point falls back per function')

pickers.backend = 'select'
vim.ui.select = real_select
vim.notify = real_notify
H.finish('pickers_spec')
