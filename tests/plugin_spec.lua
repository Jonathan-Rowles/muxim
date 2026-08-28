local H = dofile('tests/helper.lua')
local muxim = require('muxim')
local server = require('muxim.server')
local runtime = require('muxim.runtime')

H.ok(vim.g.loaded_muxim, 'plugin file was sourced at startup')
H.ok(muxim.setup_called, 'setup() records that it was called')

vim.api.nvim_exec_autocmds('VimEnter', { group = 'muxim_default_setup' })
H.eq(require('muxim.keys').prefix, '<C-a>',
  'firing the VimEnter hook for real changes nothing after an explicit setup()')

local real_has = vim.fn.has
vim.fn.has = function(feature)
  if feature == 'nvim-0.12' then return 0 end
  return real_has(feature)
end
vim.g.loaded_muxim = nil
pcall(vim.api.nvim_del_augroup_by_name, 'muxim_default_setup')
dofile('plugin/muxim.lua')
vim.fn.has = real_has
H.ok(vim.g.loaded_muxim, 'an old nvim still marks the plugin file loaded')
H.eq(pcall(vim.api.nvim_get_autocmds, { group = 'muxim_default_setup' }), false,
  'an old nvim registers no auto-setup hook, so installs stay silent there')
vim.g.loaded_muxim = nil
dofile('plugin/muxim.lua')

local root = vim.fn.fnamemodify(H.minimal_init(), ':h:h')
local init = H.runtime_dir() .. '/no-setup-init.lua'
local f = assert(io.open(init, 'w'))
f:write(([[
vim.o.swapfile = false
vim.o.shell = '/bin/sh'
vim.opt.rtp:prepend('%s')
require('muxim.agents').SWEEP_MS = false
]]):format(root))
f:close()

local path = runtime.socket('plugin-default-setup')
H.ok(H.spawn_server(path, nil, init), 'a session whose config never calls setup() is live')

local enabled = vim.wait(8000, function()
  return server.remote_expr(path, [[luaeval("require'muxim'.enabled and 1 or 0")]]) == '1'
end, 100)
H.ok(enabled, 'the plugin file ran setup() itself at VimEnter')
H.eq(server.remote_expr(path, [[luaeval("require'muxim.keys'.prefix")]]), '<C-b>',
  'the automatic setup bound the default prefix')

H.eq(server.remote_expr(path, [[luaeval("require'muxim'.adopt_foreign_terminals and 1 or 0")]]), '0',
  'an install that never chose terminal management does not claim foreign terminals')
H.eq(server.remote_expr(path, [[luaeval("require'muxim'.keep_busy_terminals and 1 or 0")]]), '1',
  'and its reaping spares terminals with a running job')
H.eq(server.remote_expr(path,
  [[luaeval("(function() vim.cmd('terminal') return require'muxim.terminal'.is_managed(vim.api.nvim_get_current_buf()) and 1 or 0 end)()")]],
  5000), '0', 'so a raw :terminal there stays unmanaged')

H.eq(server.remote_expr(path,
  [[luaeval("(function() return require'muxim'.setup({ prefix = '<C-a>' }) and 1 or 0 end)()")]],
  5000), '1', 'a setup() call after the automatic one still succeeds')
H.eq(server.remote_expr(path, [[luaeval("require'muxim.keys'.prefix")]]), '<C-a>',
  'the late call rebinds the prefix')
local count_bare_prefix =
  [[luaeval("(function() local n = 0 for _, m in ipairs(vim.api.nvim_get_keymap('n')) do if m.desc == 'muxim prefix' then n = n + 1 end end return n end)()")]]
H.eq(server.remote_expr(path, count_bare_prefix), '1',
  'one bare-prefix mapping survives the automatic setup plus the late one')

H.eq(server.remote_expr(path,
  [[luaeval("(function() return require'muxim'.setup({ keys = false, tabline = false }) and 1 or 0 end)()")]],
  5000), '1', 'setup() accepts keys = false and tabline = false after the automatic run')
H.eq(server.remote_expr(path, count_bare_prefix), '0',
  'keys = false tears down what the automatic setup bound')
H.eq(server.remote_expr(path, [[luaeval("require'muxim.keys'.prefix == nil and 1 or 0")]]), '1',
  'keys = false clears the recorded prefix')
H.eq(server.remote_expr(path, [[luaeval("vim.o.tabline == '' and 1 or 0")]]), '1',
  'tabline = false removes the tabline expression')
H.eq(server.remote_expr(path, [[luaeval("vim.o.showtabline")]]), '1',
  'tabline = false restores the showtabline the automatic setup changed')

H.eq(server.remote_expr(path,
  [[luaeval("(function() vim.g.loaded_muxim = nil require'muxim'.setup_called = false dofile('plugin/muxim.lua') return 1 end)()")]],
  5000), '1', 'the plugin file can be sourced again after startup')
local rebound = vim.wait(8000, function()
  return server.remote_expr(path, [[luaeval("require'muxim.keys'.prefix")]]) == '<C-b>'
end, 100)
H.ok(rebound, 'sourced after VimEnter with no setup() call, the scheduled branch runs setup itself')

H.ok(H.kill(path), 'the child session shut down')
os.remove(init)

H.finish('plugin_spec')
