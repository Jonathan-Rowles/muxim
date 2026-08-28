local H = dofile('tests/helper.lua')
local resume = require('muxim.resume')

local state_file = require('muxim.runtime').state_file('nvim-last-server')

os.remove(state_file)
H.eq(resume.last(), nil, 'last() nil when no state file')

resume.record('/tmp/some.sock')
H.eq(resume.last(), '/tmp/some.sock', 'record/last roundtrip')

resume.record('/tmp/other.sock')
H.eq(resume.last(), '/tmp/other.sock', 'record overwrites previous')

local server = require('muxim.server')
H.ok(server.self_path ~= nil, 'ensure_named set self_path for this instance')
H.eq(resume.last() ~= nil, true, 'state file present after records')

H.eq(resume.record('/tmp/atomic-check.sock'), true, 'record reports success')
H.eq(resume.last(), '/tmp/atomic-check.sock', 'record round-trips through the rename')
H.eq(vim.uv.fs_stat(state_file .. '.tmp'), nil, 'no temp file left behind')

resume.record(H.runtime_dir() .. '/cross-process.sock')
local child = vim.system({
  vim.v.progpath, '--headless', '-u', H.minimal_init(), '-i', 'NONE',
  '+lua io.write(require("muxim.resume").last() or "")', '+q',
}, { text = true }):wait()
H.eq(vim.trim(child.stdout or ''), H.runtime_dir() .. '/cross-process.sock',
  'another process reads back the same last-server record')

local runtime = require('muxim.runtime')
local connected = {}
local real_connect = server.connect
server.connect = function(path)
  connected[#connected + 1] = path
  return true
end

resume.record(runtime.socket('stomped-by-a-commit-editor'))
local only_live = runtime.socket('resume-fallback-one')
H.ok(H.spawn_server(only_live), 'one live server besides this session')
H.eq(resume.attach(), true, 'attach falls back when the recorded socket is dead')
H.eq(connected[#connected], only_live, 'and picks the only live session')

connected = {}
resume.record(server.self_path)
H.eq(resume.attach(), false,
  'a record pointing at THIS session is the steady state, not a dead record: bare attach keeps opening the picker')
H.eq(#connected, 0, 'and connects to nothing')

resume.record(runtime.socket('stomped-by-a-commit-editor'))
server.connect = function() return false end
H.eq(resume.attach(), false, 'a fallback candidate that refuses the connect propagates the failure')
server.connect = function(path)
  connected[#connected + 1] = path
  return true
end

local second_live = runtime.socket('resume-fallback-two')
H.ok(H.spawn_server(second_live), 'a second live server')
connected = {}
H.eq(resume.attach(), false, 'with several live sessions the fallback refuses to guess')
H.eq(#connected, 0, 'and connects to nothing')

H.eq(resume.attach(runtime.socket('explicitly-asked-for-but-dead')), false,
  'an explicit dead path never falls back to another session')
H.eq(#connected, 0, 'explicit means explicit')

H.ok(H.kill(only_live), 'first scratch server shut down')
H.ok(H.kill(second_live), 'second scratch server shut down')

local impostor = runtime.socket('resume-impostor')
local listener = vim.uv.new_pipe(false)
listener:bind(impostor)
listener:listen(4, function() end)
connected = {}
H.eq(resume.attach(), false, 'a lone socket that does not speak nvim is skipped, not attached to')
H.eq(#connected, 0, 'no connect attempt, so no error toast for a path the user never typed')
listener:close()
vim.fn.delete(impostor)

server.connect = real_connect

os.remove(state_file)
H.finish('resume_spec')
