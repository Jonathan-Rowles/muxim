local H = dofile('tests/helper.lua')
local muxim = require('muxim')
local server = require('muxim.server')

H.ok(muxim.enabled, 'setup from minimal_init enabled the plugin')
H.ok(server.self_path ~= nil, 'setup claimed a socket')
H.ok(server.is_live(server.self_path), 'claimed socket is live')
H.eq(vim.env.MUXIM_SERVER, server.self_path, 'MUXIM_SERVER exported for child processes')

H.eq(muxim.setup({ prefix = '<C-a>' }), true, 'second setup returns true')
local function count_desc(mode, desc)
  local n = 0
  for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
    if map.desc == desc then n = n + 1 end
  end
  return n
end
H.eq(count_desc('n', 'muxim prefix'), 1, 'one bare-prefix mapping in normal mode after re-setup')
H.eq(count_desc('t', 'muxim prefix'), 1, 'one bare-prefix mapping in terminal mode after re-setup')
H.eq(count_desc('n', 'send prefix'), 1, 'one send-prefix mapping after re-setup')

H.eq(muxim.setup({ prefix = '<C-a>', keys = true, tabline = true }), true,
  'keys = true and tabline = true mean the defaults, not a crash: teardown on false '
  .. 'makes true the natural re-enable gesture')
H.eq(count_desc('n', 'muxim prefix'), 1, 'and the prefix is bound')

local saved_nvim = vim.env.NVIM
vim.env.NVIM = '/tmp/fake-parent.sock'
local live = require('muxim.runtime').socket('nested-attach-test')
H.ok(H.spawn_server(live), 'scratch server for the attach guard is live')
vim.env.MUXIM_PARENT, vim.env.MUXIM_TOKEN = live, 'race-token'
H.eq(muxim.setup({}), false, 'setup refuses inside a nested nvim')
H.eq(vim.g.muxim_nested, true, 'nested flag set for consumers')
H.eq(vim.env.MUXIM_PARENT, nil, 'the refusal consumed the parent env so children cannot inherit it')
local stashed_parent, stashed_token = server.forget_parent()
H.eq(stashed_parent, live, 'but a later setup still learns the parent: losing the auto-setup race does not eat it')
H.eq(stashed_token, 'race-token', 'and the token survives with it')
H.eq(require('muxim.resume').attach(live), false, 'attach refuses a live socket while nested')
H.eq(muxim.setup({ nested = true, prefix = '<C-a>', tabline = false }), true, 'nested = true overrides the guard')
H.eq(vim.g.muxim_nested, nil, 'successful setup clears the nested flag')
H.eq(server.forget_parent(), nil, 'the successful announce consumed the stash so reloads do not re-announce')

vim.env.MUXIM_PARENT, vim.env.MUXIM_TOKEN = require('muxim.runtime').socket('no-such-parent'), 'retry-token'
H.eq(server.announce_to_parent(), false, 'announcing to a dead parent fails')
local kept_parent, kept_token = server.forget_parent()
H.eq(kept_token, 'retry-token', 'and the failure keeps the pair for the next attempt')
H.eq(vim.g.muxim_parent, kept_parent, 'the stash lives in vim.g, so a module reload cannot eat it')

vim.g.muxim_parent, vim.g.muxim_parent_token = '/tmp/stale-parent.sock', 'stale-token'
vim.env.MUXIM_PARENT = require('muxim.runtime').socket('fresh-parent')
local _, mixed_token = server.forget_parent()
H.eq(mixed_token, nil, 'an env parent with no env token never borrows a stale stashed token')
vim.g.muxim_parent, vim.g.muxim_parent_token = nil, nil
vim.env.NVIM = saved_nvim
muxim.setup({ prefix = '<C-a>' })
H.kill(live)

H.finish('setup_spec')
