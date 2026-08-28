local H = dofile('tests/helper.lua')
local muxim = require('muxim')
local terminal = require('muxim.terminal')

muxim.adopt_foreign_terminals = true
muxim.keep_busy_terminals = false

vim.cmd('$tabnew')
local owner_tab = vim.api.nvim_get_current_tabpage()
vim.cmd('terminal')
vim.cmd('stopinsert')
local buf = vim.api.nvim_get_current_buf()
local pid = vim.b[buf].terminal_job_pid
H.ok(terminal.is_managed(buf), 'plugin marks terminals it manages')
H.eq(terminal.owner(buf), owner_tab, 'terminal owned by the tab that created it')
vim.cmd('enew')

vim.cmd('$tabnew')
local viewer_tab = vim.api.nvim_get_current_tabpage()
vim.api.nvim_set_current_buf(buf)
H.eq(terminal.owner(buf), owner_tab, 'viewing from another tab does not steal ownership')
vim.cmd('enew')
vim.cmd('tabclose')
H.drain()
H.ok(vim.api.nvim_buf_is_loaded(buf), 'closing the viewing tab leaves the terminal alive')
H.ok(H.pid_alive(pid), 'closing the viewing tab leaves the shell alive')
H.eq(vim.api.nvim_tabpage_is_valid(viewer_tab), false, 'viewing tab really closed')

vim.api.nvim_set_current_tabpage(owner_tab)
vim.fn.chansend(vim.b[buf].terminal_job_id, 'sleep 999\n')
H.ok(vim.wait(3000, function() return terminal.busy(buf) end, 50), 'busy detects a foreground child')

local wiped, kept = terminal.wipe_orphans({ keep_busy = true })
H.eq(#wiped, 0, 'owned terminal is never wiped')
H.eq(#kept, 0, 'owned terminal is not even considered')

vim.cmd('tabclose')
H.ok(vim.wait(3000, function() return not vim.api.nvim_buf_is_loaded(buf) end, 50),
  'closing the owner tab reaps the terminal')
H.ok(vim.wait(3000, function() return not H.pid_alive(pid) end, 50), 'owner tab close kills the shell')

vim.cmd('$tabnew')
vim.cmd('terminal')
vim.cmd('stopinsert')
local busy_buf = vim.api.nvim_get_current_buf()
local busy_pid = vim.b[busy_buf].terminal_job_pid
vim.fn.chansend(vim.b[busy_buf].terminal_job_id, 'sleep 999\n')
H.ok(vim.wait(3000, function() return terminal.busy(busy_buf) end, 50), 'second terminal is busy')
vim.b[busy_buf].muxim_owner_tab = nil
vim.cmd('enew')
local registered_wiped = terminal.wipe_orphans({ keep_busy = false, notify = false })
H.eq(#registered_wiped, 0, 'terminal registered by a live tab is not wiped')
vim.t.muxim_terminal = nil
local kept_wiped, kept_busy = terminal.wipe_orphans({ keep_busy = true })
H.eq(#kept_wiped, 0, 'keep_busy spares an orphan running a job')
H.eq(#kept_busy, 1, 'keep_busy reports what it spared')
H.ok(H.pid_alive(busy_pid), 'spared job still running')
terminal.wipe_orphans({ keep_busy = false, notify = false })
H.ok(vim.wait(3000, function() return not H.pid_alive(busy_pid) end, 50), 'keep_busy=false reaps it')

muxim.keep_busy_terminals = true
vim.cmd('$tabnew')
vim.cmd('terminal')
vim.cmd('stopinsert')
local spared_buf = vim.api.nvim_get_current_buf()
local spared_pid = vim.b[spared_buf].terminal_job_pid
vim.fn.chansend(vim.b[spared_buf].terminal_job_id, 'sleep 999\n')
H.ok(vim.wait(3000, function() return terminal.busy(spared_buf) end, 50), 'third terminal is busy')
vim.cmd('tabclose')
H.drain()
H.ok(vim.api.nvim_buf_is_loaded(spared_buf),
  'the shipped default keep_busy_terminals=true reaches TabClosed and spares the busy terminal')
H.ok(H.pid_alive(spared_pid), 'with its job still running')
terminal.wipe_orphans({ keep_busy = false, notify = false })
H.ok(vim.wait(3000, function() return not H.pid_alive(spared_pid) end, 50), 'cleanup reaps it')

H.finish('ownership_spec')
