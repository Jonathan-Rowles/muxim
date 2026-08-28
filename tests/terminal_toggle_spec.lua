local H = dofile('tests/helper.lua')
local terminal = require('muxim.terminal')

local file_a = H.runtime_dir() .. '/toggle-a.txt'
local file_b = H.runtime_dir() .. '/toggle-b.txt'

vim.cmd('edit ' .. vim.fn.fnameescape(file_a))
local file_a_buf = vim.api.nvim_get_current_buf()

local term = terminal.toggle()
vim.cmd('stopinsert')
H.ok(terminal.is_terminal(term), 'toggle opens a terminal when there is none')
H.eq(vim.api.nvim_get_current_buf(), term, 'and focuses it')
H.ok(terminal.is_managed(term), 'and the terminal is managed')

terminal.toggle()
H.eq(vim.api.nvim_get_current_buf(), file_a_buf, 'toggling off returns to the alternate file buffer')

H.eq(terminal.toggle(), term, 'toggling back reuses the same terminal')
vim.cmd('stopinsert')
terminal.toggle()

vim.t.muxim_terminal = nil
H.eq(terminal.toggle(), term, 'toggle finds the tab own hidden terminal with no registration')
vim.cmd('stopinsert')
H.eq(terminal.registered(), term, 'and registers it again')

vim.cmd('split ' .. vim.fn.fnameescape(file_b))
H.eq(vim.bo.buftype, '', 'the new window holds a file, not the terminal')
terminal.toggle()
vim.cmd('stopinsert')
H.eq(vim.api.nvim_get_current_buf(), term, 'toggle focuses the window already showing the terminal')
H.eq(#vim.api.nvim_tabpage_list_wins(0), 2, 'without opening another window')

vim.cmd('only')
vim.cmd('edit ' .. vim.fn.fnameescape(file_a))
vim.cmd('split ' .. vim.fn.fnameescape(file_b))
local split_buf = vim.api.nvim_get_current_buf()
H.eq(#vim.api.nvim_tabpage_list_wins(0), 2, 'two file windows, terminal off screen')
terminal.toggle()
vim.cmd('stopinsert')
H.eq(vim.api.nvim_get_current_buf(), term, 'the terminal comes back into the window you are in')
H.eq(#vim.api.nvim_tabpage_list_wins(0), 2, 'showing it takes over that window instead of opening one')
terminal.toggle()
H.eq(#vim.api.nvim_tabpage_list_wins(0), 2, 'so hiding it must leave the window count alone')
H.eq(vim.api.nvim_get_current_buf(), split_buf, 'and put back the file that window was showing')
H.ok(vim.api.nvim_buf_is_valid(term), 'the terminal survives off screen')
vim.cmd('only')

local hidden_from = nil
terminal.on_terminal_hide = function(buf) hidden_from = buf end
vim.cmd('$tabnew')
terminal.open()
vim.cmd('stopinsert')
local lone = terminal.open()
vim.cmd('stopinsert')
H.ok(terminal.is_terminal(vim.fn.bufnr('#')), 'the only alternate here is another terminal')
terminal.toggle()
H.eq(hidden_from, lone, 'one window and no usable alternate, so toggle calls on_terminal_hide')
terminal.on_terminal_hide = nil
vim.cmd('tabclose')

vim.cmd('$tabnew')
vim.cmd('edit ' .. vim.fn.fnameescape(file_a))
terminal.open()
vim.cmd('stopinsert')
terminal.open()
vim.cmd('stopinsert')
H.ok(terminal.is_terminal(vim.fn.bufnr('#')), 'again the only alternate is another terminal')
terminal.toggle()
H.eq(vim.api.nvim_get_current_buf(), file_a_buf,
  'with no hook configured, toggle falls back to the last file buffer you were in')
vim.cmd('tabclose')

terminal.enter_insert = false
H.ok(not terminal.should_enter_insert(term), 'enter_insert off means no automatic insert')

vim.cmd('$tabnew')
vim.cmd('terminal')
vim.cmd('stopinsert')
local foreign = vim.api.nvim_get_current_buf()
H.ok(not terminal.is_managed(foreign), 'a terminal opened under the default adopt_foreign_terminals=false is unmanaged')
vim.cmd('enew')
vim.t.muxim_terminal = nil
H.ok(terminal.hidden_for_tab() ~= foreign, 'an unmanaged terminal is never reused as this tab own')
H.ok(terminal.orphaned() ~= foreign, 'nor offered as an orphan for toggle to steal')
terminal.enter_insert = true
vim.api.nvim_set_current_buf(foreign)
H.ok(not terminal.should_enter_insert(foreign), 'nor put into terminal mode by enter_insert')
terminal.enter_insert = false
vim.cmd('bdelete! ' .. foreign)
if #vim.api.nvim_list_tabpages() > 1 then vim.cmd('tabclose') end
vim.api.nvim_set_current_buf(term)

vim.api.nvim_set_current_buf(term)
terminal.enter_insert = true
H.ok(terminal.should_enter_insert(term), 'enter_insert on inserts for the focused terminal')
H.ok(not terminal.should_enter_insert(file_a_buf), 'and never for a file buffer')

H.ok(not terminal.reading_scrollback(term), 'a terminal at its prompt is not scrolled back')

local inserted = nil
local real_start_insert = terminal.start_insert
terminal.start_insert = function() inserted = vim.api.nvim_get_current_buf() end
vim.api.nvim_exec_autocmds('BufEnter', {})
H.drain()
H.eq(inserted, term, 'BufEnter into a terminal starts insert')

inserted = nil
vim.api.nvim_set_current_buf(file_a_buf)
vim.api.nvim_exec_autocmds('BufEnter', {})
H.drain()
H.eq(inserted, nil, 'BufEnter into a file buffer does not')

inserted = nil
vim.api.nvim_exec_autocmds('BufEnter', { buffer = term })
vim.api.nvim_set_current_buf(file_a_buf)
H.drain()
H.eq(inserted, nil, 'and the insert is decided after the loop settles, never on a stale window')

terminal.start_insert = real_start_insert
terminal.enter_insert = false

H.finish('terminal_toggle_spec')
