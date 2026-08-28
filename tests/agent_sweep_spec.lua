local H = dofile('tests/helper.lua')
local agents = require('muxim.agents')
local terminal = require('muxim.terminal')

local function run_sweep()
  agents.SWEEP_MS = 0
  local finished, swept
  agents.sweep(function(result) finished, swept = true, result end)
  vim.wait(5000, function() return finished end, 50)
  agents.SWEEP_MS = false
  return swept
end

local ghost_buf = terminal.open_in_tab('sleep 300')
H.ok(vim.wait(3000, function() return vim.b[ghost_buf].terminal_job_pid ~= nil end, 50),
  'a terminal with a live job')

agents.SWEEP_MS = 3600000
H.eq(agents.sweep(), false, 'nothing reported: no sweep, and the window is NOT consumed')
agents.SWEEP_MS = false
agents.report(ghost_buf, 'blocked', 'wants to use Bash', 'claude')
agents.SWEEP_MS = 3600000
H.eq(agents.sweep(), true,
  'the first real sweep runs even on a machine booted seconds ago: the throttle keys off '
  .. 'a never-swept sentinel, not the boot-origin hrtime zero')
H.eq(agents.sweep(), false,
  'a second within SWEEP_MS is throttled: publish fires on every tab switch and ps is not free')
agents.SWEEP_MS = false

H.eq(run_sweep(), false,
  'a claude the scan has NEVER seen is not swept: an npm claude is comm=node to ps, and '
  .. 'scan blindness must stay fail-safe instead of killing a healthy agent every pass')
H.eq(agents.state(ghost_buf).state, 'blocked', 'so its report stands')

agents.COMMANDS.cat = true
agents.COMMANDS.sleep = true
local buf = terminal.open_in_tab('cat; sleep 300')
H.ok(vim.wait(3000, function() return vim.b[buf].terminal_job_pid ~= nil end, 50),
  'a terminal whose first process the scan recognises (cat, standing in for an agent binary)')
local agent_pid
H.ok(vim.wait(3000, function()
  agent_pid = tonumber(vim.fn.system({
    'pgrep', '-P', tostring(vim.b[buf].terminal_job_pid), '-x', 'cat' }))
  return agent_pid ~= nil
end, 100), 'and that process is up under the shell')

agents.report(buf, 'blocked', 'wants to use Bash', 'cat', 'cat-sess')
H.eq(run_sweep(), false, 'an agent whose process the scan can see is left alone')
H.eq(agents.state(buf).state, 'blocked', 'and keeps reporting')

vim.uv.kill(agent_pid, 'sigkill')
H.ok(H.wait_pid_gone(agent_pid),
  'the agent process is SIGKILLed behind the shell, which fires no hook')
agents.report(buf, 'working', '', 'sleep', 'sleep-sess')
H.eq(run_sweep(), true, 'the sweep notices: the agent this scan once SAW here is gone')
H.eq(agents.state(buf).state, 'working',
  'and it swept BY NAME: the dead agent went, the live one beside it stayed')

agents.report(buf, 'blocked', 'input needed', 'mystery-agent', 'mystery-sess')
H.eq(run_sweep(), false,
  'an agent the scan cannot even recognise is NEVER swept: hooks may report vendors the '
  .. 'process scan does not know, and sweeping those would end every one of them')
H.eq(agents.state(buf).state, 'blocked', 'so it keeps its reported state')
agents.report(buf, 'ended', '', 'mystery-agent', 'mystery-sess')

agents.report(buf, 'blocked', 'ghost', 'cat', 'cat-sess')
local real_ps = agents.PS_ARGV
agents.PS_ARGV = { 'sh', '-c', 'echo "  1     0 01:00 fake fake"; exit 1' }
H.eq(run_sweep(), false,
  'a failed ps with partial stdout sweeps NOTHING: the exit code is checked, not just '
  .. 'whether anything parsed, so a truncated tree cannot end live agents')
H.eq(agents.state(buf).state, 'blocked', 'the report survives the bad scan')
agents.PS_ARGV = real_ps
H.eq(run_sweep(), true, 'and the next good scan sweeps the ghost')

agents.SWEEP_MS = 0
local finished, swept
agents.sweep(function(result) finished, swept = true, result end)
agents.SWEEP_MS = false
agents.report(buf, 'blocked', 'ghost', 'cat', 'cat-sess')
H.ok(vim.wait(5000, function() return finished end, 50), 'the in-flight sweep completes')
H.eq(swept, false,
  'a report that lands after a scan started is never judged by that stale snapshot')
H.eq(agents.state(buf).state, 'blocked', 'the young entry survives')
H.eq(run_sweep(), true, 'and only a scan started after it may sweep it')

agents.SWEEP_MS = 0
agents.report(buf, 'blocked', 'ghost', 'cat', 'cat-sess')
H.ok(vim.wait(5000, function() return (agents.state(buf) or {}).state == 'working' end, 50),
  'the agent-state announcement that already fires on every report runs the sweep itself: '
  .. 'no new timer and no polling loop, per the standing ruling. It is deliberately NOT '
  .. 'driven by publish, whose BufWinEnter trigger fires during a quit, where spawning '
  .. 'async work cancels the quit silently, the exact regression quit_spec guards')
agents.SWEEP_MS = false

agents.COMMANDS.cat = nil
agents.COMMANDS.sleep = nil

H.finish('agent_sweep_spec')
