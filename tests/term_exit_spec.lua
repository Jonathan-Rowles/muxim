local H = dofile('tests/helper.lua')

require('muxim').adopt_foreign_terminals = true

local tabs_before = #vim.api.nvim_list_tabpages()
vim.cmd('$tabnew')
vim.cmd('terminal')
vim.cmd('stopinsert')
local buf = vim.api.nvim_get_current_buf()
local job = vim.b[buf].terminal_job_id
H.eq(#vim.api.nvim_list_tabpages(), tabs_before + 1, 'terminal tab opened')

vim.fn.chansend(job, 'exit\n')
H.ok(vim.wait(4000, function() return #vim.api.nvim_list_tabpages() == tabs_before end, 50),
  'tab closes when its only terminal exits')
H.ok(vim.wait(2000, function() return not vim.api.nvim_buf_is_loaded(buf) end, 50),
  'exited terminal buffer is wiped')

vim.cmd('$tabnew')
vim.cmd('split')
vim.cmd('terminal')
vim.cmd('stopinsert')
local shared_tab = vim.api.nvim_get_current_tabpage()
local job2 = vim.b[vim.api.nvim_get_current_buf()].terminal_job_id
vim.fn.chansend(job2, 'exit\n')
vim.wait(1500)
H.ok(vim.api.nvim_tabpage_is_valid(shared_tab), 'tab with another window survives terminal exit')

local reported = {}
vim.api.nvim_create_autocmd('User', {
  pattern = 'MuximTermClose',
  callback = function(args) reported[#reported + 1] = args.data end,
})

vim.cmd('$tabnew')
vim.cmd('split')
vim.cmd('terminal')
vim.cmd('stopinsert')
local job3 = vim.b[vim.api.nvim_get_current_buf()].terminal_job_id
vim.fn.chansend(job3, 'exit 3\n')
H.ok(vim.wait(4000, function() return #reported > 0 end, 50), 'MuximTermClose fires for the exit')
H.eq(reported[#reported] and reported[#reported].exit_code, 3,
  'and carries the job exit code, so config can warn on a failure')

require('muxim').adopt_foreign_terminals = false
local closes = 0
vim.api.nvim_create_autocmd('TermClose', {
  callback = function() closes = closes + 1 end,
})
local events_before = #reported
vim.cmd('$tabnew')
vim.cmd('split')
vim.cmd('terminal')
vim.cmd('stopinsert')
local foreign_job = vim.b[vim.api.nvim_get_current_buf()].terminal_job_id
vim.fn.chansend(foreign_job, 'exit\n')
H.ok(vim.wait(4000, function() return closes > 0 end, 50), 'the unadopted terminal exited')
H.drain()
H.eq(#reported, events_before,
  'an unadopted terminal fires no MuximTermClose: the pair stays balanced with the '
  .. 'MuximTermOpen the adopt gate never fired')

H.finish('term_exit_spec')
