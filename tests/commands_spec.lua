local H = dofile('tests/helper.lua')

for _, cmd in ipairs({ 'MuximInfo', 'MuximSessions', 'MuximKeys', 'MuximClean', 'MuximAgents', 'MuximAgent', 'MuximAgentSetup', 'MuximTabRoot' }) do
  H.ok(vim.fn.exists(':' .. cmd) == 2, cmd .. ' registered')
end
H.eq(vim.fn.exists(':MuximAttach'), 0, 'MuximAttach is gone; the picker and resume.attach cover it')

H.ok(pcall(vim.cmd, 'MuximInfo'), 'Info runs')
H.ok(pcall(vim.cmd, 'MuximSessions'), 'Sessions runs')

local runtime = require('muxim.runtime')
local stale = runtime.socket('stale-clean-test')
local f = io.open(stale, 'w')
f:write('')
f:close()
H.ok(vim.uv.fs_stat(stale) ~= nil, 'stale socket file planted')
vim.cmd('MuximClean')
H.ok(vim.uv.fs_stat(stale) == nil, 'Clean removed the stale socket')

local claude = require('muxim.agents.claude')
vim.env.CLAUDE_CONFIG_DIR = H.runtime_dir() .. '/claude-config'
vim.fn.mkdir(vim.env.CLAUDE_CONFIG_DIR, 'p', tonumber('700', 8))

local ok, err = pcall(vim.cmd, 'checkhealth muxim')
H.ok(ok, 'checkhealth muxim runs: ' .. tostring(err))
local report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
H.ok(report:find('Runtime directory', 1, true) ~= nil, 'health report has runtime section')
H.ok(report:find('ERROR') == nil, 'health report has no errors: ' .. (report:match('[^\n]*ERROR[^\n]*') or ''))
H.ok(report:find('taken over', 1, true) == nil, 'health does not think the tabline was hijacked')
H.contains(report, 'tabline is muxim', 'health recognises muxim as the tabline owner')
H.contains(report, 'agents reporting here', 'health reports the agent watcher')
H.contains(report, 'no dead sockets in ' .. vim.env.XDG_RUNTIME_DIR, 'health scans for sockets outside the muxim directory')

local orphan = vim.env.XDG_RUNTIME_DIR .. '/nvim-orphan.sock'
local socket_file = io.open(orphan, 'w')
socket_file:write('')
socket_file:close()
vim.cmd('checkhealth muxim')
report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
H.contains(report, 'dead: ' .. orphan, 'a dead socket outside the muxim directory is reported')
H.ok(report:find('ERROR') == nil, 'and only as a warning')
vim.fn.delete(orphan)

local notified
local real_notify = vim.notify
vim.notify = function(msg) notified = msg end

vim.cmd('MuximAgentSetup')
H.contains(notified or '', claude.settings_path(), 'MuximAgentSetup says where it installed')
H.ok((notified or ''):find('nil', 1, true) == nil, 'and not "nil": ' .. tostring(notified))
H.eq(claude.installed(), true, 'and the hooks really are installed')

vim.cmd('MuximAgentSetup!')
H.contains(notified or '', 'removed from', 'the bang form says it removed them')
H.eq(claude.installed(), false, 'and they are gone')

local installs = 0
local real_install, real_uninstall = claude.install, claude.uninstall
claude.install = function() installs = installs + 1 return true, 'installed' end
claude.uninstall = function() return false, 'could not write it' end
vim.cmd('MuximAgentSetup!')
H.eq(installs, 0, 'a failing uninstall never falls through into installing')
H.contains(notified or '', 'could not write it', 'it reports the failure instead')
claude.install, claude.uninstall = real_install, real_uninstall

local settings_file = io.open(claude.settings_path(), 'w')
settings_file:write('{"hooks":{"SessionStart":[{"matcher":"startup|resume|fork","hooks":[{"type":"command",'
  .. '"command":"\'/Users/someone-else/.local/share/nvim/muxim/agent-hook\' idle \'\' claude"}]}]}}')
settings_file:close()
vim.cmd('checkhealth muxim')
report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
H.contains(report, '/Users/someone-else',
  'health names a hook installed on another machine, which is the failure that '
  .. 'produced silence rather than an error for a whole day')
H.contains(report, 'does not exist here', 'and says why it cannot work')

local agents = require('muxim.agents')
agents.write_hook()
local old_format = io.open(claude.settings_path(), 'w')
old_format:write(('{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"%s idle \'\'"}]}]}}')
  :format(agents.hook_path()))
old_format:close()
vim.cmd('checkhealth muxim')
report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
H.contains(report, 'not what muxim writes today',
  'an entry from an OLDER muxim, whose path does exist, is called out as stale '
  .. 'rather than as missing')
vim.fn.delete(claude.settings_path())

local agents_module = require('muxim.agents')
local real_watching = agents_module.watching_fleet
agents_module.watching_fleet = nil
vim.cmd('checkhealth muxim')
report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
H.contains(report, 'older muxim than the one on disk',
  'a session whose loaded muxim is older than health.lua says so, rather than throwing: '
  .. 'reloading only some modules is a normal state here, not an exception')
H.contains(report, 'Tabline',
  'and every LATER section still runs. One check that throws used to abort the whole '
  .. 'report, so a missing function hid everything after it')
agents_module.watching_fleet = real_watching

agents_module.watching_fleet = function() error('deliberately broken') end
vim.cmd('checkhealth muxim')
report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
H.contains(report, 'check itself failed',
  'a check that throws for any reason is reported as a muxim bug')
H.contains(report, 'Tabline', 'and still does not take the rest of the report with it')
agents_module.watching_fleet = real_watching

vim.notify = real_notify
H.finish('commands_spec')
