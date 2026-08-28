local H = dofile('tests/helper.lua')
local agents = require('muxim.agents')
local drawer = require('muxim.drawer')
local claude = require('muxim.agents.claude')
local terminal = require('muxim.terminal')

require('muxim').setup({})

local isolated = H.runtime_dir() .. '/claude-config'
vim.fn.mkdir(isolated, 'p', tonumber('700', 8))
vim.fn.writefile({ '{}' }, isolated .. '/settings.json')
vim.env.CLAUDE_CONFIG_DIR = isolated
H.eq(claude.installed(), false, 'a machine with nothing installed in the Claude settings')

local fake_bin = H.runtime_dir() .. '/bin'
vim.fn.mkdir(fake_bin, 'p', tonumber('700', 8))
vim.uv.fs_symlink(vim.fn.exepath('sh'), fake_bin .. '/claude')
local original_path = vim.env.PATH
vim.env.PATH = fake_bin .. ':' .. original_path
H.eq(vim.fn.exepath('claude'), fake_bin .. '/claude',
  'a binary literally named claude, because ps reports the EXECUTABLE name on both '
  .. 'macOS and Linux, so exec -a would not do. It is a symlink rather than a copy '
  .. 'because macOS kills a copy of a signed system binary, and it is found on PATH '
  .. 'rather than run by absolute path because ps truncates the name it reports to 16 '
  .. 'characters, which is how muxim starts an agent anyway. It runs "sleep 300; true" '
  .. 'rather than a bare sleep, because a shell EXECS a single command and would stop '
  .. 'being claude')

local function look()
  local sessions
  agents.fleet_view(function(found) sessions = found end)
  H.ok(vim.wait(10000, function() return sessions ~= nil end, 100), 'muxim looked at the fleet')
  return sessions
end

local function drawn(sessions)
  drawer.show(sessions)
  return table.concat(vim.api.nvim_buf_get_lines(drawer.buffer(), 0, -1, false), '\n')
end

local wired = terminal.open_in_tab(
  { 'claude', '-c', 'sleep 300; true', '--plugin-dir', claude.plugin_dir() })
drawer.open()
local seen = look()
H.eq(#agents.unwired(seen), 0,
  'an agent started THROUGH muxim needs no wiring: the plugin directory is right '
  .. 'there in its argv, so whether it is wired is a FACT to read, never a delay to '
  .. 'wait out')
H.contains(drawn(seen), 'no state reported yet', 'it is still listed as running')
H.eq(drawn(seen):find('wire it up', 1, true), nil, 'and nothing is offered')
drawer.close()
vim.api.nvim_buf_delete(wired, { force = true })
vim.cmd('tabfirst')

local unwired = terminal.open_in_tab({ 'claude', '-c', 'sleep 300; true' })
drawer.open()
seen = look()
H.eq(#agents.unwired(seen), 1, 'the same agent started WITHOUT muxim cannot report')
local offered = drawn(seen)
H.contains(offered, 'is running but not reporting', 'so the drawer says so')
H.contains(offered, '<CR> to wire it up', 'and offers the fallback where you are looking')

for line = 1, vim.api.nvim_buf_line_count(drawer.buffer()) do
  local text = vim.api.nvim_buf_get_lines(drawer.buffer(), line - 1, line, false)[1]
  if text:find('wire it up', 1, true) then
    vim.api.nvim_win_set_cursor(drawer.window(), { line, 0 })
  end
end
drawer.select()
H.eq(claude.installed(), true,
  'selecting that row installs the fallback, so the only manual step left is offered '
  .. 'at the moment it has value rather than asked for up front')
H.eq(drawn(seen):find('wire it up', 1, true), nil, 'and the offer goes away once it is done')

drawer.close()
vim.api.nvim_buf_delete(unwired, { force = true })
vim.env.CLAUDE_CONFIG_DIR = nil
vim.env.PATH = original_path

H.finish('agent_offer_spec')
