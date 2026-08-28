local H = dofile('tests/helper.lua')
local actions = require('muxim.actions')
local server = require('muxim.server')

local function result_of(entry, force)
  local settled
  actions.kill(entry, force, function(ok, err) settled = { ok = ok, err = err } end)
  vim.wait(8000, function() return settled ~= nil end, 20)
  return settled or {}
end

local guarded = result_of({ path = server.self_path, name = 'self' }, true)
H.eq(guarded.ok, false, 'refuses to kill the server you are attached to')
H.contains(guarded.err, 'attached to', 'and says why')
H.ok(server.is_live(server.self_path), 'the current server survived the attempt')

H.eq(result_of({ current = true, path = '/nope', name = 'x' }, false).ok, false,
  'a current entry is refused before any socket work')

local clean = H.runtime_dir() .. '/kill-clean'
vim.fn.mkdir(clean, 'p')
local clean_sock = server.socket_for(clean)
H.ok(H.spawn_server(clean_sock, clean), 'clean scratch server is live')
H.eq(#server.modified_on(clean_sock), 0, 'a clean server reports no unsaved buffers')
H.eq(result_of({ path = clean_sock, name = 'clean' }, false).ok, true, 'a clean server is killed')
H.ok(not server.is_live(clean_sock), 'and it is really gone')

local dirty = H.runtime_dir() .. '/kill-dirty'
vim.fn.mkdir(dirty, 'p')
local dirty_sock = server.socket_for(dirty)
H.ok(H.spawn_server(dirty_sock, dirty), 'dirty scratch server is live')
server.remote_expr(dirty_sock,
  ('luaeval("(function() vim.cmd(\'edit %s/notes.txt\') vim.api.nvim_buf_set_lines(0,0,-1,false,{\'x\'}) return 1 end)()")'):format(dirty))
local unsaved = server.modified_on(dirty_sock)
H.eq(#unsaved, 1, 'modified_on reports one unsaved buffer')
H.ok(unsaved[1]:match('notes%.txt$') ~= nil, 'and names it: ' .. tostring(unsaved[1]))

local blocked = result_of({ path = dirty_sock, name = 'dirty' }, false)
H.eq(blocked.ok, false, 'a server with unsaved changes is not killed without force')
H.contains(blocked.err, 'unsaved buffer', 'the failure names the unsaved work')
H.contains(blocked.err, 'force-quits', 'and tells you how to force it')
H.ok(server.is_live(dirty_sock), 'the dirty server is still running')

local real_modified_on = server.modified_on
server.modified_on = function() return nil end
local asked
local saved_confirm = vim.fn.confirm
vim.fn.confirm = function(prompt) asked = prompt return 2 end
local unknown = result_of({ path = dirty_sock, name = 'dirty' }, true)
server.modified_on = real_modified_on
vim.fn.confirm = saved_confirm
H.ok(asked ~= nil,
  'a force-kill that cannot CHECK for unsaved changes still prompts: a timed-out '
  .. 'check once read as "nothing unsaved" and skipped straight to qall!')
H.contains(asked or '', 'did not answer', 'saying the check failed, not that the session is clean')
H.eq(unknown.ok, false, 'declining the unknown-state prompt leaves it alive')
H.ok(server.is_live(dirty_sock), 'and it is')

local answered
local real_confirm = vim.fn.confirm
vim.fn.confirm = function() answered = true return 2 end
local declined = result_of({ path = dirty_sock, name = 'dirty' }, true)
H.ok(answered, 'force on a dirty server prompts before discarding')
H.eq(declined.ok, false, 'declining the prompt leaves it alive')
H.ok(server.is_live(dirty_sock), 'and it really is alive')

vim.fn.confirm = function() return 1 end
H.eq(result_of({ path = dirty_sock, name = 'dirty' }, true).ok, true, 'accepting the prompt force-kills it')
H.ok(not server.is_live(dirty_sock), 'the dirty server is gone')

vim.fn.confirm = real_confirm
H.finish('actions_spec')
