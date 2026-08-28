local H = dofile('tests/helper.lua')
local agents = require('muxim.agents')
local remote = require('muxim.remote')

H.ok(agents.write_wrapper(), 'write_wrapper writes the script')
H.ok(agents.wrapper_is_current(), 'wrapper_is_current sees the fresh script')

local wrapper = agents.wrapper_path()
local work = H.runtime_dir() .. '/wrapper-work'
vim.fn.mkdir(work .. '/sub', 'p')
vim.fn.mkdir(work .. '/fakebin', 'p')
work = vim.uv.fs_realpath(work)
local log = work .. '/calls.log'

local function write_stub(path)
  local file = io.open(path, 'w')
  file:write(('#!/bin/sh\n{ printf \'%%s\\n\' "$@"; echo ==; } >> %s\n'):format(log))
  file:close()
  vim.uv.fs_chmod(path, tonumber('700', 8))
end

local stub = work .. '/stub-nvim'
write_stub(stub)
write_stub(work .. '/fakebin/nvim')

local function calls()
  local file = io.open(log, 'r')
  if not file then return {} end
  local body = file:read('*a')
  file:close()
  os.remove(log)
  local out = {}
  for chunk in body:gmatch('(.-)\n==\n') do
    out[#out + 1] = vim.split(chunk, '\n')
  end
  return out
end

local function run(args, env)
  local full_env = vim.tbl_extend('force', { PATH = '/usr/bin:/bin' }, env or {})
  return vim.system(vim.list_extend({ '/bin/sh', wrapper }, args),
    { cwd = work, env = full_env, clear_env = true, timeout = 5000 }):wait()
end

run({ 'plain.txt' }, { MUXIM_NVIM = stub })
local c = calls()
H.eq(#c, 1, 'outside nvim the wrapper makes one call')
H.eq(c[1][1], 'plain.txt', 'outside nvim args pass through untouched')

run({ '--version' }, { NVIM = '/fake.sock', MUXIM_NVIM = stub })
c = calls()
H.eq(#c, 1, 'a flag makes one passthrough call')
H.eq(c[1][1], '--version', 'flags reach the real nvim unchanged')

run({ work .. '/.git/COMMIT_EDITMSG' }, { NVIM = '/fake.sock', MUXIM_NVIM = stub })
c = calls()
H.eq(#c, 1, 'a git editor file makes one call')
H.eq(c[1][1], work .. '/.git/COMMIT_EDITMSG', 'git editor files run the real blocking editor')

run({ '.git/config' }, { NVIM = '/fake.sock', MUXIM_NVIM = stub })
c = calls()
H.eq(#c, 1, 'a RELATIVE .git path makes one call: git config --edit invokes the editor '
  .. 'with ".git/config" from the toplevel, and */.git/* alone never matched it')
H.eq(c[1][1], '.git/config', 'and it runs the real blocking editor too')

io.open(work .. '/rel.txt', 'w'):close()
run({ 'rel.txt' }, { NVIM = '/fake.sock', MUXIM_NVIM = stub })
c = calls()
H.eq(#c, 2, 'a file routes as prepare then remote')
H.eq(c[1][2], '/fake.sock', 'prepare targets the parent socket')
H.contains(table.concat(c[1], ' '), 'muxim.remote\'.prepare', 'prepare goes over remote-expr')
H.eq(c[2][3], '--remote', 'the file goes over --remote')
H.eq(c[2][4], work .. '/rel.txt', 'a relative file is resolved against the terminal cwd')

run({ 'sub' }, { NVIM = '/fake.sock', MUXIM_NVIM = stub })
c = calls()
H.eq(#c, 1, 'a directory routes as one remote-expr')
H.contains(table.concat(c[1], ' '), 'open_dir(\'' .. work .. '/sub\')', 'a relative dir is resolved against the terminal cwd')

run({}, { NVIM = '/fake.sock', MUXIM_NVIM = stub })
c = calls()
H.eq(#c, 1, 'bare nvim makes one call')
H.contains(table.concat(c[1], ' '), 'muxim.remote\'.focus', 'bare nvim focuses the parent')

local bin_dir = agents.wrapper_dir()
local result = run({ 'loop.txt' }, { PATH = bin_dir .. ':' .. work .. '/fakebin:/usr/bin:/bin' })
c = calls()
H.eq(result.code, 0, 'passthrough without MUXIM_NVIM exits cleanly instead of looping')
H.eq(#c, 1, 'passthrough without MUXIM_NVIM finds the next nvim on PATH')
H.eq(c[1][1], 'loop.txt', 'the next nvim gets the original args')

local server = require('muxim.server')
local saved = server.self_path
server.self_path = '/tmp/fake-muxim.sock'
local env = agents.env(1)
server.self_path = saved
H.ok(env.PATH ~= nil, 'env carries a PATH once the wrapper exists')
H.eq(env.PATH:sub(1, #bin_dir + 1), bin_dir .. ':', 'env puts the wrapper dir first on PATH')
H.eq(env.MUXIM_NVIM, vim.v.progpath, 'env names the real nvim for the wrapper')
H.eq(env.MUXIM_BIN, bin_dir, 'env names the wrapper dir, so the shell init can put it back')

H.ok(agents.write_shell_init(), 'write_shell_init writes the rc file')
local rc_probe = work .. '/rc-probe.sh'
vim.fn.writefile({
  'PATH="' .. work .. '/fakebin:$PATH"',
  '. "$MUXIM_SHELL_INIT"',
  'command -v nvim',
}, rc_probe)
local function resolved_nvim(extra)
  local probe_env = vim.tbl_extend('force', {
    PATH = bin_dir .. ':/usr/bin:/bin',
    MUXIM_SHELL_INIT = agents.shell_init_path(),
  }, extra or {})
  local probe = vim.system({ '/bin/sh', rc_probe },
    { env = probe_env, clear_env = true, timeout = 5000 }):wait()
  return vim.trim(probe.stdout or '')
end
H.eq(resolved_nvim({ MUXIM_BIN = bin_dir, NVIM = '/fake.sock' }), bin_dir .. '/nvim',
  'the shell init puts the wrapper back in front after the rc rebuilt PATH: an rc '
  .. 'that prepends its own dirs buries the wrapper, and nvim typed in a muxim '
  .. 'terminal nests a whole new editor')
H.eq(resolved_nvim({}), work .. '/fakebin/nvim',
  'outside muxim the shell init leaves PATH alone')

local edited = work .. '/focus-target.txt'
vim.cmd('edit ' .. vim.fn.fnameescape(edited))
local file_buf = vim.api.nvim_get_current_buf()
local term = require('muxim.terminal').open()
vim.cmd('stopinsert')
H.eq(vim.api.nvim_get_current_buf(), term, 'the terminal starts focused')
remote.focus()
H.eq(vim.api.nvim_get_current_buf(), file_buf, 'focus returns to the last file buffer')

remote.open_dir(work)
H.contains(vim.api.nvim_buf_get_name(0), work, 'open_dir lands on the directory buffer')

local revived = work .. '/revive-me.txt'
io.open(revived, 'w'):close()
vim.cmd('only')
vim.cmd('edit ' .. vim.fn.fnameescape(revived))
local revive_buf = vim.api.nvim_get_current_buf()
require('muxim.terminal').open()
vim.cmd('stopinsert')
vim.cmd('bwipeout! ' .. revive_buf)
remote.focus()
H.contains(vim.api.nvim_buf_get_name(0), 'revive-me.txt',
  'focus revives the last buffer by name after it was wiped')

H.finish('remote_spec')
