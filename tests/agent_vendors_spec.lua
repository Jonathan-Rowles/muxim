local H = dofile('tests/helper.lua')
local agents = require('muxim.agents')
local commands = require('muxim.commands')
local claude = require('muxim.agents.claude')

require('muxim').setup({})

H.eq(agents.vendor('claude'), claude, 'claude resolves through the registry rather than by name')
H.eq(agents.vendor('zsh'), nil,
  'and a shell does not, so a terminal running zsh is never treated as an agent muxim can install for')
H.eq(agents.vendor('claude').title, 'Claude Code', 'a vendor carries a human title')

local real_vendors = agents.VENDORS
local ensure_calls = 0
package.loaded['muxim.agents.terminalonly'] = {
  name = 'terminalonly',
  title = 'Signals Through The Terminal',
  env = function() return { MUXIM_TERMINALONLY = 'yes' } end,
  shell_init = function() return 'terminalonly() { command terminalonly "$@"; }' end,
  ensure = function() ensure_calls = ensure_calls + 1 end,
  health = function(health) health.info('terminalonly needs no setup at all') end,
}
agents.VENDORS = { 'claude', 'terminalonly', 'never-written' }

H.eq(#agents.vendors(), 2,
  'a vendor named in the registry with no module behind it is skipped rather than erroring, '
  .. 'so a half-finished vendor cannot take the whole feature down')

local env = agents.env(vim.api.nvim_get_current_buf())
H.eq(env.MUXIM_TERMINALONLY, 'yes', 'each vendor adds its own variables to a managed terminal')
H.contains(env.MUXIM_CLAUDE_PLUGIN or '', 'claude-plugin',
  "and claude's is one of them rather than a hardcoded line in agents.lua")
H.contains(env.MUXIM_SERVER or '', H.runtime_dir(), 'while the generic ones are still there')

H.contains(agents.shell_init(), 'terminalonly() {',
  'the shell init is composed from the vendors, so adding a vendor adds its wrapper')
H.contains(agents.shell_init(), 'command claude --plugin-dir "$MUXIM_CLAUDE_PLUGIN"',
  'and claude keeps the wrapper it already had')

local sessions = { {
  current = true,
  agents = {
    { name = 'claude', state = 'running', wired = false },
    { name = 'terminalonly', state = 'running', wired = false },
    { name = 'zsh', state = 'running', wired = false },
  },
} }
local unwired = agents.unwired(sessions)
H.eq(#unwired, 1, 'only a vendor that HAS an install is ever offered one')
H.eq(unwired[1].name, 'claude',
  'a vendor that signals through the terminal is never nagged about a settings file it does not have')

local notified
local real_notify = vim.notify
vim.notify = function(msg) notified = msg end

commands.register()
vim.cmd('MuximAgentSetup terminalonly')
H.contains(notified or '', 'has nothing to install',
  'and :MuximAgentSetup names that rather than failing, which is the whole point of the registry')
vim.cmd('MuximAgentSetup! terminalonly')
H.contains(notified or '', 'has nothing to remove',
  'and the bang form says REMOVE, rather than offering to install what you asked it to take away')

vim.env.CLAUDE_CONFIG_DIR = H.runtime_dir() .. '/claude-config'
vim.fn.mkdir(vim.env.CLAUDE_CONFIG_DIR, 'p', tonumber('700', 8))
vim.cmd('MuximAgentSetup claude')
H.contains(notified or '', claude.settings_path(), 'a vendor argument targets that vendor alone')
H.eq(claude.installed(), true, 'and really installs it')
vim.cmd('MuximAgentSetup! claude')
H.eq(claude.installed(), false, 'the bang form removes the same one')

vim.cmd('MuximAgentSetup ' .. vim.env.CLAUDE_CONFIG_DIR)
H.eq(claude.installed(), true,
  'a first argument that is not a vendor name is still a config dir, so the habit that '
  .. 'shipped before the registry keeps working')

local second = H.runtime_dir() .. '/claude-second'
vim.fn.mkdir(second, 'p', tonumber('700', 8))
agents.setup({ claude = { config_dirs = { second } } })
vim.cmd('MuximAgentSetup!')
vim.cmd('MuximAgentSetup')
H.eq(claude.installed(), true, 'a bare :MuximAgentSetup installs into the default account')
H.eq(claude.installed(second), true,
  'AND into every other account muxim knows about. checkhealth warns about all of them '
  .. 'and the drawer offer installs into all of them, so the command that is supposed to '
  .. 'clear that warning has to cover the same set: Jon ran it for his second account and '
  .. 'watched it write to the first')
vim.cmd('MuximAgentSetup!')
H.eq(claude.installed(second), false, 'and the bang form removes them from everywhere too')
agents.setup({})
vim.cmd('MuximAgentSetup')

vim.cmd('MuximAgent terminalonly')
H.contains(notified or '', 'cannot start an agent for you',
  'a vendor with no launch says so rather than opening an empty terminal')

vim.cmd('checkhealth muxim')
local report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
H.contains(report, 'terminalonly needs no setup at all',
  'checkhealth asks each vendor for its own checks, so a new vendor is not a new edit to health.lua')
H.contains(report, 'Claude Code hooks installed in ' .. claude.settings_path(),
  "and claude's own checks moved with it, settings file and all")
H.contains(report, agents.hook_path(),
  'while the checks that are about muxim rather than a vendor stay in health.lua')

package.loaded['muxim.agents.halfvendor'] = {
  name = 'halfvendor',
  title = 'Installs But Cannot Uninstall',
  config_dirs = function() return { H.runtime_dir() .. '/half-config' } end,
  install = function() return true, 'half-config' end,
}
agents.VENDORS = { 'claude', 'terminalonly', 'halfvendor' }

local ok_bang = pcall(vim.cmd, 'MuximAgentSetup! halfvendor')
H.eq(ok_bang, true,
  'a vendor with an install but no uninstall does not throw on the bang form: every field '
  .. 'except name and title is documented optional, so muxim must not call one that is absent')
H.contains(notified or '', 'nothing to undo', 'it says so instead')

vim.cmd('MuximAgentSetup ' .. vim.env.CLAUDE_CONFIG_DIR)
H.contains(notified or '', 'belongs to one agent',
  'a config dir with no agent name is REFUSED once two agents install, rather than writing '
  .. "one agent's hooks into the other's settings file in the wrong format")
H.contains(notified or '', 'claude, halfvendor', 'and it names the agents you could have meant')

package.loaded['muxim.agents.bad_env'] = {
  name = 'bad_env',
  title = 'Returns Nothing And Wants Everything',
  env = function() return nil end,
}
package.loaded['muxim.agents.greedy'] = {
  name = 'greedy',
  title = 'Tries To Take The Socket',
  env = function() return { MUXIM_SERVER = '/nowhere', MUXIM_GREEDY = 'yes' } end,
}
agents.VENDORS = { 'claude', 'bad_env', 'greedy' }

local safe, env_now = pcall(agents.env, vim.api.nvim_get_current_buf())
H.eq(safe, true,
  'a vendor whose env() returns nothing cannot break opening EVERY muxim terminal, '
  .. 'not just its own')
H.eq(env_now.MUXIM_GREEDY, 'yes', 'a vendor still adds its own variables')
H.contains(env_now.MUXIM_SERVER or '', H.runtime_dir(),
  'but it cannot clobber the socket the hook reports to, which would silently disable '
  .. 'reporting for every agent in that terminal')

agents.VENDORS = { 'claude', 'terminalonly', 'never-written' }
ensure_calls = 0
agents.setup({})
H.eq(ensure_calls, 1, 'setup() gives every vendor its chance to write whatever it needs')

agents.setup({ claude = { config_dirs = { '~/second-account' } } })
H.eq(#claude.config_dirs(), 2, 'a configured second account is picked up by setup()')
agents.setup({})
H.eq(#claude.config_dirs(), 1,
  'and a later setup() WITHOUT it drops it again. This is deliberate: setup(opts) is '
  .. 'declarative, so :ConfigReload cannot leave a config dir behind that no config file '
  .. 'mentions any more. State that outlives the config that asked for it is the harder '
  .. 'bug to see')

agents.VENDORS = real_vendors
package.loaded['muxim.agents.terminalonly'] = nil
package.loaded['muxim.agents.halfvendor'] = nil
package.loaded['muxim.agents.bad_env'] = nil
package.loaded['muxim.agents.greedy'] = nil
vim.notify = real_notify

H.finish('agent_vendors_spec')
