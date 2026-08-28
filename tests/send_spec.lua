local H = dofile('tests/helper.lua')
local terminal = require('muxim.terminal')

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end

local function wait_for(buf, needle, ms)
  return vim.wait(ms or 5000, function()
    return buffer_text(buf):find(needle, 1, true) ~= nil
  end, 50)
end

vim.cmd('$tabnew')
local buf = terminal.open()
vim.cmd('stopinsert')
H.ok(vim.wait(3000, function() return vim.b[buf].terminal_job_pid ~= nil end, 50), 'terminal started')

H.eq(terminal.busy(buf), false, 'an idle shell is not busy')

terminal.send(buf, 'echo first-marker')
H.ok(wait_for(buf, 'first-marker'), 'send runs a command in the terminal')

terminal.send(buf, 'echo not-run-yet', false)
vim.wait(1200)
H.ok(buffer_text(buf):find('not%-run%-yet') ~= nil, 'run_immediately=false puts the text on the prompt')
H.eq(select(2, buffer_text(buf):gsub('not%-run%-yet', '')), 1,
  'and it appears only once, so it was not executed')

vim.fn.chansend(vim.b[buf].terminal_job_id, '\n')
vim.wait(600)

local shell_pid = vim.b[buf].terminal_job_pid
vim.fn.chansend(vim.b[buf].terminal_job_id, 'sleep 999\n')
H.ok(vim.wait(5000, function() return terminal.busy(buf) end, 50), 'busy() sees a running child')

terminal.send(buf, 'echo after-interrupt')
H.ok(wait_for(buf, 'after-interrupt', 8000), 'send interrupts a running command and then writes')
H.ok(H.pid_alive(shell_pid), 'the shell itself survived the interrupt')
H.ok(vim.wait(3000, function() return not terminal.busy(buf) end, 50), 'the child is gone')

local gone = vim.api.nvim_create_buf(false, true)
H.ok(pcall(terminal.send, gone, 'echo x'), 'sending to a non-terminal buffer fails without raising')
H.eq(terminal.busy(gone), false, 'busy() is false for a buffer with no terminal job')

H.finish('send_spec')
