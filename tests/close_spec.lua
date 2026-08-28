local H = dofile('tests/helper.lua')
local muxim = require('muxim')

local answer = 1
local asked
local real_confirm = vim.fn.confirm
vim.fn.confirm = function(msg)
  asked = msg
  return answer
end

local last_close_calls = 0
local real_on_last_close = muxim.on_last_close
muxim.on_last_close = function() last_close_calls = last_close_calls + 1 end

vim.cmd('tabonly')
vim.cmd('only')

vim.cmd('$tabnew')
vim.cmd('vsplit')
H.eq(#vim.api.nvim_tabpage_list_wins(0), 2, 'tab has two panes')

answer = 2
asked = nil
muxim.close_pane()
H.contains(asked, 'pane', 'close_pane asks first')
H.eq(#vim.api.nvim_tabpage_list_wins(0), 2, 'declining leaves both panes')

answer = 1
muxim.close_pane()
H.eq(#vim.api.nvim_tabpage_list_wins(0), 1, 'accepting closes one pane')
H.eq(last_close_calls, 0, 'closing a pane with tabs open never reaches on_last_close')

local before_tabs = #vim.api.nvim_list_tabpages()
answer = 2
asked = nil
muxim.close_tab()
H.contains(asked, 'tab', 'close_tab asks first')
H.eq(#vim.api.nvim_list_tabpages(), before_tabs, 'declining leaves the tab')

answer = 1
muxim.close_tab()
H.eq(#vim.api.nvim_list_tabpages(), before_tabs - 1, 'accepting closes the tab')

vim.cmd('tabonly')
vim.cmd('only')
H.eq(#vim.api.nvim_list_tabpages(), 1, 'down to a single tab')

last_close_calls = 0
muxim.close_pane()
H.eq(last_close_calls, 1, 'close_pane on the last pane defers to on_last_close')
H.eq(#vim.api.nvim_list_tabpages(), 1, 'and does not close the window itself')

last_close_calls = 0
muxim.close_tab()
H.eq(last_close_calls, 1, 'close_tab on the last tab defers to on_last_close')
H.eq(#vim.api.nvim_list_tabpages(), 1, 'and does not close the tab itself')

local overridden = 0
require('muxim').setup({ prefix = '<C-a>', on_last_close = function() overridden = overridden + 1 end })
muxim.close_tab()
H.eq(overridden, 1, 'setup({on_last_close}) replaces the handler')

muxim.on_last_close = real_on_last_close

local prompt, choices, default
vim.fn.confirm = function(msg, list, def)
  prompt, choices, default = msg, list, def
  return answer
end

local ran = {}
local real_cmd = vim.cmd
vim.cmd = function(command) ran[#ran + 1] = command end

answer = 3
muxim.on_last_close()
H.contains(choices, '&Quit', 'the last-pane prompt offers Quit')
H.contains(choices, '&Detach', 'and Detach')
H.contains(choices, '&Cancel', 'and Cancel')
H.eq(default, 3, 'Cancel is the default')
H.contains(prompt, '<C-a>s', 'the prompt names the key that reattaches')
H.eq(#ran, 0, 'cancelling runs nothing')

answer = 1
ran = {}
muxim.on_last_close()
H.eq(ran[1], 'confirm qall', 'Quit quits, asking about unsaved buffers first')

answer = 2
ran = {}
muxim.on_last_close()
H.eq(ran[1], 'detach', 'Detach detaches')

vim.cmd = real_cmd
vim.fn.confirm = real_confirm
H.finish('close_spec')
