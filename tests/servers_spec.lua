local H = dofile('tests/helper.lua')
local server = require('muxim.server')
local session = require('muxim.session')

H.ok(server.self_path ~= nil, 'test instance claimed a socket')

local scratch = H.runtime_dir() .. '/proj-a'
vim.fn.mkdir(scratch, 'p')
local sock = server.socket_for(scratch)
H.ok(H.spawn_server(sock, scratch), 'spawned scratch server is live')

local lines = H.lines(sock)
H.ok(type(lines) == 'table', 'remote session_lines returns lines')
H.contains(table.concat(lines or {}, '\n'), 'cwd', 'remote session preview includes cwd')

H.eq(table.concat(H.lines(H.runtime_dir() .. '/nope.sock') or {}, ''), 'not running', 'missing socket previews as not running')

local found = false
for _, s in ipairs(server.list()) do
  if s.path == sock then found = true end
end
H.ok(found, 'scratch server appears in list_servers')

local base = (server.self_path:match('^(.*)%.sock$'):gsub('%-%d+$', ''))
local before = {}
for _, f in ipairs(vim.fn.glob(base .. '*.sock', true, true)) do before[f] = true end
local suffix_job = vim.fn.jobstart(
  { vim.v.progpath, '--headless', '-u', H.minimal_init(), '-i', 'NONE' },
  { detach = true, cwd = vim.fn.getcwd(), env = { NVIM = '' } })
local suffix_pid = vim.fn.jobpid(suffix_job)
H.track_pid(suffix_pid)
local suffixed
H.ok(vim.wait(8000, function()
  for _, f in ipairs(vim.fn.glob(base .. '*.sock', true, true)) do
    if not before[f] and server.is_live(f) then
      suffixed = f
      return true
    end
  end
end, 100), 'second instance in same dir claims suffixed socket')

H.ok(require('muxim.server').socket_for(vim.fn.expand('~/source/api'))
  ~= require('muxim.server').socket_for(vim.fn.expand('~/.config/api')),
  'same basename in different dirs gets different sockets')

local summary = session.summary()
H.contains(summary, 'cwd', 'self session_summary includes cwd')
H.contains(summary, 'tab 1', 'self session_summary lists tabs')

vim.system({ vim.v.progpath, '--server', sock, '--remote-expr', 'execute("terminal")' }, { text = true, timeout = 2000 }):wait()
server.kill(sock, true)
H.ok(vim.wait(3000, function() return not server.is_live(sock) end, 50),
  'forced kill closes server with running terminal (nothing muxim does on TermClose may block an exit)')

H.kill(suffixed)
pcall(vim.uv.kill, suffix_pid, 15)
H.ok(H.wait_pid_gone(suffix_pid, 3000), 'suffix test process exited (no leak)')
vim.env.MUXIM_TERM = '99'
server.ensure_named()
H.eq(vim.env.MUXIM_TERM, nil,
  'claiming a socket clears any inherited MUXIM_TERM: a buffer number from another '
  .. 'session would make this one report against the wrong terminal')

local stale = require('muxim.runtime').socket('stale-test')
vim.fn.writefile({}, stale)
H.ok(vim.uv.fs_stat(stale) ~= nil, 'stale socket file planted')
local listed_stale = false
for _, entry in ipairs(server.list()) do
  if entry.path == stale then listed_stale = true end
end
H.ok(vim.uv.fs_stat(stale) ~= nil,
  'list() leaves it alone: listing must never delete, because a session mid-exit '
  .. 'refuses connections while it is still alive')
H.eq(listed_stale, false, 'and does not report it as live either')
H.ok(server.gc() >= 1, 'gc() reports the planted stale socket removed')
H.eq(vim.uv.fs_stat(stale), nil, 'gc() is the only thing that deletes')

H.finish('servers_spec')
