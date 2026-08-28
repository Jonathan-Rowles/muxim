local H = dofile('tests/helper.lua')
local server = require('muxim.server')

local project = H.runtime_dir() .. '/spawn-project'
vim.fn.mkdir(project, 'p')

local ticks = 0
local heartbeat = vim.uv.new_timer()
heartbeat:start(1, 1, function() ticks = ticks + 1 end)

local init = H.minimal_init()
local started = vim.uv.hrtime()
local result
server.spawn_async(project, function(path, err) result = { path = path, err = err } end, { init = init })
local returned_after = (vim.uv.hrtime() - started) / 1e6
H.ok(returned_after < 100, ('spawn_async returns immediately (%.1fms)'):format(returned_after))

H.ok(vim.wait(15000, function() return result ~= nil end, 20), 'spawn completed')
heartbeat:stop()
H.ok(ticks > 0, 'event loop kept running while the server spawned')
H.ok(result.path ~= nil, 'spawn produced a socket: ' .. tostring(result.err))
H.ok(server.is_live(result.path), 'spawned server is live')
H.eq(server.remote_expr(result.path, 'luaeval("require(\'muxim\').enabled")'), 'true',
  'readiness means the child finished setup(), not just that the socket bound')
H.track_pid(vim.fn.trim(vim.fn.system('pgrep -f -- "--listen ' .. result.path .. '"')))
H.eq(server.remote_expr(result.path, 'luaeval("vim.env.MUXIM_TERM == nil or vim.env.MUXIM_TERM == \'\'")'), 'true',
  'a spawned session does not inherit the spawning terminal\'s MUXIM_TERM, which would '
  .. 'make its agents report against a buffer number that means something else there')

local failure
server.spawn_async(H.runtime_dir() .. '/no-such-project', function(path, err)
  failure = { path = path, err = err }
end, { timeout = 1000, init = init })
H.ok(vim.wait(8000, function() return failure ~= nil end, 20), 'failing spawn reports back')
H.eq(failure.path, nil, 'failed spawn yields no socket')
H.ok(failure.err ~= nil and failure.err ~= '', 'failure carries a reason: ' .. tostring(failure.err))

H.ok(server.speaks_nvim(result.path), 'a real server answers the identity probe')

local impostor = require('muxim.runtime').socket('impostor')
local listener = vim.uv.new_pipe(false)
listener:bind(impostor)
listener:listen(4, function() end)
H.ok(server.is_live(impostor), 'a bare socket passes the connect test')
local probe_started = vim.uv.hrtime()
H.eq(server.speaks_nvim(impostor), false, 'but fails the identity probe')
H.eq(server.connect(impostor), false, 'connect refuses a peer that does not speak nvim')
H.eq(server.modified_on(impostor), nil, 'modified_on gives up instead of hanging')
H.ok((vim.uv.hrtime() - probe_started) / 1e6 < 6000, 'all three probes were deadline-bounded')
listener:close()
vim.fn.delete(impostor)

local killed_at = vim.uv.hrtime()
local gone
server.kill(result.path, true)
server.on_gone(result.path, 4000, function(dead)
  gone = { dead = dead, ms = (vim.uv.hrtime() - killed_at) / 1e6 }
end)
H.ok(vim.wait(6000, function() return gone ~= nil end, 10), 'on_gone settled')
H.ok(gone.dead, 'kill actually killed the server (rpcnotify was flushed before close)')
H.ok(gone.ms < 2000, ('death detected by polling, not a deadline (%.0fms)'):format(gone.ms))

H.finish('spawn_spec')
