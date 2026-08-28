local M = {}

local function server_label(entry)
  local name = require('muxim.runtime').display_name(entry.path)
  return name .. (entry.current and '  (attached)' or '') .. '\n    ' .. entry.path
end

local function info()
  local runtime = require('muxim.runtime')
  local server = require('muxim.server')
  local keys = require('muxim.keys')
  local lines = { 'muxim' }
  local attached = server.self_path
  if not attached then
    attached = vim.g.muxim_nested and 'none (nested instance)' or 'none (no socket claimed)'
  end
  lines[#lines + 1] = '  attached to: ' .. attached
  local ok, dir = pcall(runtime.dir)
  lines[#lines + 1] = '  runtime dir: ' .. (ok and dir or ('ERROR: ' .. dir))
  lines[#lines + 1] = '  prefix:      ' .. (keys.prefix or 'none (keys disabled)')
  lines[#lines + 1] = '  nested:      ' .. tostring(vim.g.muxim_nested == true)
  lines[#lines + 1] = '  $MUXIM_SERVER: ' .. (vim.env.MUXIM_SERVER or 'unset')
  local live = server.list()
  lines[#lines + 1] = ('  sessions (%d live):'):format(#live)
  for _, entry in ipairs(live) do
    lines[#lines + 1] = '  - ' .. server_label(entry)
  end
  print(table.concat(lines, '\n'))
end

local function sessions()
  local live = require('muxim.server').list()
  if #live == 0 then
    print('muxim: no live sessions')
    return
  end
  local lines = {}
  for _, entry in ipairs(live) do
    lines[#lines + 1] = '  ' .. server_label(entry)
  end
  print(table.concat(lines, '\n'))
end

local function clean()
  local removed = require('muxim.server').gc()
  print(('muxim: removed %d stale socket%s'):format(removed, removed == 1 and '' or 's'))
end

local function split_vendor(fargs)
  local agents = require('muxim.agents')
  local rest = vim.list_slice(fargs)
  local name
  if rest[1] and agents.vendor(rest[1]) then
    name = table.remove(rest, 1)
  end
  return name, rest
end

local function installing_vendors(name)
  local chosen = {}
  for _, vendor in ipairs(require('muxim.agents').vendors()) do
    if vendor.install and (not name or vendor.name == name) then
      chosen[#chosen + 1] = vendor
    end
  end
  return chosen
end

local function agent_setup(opts)
  local name, rest = split_vendor(opts.fargs)
  local dir = rest[1] and vim.fn.expand(rest[1]) or nil
  local chosen = installing_vendors(name)
  local verb = opts.bang and 'remove' or 'install'
  if #chosen == 0 then
    vim.notify(('muxim: %s has nothing to %s, it reports as soon as muxim starts it')
      :format(name or 'no agent muxim knows about', verb))
    return
  end
  if dir and not name and #chosen > 1 then
    local names = {}
    for _, vendor in ipairs(chosen) do names[#names + 1] = vendor.name end
    vim.notify(('muxim: %s belongs to one agent, but %s all install. Name one: '
      .. ':MuximAgentSetup%s <agent> %s'):format(
      dir, table.concat(names, ', '), opts.bang and '!' or '', rest[1]), vim.log.levels.ERROR)
    return
  end
  local written = {}
  for _, vendor in ipairs(chosen) do
    local act = vendor.install
    if opts.bang then
      act = vendor.uninstall
    end
    if act then
      local targets = { false }
      if dir then
        targets = { dir }
      elseif vendor.config_dirs then
        targets = vendor.config_dirs()
      end
      for _, target in ipairs(targets) do
        local ok, detail = act(target or nil)
        if not ok then
          vim.notify('muxim: ' .. tostring(detail), vim.log.levels.ERROR)
          return
        end
        written[#written + 1] = detail
      end
    end
  end
  if #written == 0 then
    vim.notify(('muxim: %s cannot %s its hooks, so there is nothing to undo')
      :format(name or 'that agent', verb))
    return
  end
  vim.notify(('muxim: agent hooks %s %s'):format(
    opts.bang and 'removed from' or 'installed into', table.concat(written, ', ')))
end

local function argument_index(line, lead)
  local before = line:sub(1, #line - #lead)
  local index = 0
  for _ in before:gmatch('%S+') do index = index + 1 end
  return index
end

local function agent_setup_complete(lead, line)
  local names = {}
  if argument_index(line, lead) <= 1 then
    for _, vendor in ipairs(installing_vendors()) do
      if vendor.name:find(lead, 1, true) == 1 then
        names[#names + 1] = vendor.name
      end
    end
  end
  return vim.list_extend(names, vim.fn.getcompletion(lead, 'dir'))
end

local function vendor_complete(lead)
  local names = {}
  for _, vendor in ipairs(require('muxim.agents').vendors()) do
    if vendor.launch and vendor.name:find(lead, 1, true) == 1 then
      names[#names + 1] = vendor.name
    end
  end
  return names
end

local function agent_start(opts)
  local agents = require('muxim.agents')
  local name, rest = split_vendor(opts.fargs)
  local default = name or agents.VENDORS[1]
  local vendor = agents.vendor(default)
  if not vendor or not vendor.launch then
    vim.notify('muxim: ' .. tostring(default) .. ' cannot start an agent for you',
      vim.log.levels.ERROR)
    return
  end
  local argv, why = vendor.launch(rest)
  if not argv then
    vim.notify('muxim: ' .. tostring(why), vim.log.levels.ERROR)
    return
  end
  require('muxim.terminal').open_in_tab(argv)
  require('muxim.terminal').start_insert()
end

local function agent_list()
  require('muxim.drawer').toggle()
end

local function tab_root(opts)
  local root = require('muxim.root')
  if opts.args ~= '' then
    root.set(opts.args)
  elseif not root.follow() then
    return
  end
  vim.notify('muxim: tab root ' .. vim.fn.fnamemodify(root.get(), ':~'))
  require('muxim.tabline').refresh()
end

function M.register()
  local command = vim.api.nvim_create_user_command
  command('MuximInfo', info, { desc = 'muxim state: attachment, sockets, prefix' })
  command('MuximSessions', sessions, { desc = 'List live muxim sessions' })
  command('MuximKeys', function() require('muxim.keys').help() end,
    { desc = 'Show muxim key bindings' })
  command('MuximClean', clean, { desc = 'Delete stale muxim sockets' })
  command('MuximAgentSetup', agent_setup,
    { bang = true, nargs = '*', complete = agent_setup_complete,
      desc = 'Install muxim agent hooks for an agent, into a config dir (! removes them)' })
  command('MuximAgent', agent_start,
    { nargs = '*', complete = vendor_complete,
      desc = 'Open a tab running an agent already wired to report to muxim' })
  command('MuximAgents', agent_list,
    { desc = 'Toggle the drawer: every session, with its agents' })
  command('MuximTabRoot', tab_root,
    { nargs = '?', complete = 'dir', desc = "Set this tab's root (the focused terminal's cwd if no dir)" })
end

return M
