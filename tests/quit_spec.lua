local H = dofile('tests/helper.lua')
local server = require('muxim.server')

local project = H.runtime_dir() .. '/quit-guard'
vim.fn.mkdir(project, 'p')
local sock = server.socket_for(project)
H.ok(H.spawn_server(sock, project), 'headless server for the quit guard is live')

H.eq(#server.modified_here(), 0, 'this instance has no unsaved buffers')

local dirty = ('luaeval("(function() vim.cmd(\'edit %s/draft.txt\') vim.api.nvim_buf_set_lines(0,0,-1,false,{\'unsaved\'}) return #require(\'muxim.server\').modified_here() end)()")')
  :format(project)
H.eq(server.remote_expr(sock, dirty), '1', 'the remote server reports its own unsaved buffer')

server.remote_expr(sock, 'luaeval("(function() require(\'muxim.server\').quit_when_detached(1) return 1 end)()")')
vim.wait(1500)
H.ok(server.is_live(sock), 'quit_when_detached refuses to quit with unsaved changes')

server.remote_expr(sock,
  'luaeval("(function() vim.bo.modified = false return 1 end)()")')
H.eq(server.remote_expr(sock, 'luaeval("#require(\'muxim.server\').modified_here()")'), '0',
  'the buffer is no longer modified')

server.remote_expr(sock, 'luaeval("(function() require(\'muxim.server\').quit_when_detached(1) return 1 end)()")')
H.ok(vim.wait(4000, function() return not server.is_live(sock) end, 50),
  'with nothing unsaved it quits')

local queried = H.runtime_dir() .. '/quit-after-query'
vim.fn.mkdir(queried, 'p')
local queried_sock = server.socket_for(queried)
H.ok(H.spawn_server(queried_sock, queried), 'a second server for the quit-after-query guard')
local clean = true
for _ = 1, 3 do
  if not server.is_live(queried_sock) then break end
  H.eq(#(server.modified_on(queried_sock) or {}), 0, 'it reports nothing unsaved')
  server.kill(queried_sock, false)
  if not vim.wait(3000, function() return not server.is_live(queried_sock) end, 50) then
    clean = false
    break
  end
  H.spawn_server(queried_sock, queried)
end
H.ok(clean,
  'a session that has answered a query still quits: scheduling work from an autocmd that '
  .. 'fires DURING the quit (BufWinEnter) swallows the quit entirely, and nothing says so')
H.ok(H.kill(queried_sock), 'and the guard server is gone')

H.finish('quit_spec')
