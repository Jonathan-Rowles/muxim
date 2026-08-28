local H = dofile('tests/helper.lua')
local server = require('muxim.server')
local runtime = require('muxim.runtime')

local notified = {}
local real_notify = vim.notify
vim.notify = function(msg) notified[#notified + 1] = msg end

local path = runtime.socket('handoff')
H.ok(H.spawn_server(path, '.'), 'a session to hand off from')
H.ok(server.self_path ~= nil, 'and a session to hand off to')

local ok, chan = pcall(vim.fn.sockconnect, 'pipe', path, { rpc = true })
H.ok(ok and chan > 0, 'connected to it')

local function remote(code, args)
  return vim.fn.rpcrequest(chan, 'nvim_exec_lua', code, args or {})
end

remote('vim.cmd("enew"); vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved scratch" })')
H.eq(remote('return vim.bo.modified'), true, 'it has a modified buffer')
H.eq(remote('return vim.api.nvim_buf_get_name(0)'), '', 'with no name, so no one can save it')
H.eq(remote('return #vim.api.nvim_list_uis()'), 0, 'and no UI to see any refusal')

vim.fn.rpcnotify(chan, 'nvim_exec_lua', 'require("muxim.server").hand_off(...)', { server.self_path })

H.ok(vim.wait(5000, function() return #notified > 0 end, 50),
  'refusing to quit is reported to the session you handed off TO')
H.contains(notified[1] or '', 'still running', 'saying the old session is still there')
H.contains(notified[1] or '', 'unsaved changes', 'and why it would not go')
H.contains(notified[1] or '', 'handoff', 'naming the session, not just "this server"')
H.contains(notified[1] or '', '[No Name]', 'and the buffer holding it up')
H.ok(server.is_live(path), 'the session is still alive, as the message says')

local log = server.log_lines()
H.ok(#log > 0, 'the hand-off is written to the quit log, so an unreproducible case explains itself')
H.contains(table.concat(log, '\n'), 'hand_off', 'recording that a hand-off was attempted')
H.contains(table.concat(log, '\n'), 'refused', 'and that it was refused')
H.contains(table.concat(log, '\n'), '[No Name]', 'naming what refused it')

notified = {}
remote('vim.bo.modified = false')
vim.fn.rpcnotify(chan, 'nvim_exec_lua', 'require("muxim.server").hand_off(...)', { server.self_path })
H.ok(vim.wait(5000, function() return not server.is_live(path) end, 50),
  'with nothing unsaved the hand-off quits the old session')
H.eq(#notified, 0, 'and says nothing, because there is nothing to say')

H.contains(table.concat(server.log_lines(), '\n'), 'quitting',
  'and the successful quit is logged too, so silence is never ambiguous')

local blocked = runtime.socket('handoff-blocked')
H.ok(H.spawn_server(blocked, '.'), 'a second session, whose exit will block')
local ok_blocked, blocked_chan = pcall(vim.fn.sockconnect, 'pipe', blocked, { rpc = true })
H.ok(ok_blocked and blocked_chan > 0, 'connected to it')
local blocked_pid = vim.fn.rpcrequest(blocked_chan, 'nvim_exec_lua', 'return vim.uv.os_getpid()', {})
local function blocked_running() return vim.uv.kill(blocked_pid, 0) == 0 end
vim.fn.rpcrequest(blocked_chan, 'nvim_exec_lua', [[
  vim.api.nvim_create_autocmd('VimLeavePre', { callback = function() vim.fn.getchar() end })
]], {})

vim.fn.rpcnotify(blocked_chan, 'nvim_exec_lua',
  'vim.schedule(function() pcall(vim.cmd, "silent! qall!") end)', {})
H.eq(vim.wait(1500, function() return not blocked_running() end, 50), false,
  'qall! alone cannot end it: this is the real bug, an exit stranded waiting for input')

vim.fn.rpcnotify(blocked_chan, 'nvim_exec_lua', 'require("muxim.server").hand_off(...)',
  { server.self_path })
H.ok(vim.wait(8000, function() return not blocked_running() end, 100),
  'muxim takes the session down anyway, because nothing in it is unsaved')
H.contains(table.concat(server.log_lines(), '\n'), 'handoff-blocked',
  'and the log records what that session did, rather than it vanishing mysteriously')

local signals = {}
local real_kill, real_cmd = vim.uv.kill, vim.cmd
vim.uv.kill = function(pid, signal) signals[#signals + 1] = signal end
vim.cmd = function(command)
  if command == 'silent! qall!' then return end
  return real_cmd(command)
end
server.QUIT_GRACE = 30
server.quit_now(nil)
H.ok(vim.wait(3000, function() return #signals >= 2 end, 20),
  'a qall! that never exits escalates to signals instead of hanging forever')
H.eq(signals[1], 'sigterm', 'SIGTERM first, so VimLeave still runs')
H.eq(signals[2], 'sigkill', 'then SIGKILL, because a stuck session must not outlive you')
H.contains(table.concat(server.log_lines(), '\n'), 'quit_forced', 'and both are logged')
vim.uv.kill, vim.cmd = real_kill, real_cmd

vim.notify = real_notify
H.finish('handoff_spec')
