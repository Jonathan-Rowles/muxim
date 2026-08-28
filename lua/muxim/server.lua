local runtime = require('muxim.runtime')

local M = {}

M.self_path = nil

function M.nested()
  local parent = vim.env.NVIM
  return parent ~= nil and parent ~= ''
end

function M.name_for(dir)
  dir = vim.fn.fnamemodify(dir, ':p'):gsub('/$', '')
  dir = vim.uv.fs_realpath(dir) or dir
  local base = (vim.fn.fnamemodify(dir, ':t'):gsub('[^%w_-]', '_'))
  local digest = vim.fn.sha256(dir):sub(1, 6)
  return base == '' and digest or (digest .. '-' .. base)
end

function M.socket_for(dir)
  return runtime.socket(M.name_for(dir))
end

function M.is_live(path)
  local ok, chan = pcall(vim.fn.sockconnect, 'pipe', path, { rpc = true })
  if ok and chan and chan > 0 then
    pcall(vim.fn.chanclose, chan)
    return true
  end
  return false
end

local function deliver_detached(path, method, params)
  local pipe = vim.uv.new_pipe(false)
  local request = vim.mpack.encode({ 0, 0, method, params })
  pipe:connect(path, function(err)
    if err then
      pipe:close()
      return
    end
    pipe:read_start(function()
      if not pipe:is_closing() then pipe:close() end
    end)
    pipe:write(request)
  end)
end

local function i_own(path)
  for _, addr in ipairs(vim.fn.serverlist()) do
    if addr == path then return true end
  end
  return false
end

function M.list()
  local servers = {}
  for _, path in ipairs(runtime.sockets()) do
    if M.is_live(path) then
      servers[#servers + 1] = {
        name = runtime.name_from_socket(path),
        path = path,
        current = (path == M.self_path),
      }
    end
  end
  table.sort(servers, function(a, b) return a.name < b.name end)
  return servers
end

function M.stale()
  local stale = {}
  for _, path in ipairs(runtime.sockets()) do
    if not M.is_live(path) then
      stale[#stale + 1] = path
    end
  end
  return stale
end

function M.gc()
  local removed = 0
  for _, path in ipairs(M.stale()) do
    if vim.fn.delete(path) == 0 then
      removed = removed + 1
    end
  end
  return removed
end

function M.remote_expr(path, expr, timeout)
  local result = vim.system(
    { vim.v.progpath, '--server', path, '--remote-expr', expr },
    { text = true, timeout = timeout or 1000 }):wait()
  if result.code ~= 0 then return nil end
  return (result.stdout or ''):gsub('\n$', '')
end

function M.speaks_nvim(path)
  return M.remote_expr(path, '1') == '1'
end

function M.connect(path)
  local answer = M.remote_expr(path, '1')
  if answer == nil then
    vim.notify('muxim: ' .. path .. ' did not answer in time, not attaching', vim.log.levels.ERROR)
    return false
  end
  if answer ~= '1' then
    vim.notify('muxim: ' .. path .. ' is not an nvim server, refusing to attach', vim.log.levels.ERROR)
    return false
  end
  require('muxim.resume').record(path)
  vim.cmd('connect ' .. vim.fn.fnameescape(path))
  return true
end

function M.ensure_named()
  local function claim(path)
    M.self_path = path
    vim.env.MUXIM_SERVER = path
    vim.env.MUXIM_TERM = nil
    return true
  end
  for _, addr in ipairs(vim.fn.serverlist()) do
    if addr:match('/' .. vim.pesc(runtime.PREFIX) .. '[^/]+%.sock$') then
      return claim(addr)
    end
  end
  local base = M.name_for(vim.fn.getcwd())
  for n = 1, 20 do
    local path = runtime.socket(n == 1 and base or (base .. '-' .. n))
    if i_own(path) or pcall(vim.fn.serverstart, path) then
      return claim(path)
    end
    if vim.uv.fs_stat(path) and not M.is_live(path) then
      vim.fn.delete(path)
      if pcall(vim.fn.serverstart, path) then
        return claim(path)
      end
    end
  end
  vim.notify('muxim: could not claim a server socket in ' .. runtime.dir(), vim.log.levels.ERROR)
  return false
end

local pending = {}
local next_token = 0

function M.announce(token, path)
  local waiting = pending[token]
  if not waiting then return end
  pending[token] = nil
  waiting(path)
end

function M.forget_parent()
  local parent, token = vim.env.MUXIM_PARENT, vim.env.MUXIM_TOKEN
  if parent == nil and token == nil then
    parent, token = vim.g.muxim_parent, vim.g.muxim_parent_token
  end
  vim.env.MUXIM_PARENT, vim.env.MUXIM_TOKEN = nil, nil
  vim.g.muxim_parent, vim.g.muxim_parent_token = parent, token
  return parent, token
end

function M.announce_to_parent()
  local parent, token = M.forget_parent()
  if not (parent and parent ~= '' and token and token ~= '' and M.self_path) then
    return false
  end
  if not M.is_live(parent) then return false end
  deliver_detached(parent, 'nvim_exec_lua',
    { 'require("muxim.server").announce(...)', { token, M.self_path } })
  vim.g.muxim_parent, vim.g.muxim_parent_token = nil, nil
  return true
end

function M.spawn_async(dir, callback, opts)
  opts = opts or {}
  local timeout = opts.timeout or 30000
  local path = M.socket_for(dir)
  if vim.uv.fs_stat(path) then vim.fn.delete(path) end

  next_token = next_token + 1
  local token = tostring(next_token) .. '-' .. tostring(vim.uv.now())
  local argv = { vim.v.progpath, '--headless' }
  if opts.init then
    vim.list_extend(argv, { '-u', opts.init, '-i', 'NONE' })
  end
  vim.list_extend(argv, { '--listen', path, dir })

  local stderr = {}
  local function why()
    local reason = vim.trim(table.concat(stderr, ' '))
    return reason ~= '' and reason or nil
  end

  local deadline = vim.uv.new_timer()
  local settled = false
  local job

  local function finish(result, err)
    if settled then return end
    settled = true
    pending[token] = nil
    if not deadline:is_closing() then
      deadline:stop()
      deadline:close()
    end
    if result then
      vim.api.nvim_exec_autocmds('User', {
        pattern = 'MuximServerSpawn',
        data = { path = result, dir = dir },
      })
    end
    callback(result, err)
  end

  local ok_job
  ok_job, job = pcall(vim.fn.jobstart, argv, {
    detach = true,
    cwd = dir,
    env = {
      NVIM = '', MUXIM_TERM = '', MUXIM_HOOK = '',
      MUXIM_PARENT = M.self_path or '', MUXIM_TOKEN = token,
    },
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= '' then stderr[#stderr + 1] = line end
      end
    end,
    on_exit = function(_, code)
      if vim.uv.fs_stat(path) then vim.fn.delete(path) end
      finish(nil, why() or ('nvim exited with code ' .. code))
    end,
  })
  if not ok_job then
    return finish(nil, tostring(job))
  end
  if job <= 0 then
    return finish(nil, 'could not start ' .. vim.v.progpath)
  end

  pending[token] = function(announced)
    finish(announced or path)
  end

  deadline:start(timeout, 0, vim.schedule_wrap(function()
    pcall(vim.fn.jobstop, job)
    if vim.uv.fs_stat(path) then vim.fn.delete(path) end
    finish(nil, why() or ('no readiness signal after ' .. (timeout / 1000) .. 's'))
  end))
end

function M.open(dir, callback)
  callback = callback or function() end
  if not dir or dir == '' then
    callback(false, 'no directory given')
    return false
  end
  dir = vim.fn.fnamemodify(dir, ':p'):gsub('/$', '')
  local path = M.socket_for(dir)
  local name = M.name_for(dir)

  if M.self_path and path == M.self_path then
    vim.notify('Already in project: ' .. name)
    callback(true)
    return true
  end
  local function attach(target)
    local ok, err = pcall(M.connect, target)
    if not ok then
      vim.notify('muxim: could not attach to ' .. name .. ': ' .. tostring(err), vim.log.levels.ERROR)
    end
    callback(ok, not ok and tostring(err) or nil)
    return ok
  end

  if M.is_live(path) then
    return attach(path)
  end

  vim.notify('muxim: starting ' .. name .. '...')
  M.spawn_async(dir, function(spawned, err)
    if not spawned then
      vim.notify('muxim: could not start ' .. name .. ': ' .. (err or 'unknown error'), vim.log.levels.ERROR)
      return callback(false, err)
    end
    attach(spawned)
  end)
  return true
end

local MODIFIED_QUERY = [[
  local names = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      names[#names + 1] = name ~= '' and vim.fn.fnamemodify(name, ':~:.') or '[No Name]'
    end
  end
  return names
]]

function M.modified_here()
  return load(MODIFIED_QUERY)()
end

function M.modified_on(path)
  local expr = ('luaeval("(function() %s end)()")'):format(MODIFIED_QUERY:gsub('%s+', ' '))
  local result = M.remote_expr(path, 'join(' .. expr .. ", \"\\n\")")
  if not result then return nil end
  return result == '' and {} or vim.split(result, '\n')
end

function M.kill(path, force)
  deliver_detached(path, 'nvim_command', { force and 'qall!' or 'qall' })
end

function M.on_gone(path, timeout, callback)
  if not M.is_live(path) then
    return callback(true)
  end
  local poll = vim.uv.new_timer()
  local deadline = vim.uv.new_timer()
  local settled = false
  local function done(dead)
    if settled then return end
    settled = true
    for _, handle in ipairs({ poll, deadline }) do
      if not handle:is_closing() then
        handle:stop()
        handle:close()
      end
    end
    callback(dead)
  end
  poll:start(100, 100, vim.schedule_wrap(function()
    if not M.is_live(path) then done(true) end
  end))
  deadline:start(timeout, 0, vim.schedule_wrap(function()
    done(not M.is_live(path))
  end))
end

function M.tell(path, message)
  deliver_detached(path, 'nvim_exec_lua',
    { 'vim.notify((...), vim.log.levels.WARN)', { message } })
end

function M.self_name()
  return M.self_path and runtime.display_name(M.self_path) or 'this session'
end

function M.log(event, detail)
  local ok, dir = pcall(runtime.dir)
  if not ok then return false end
  local file = io.open(dir .. '/quit.log', 'a')
  if not file then return false end
  file:write(('%s  %s  %s  %s\n'):format(
    os.date('%Y-%m-%d %H:%M:%S'), M.self_name(), event, detail or ''))
  file:close()
  return true
end

function M.log_lines()
  local ok, dir = pcall(runtime.dir)
  if not ok then return {} end
  local file = io.open(dir .. '/quit.log', 'r')
  if not file then return {} end
  local lines = {}
  for line in file:lines() do
    lines[#lines + 1] = line
  end
  file:close()
  return lines
end

local function refuse(message, target)
  M.log('refused', message)
  if target then
    M.tell(target, 'muxim: ' .. message)
  end
  if #vim.api.nvim_list_uis() > 0 then
    vim.notify('muxim: ' .. message, vim.log.levels.WARN)
  end
end

M.QUIT_GRACE = 3000

function M.quit_now(target)
  M.log('quitting', 'no UI attached, nothing unsaved')
  vim.schedule(function() pcall(vim.cmd, 'silent! qall!') end)
  vim.defer_fn(function()
    if #vim.api.nvim_list_uis() > 0 then
      M.log('quit_abandoned', 'a UI attached again before the quit took effect')
      return
    end
    if #M.modified_here() > 0 then
      refuse(('%s is still running, unsaved changes appeared while quitting'):format(
        M.self_name()), target)
      return
    end
    M.log('quit_forced', 'qall! did not exit (a stranded prompt blocks it); terminating')
    vim.uv.kill(vim.uv.os_getpid(), 'sigterm')
    vim.defer_fn(function()
      M.log('quit_killed', 'SIGTERM did not exit either; SIGKILL')
      vim.uv.kill(vim.uv.os_getpid(), 'sigkill')
    end, M.QUIT_GRACE)
  end, M.QUIT_GRACE)
end

function M.quit_when_detached(tries, target)
  tries = tries or 100
  if #vim.api.nvim_list_uis() == 0 then
    local modified = M.modified_here()
    if #modified > 0 then
      refuse(('%s is still running, unsaved changes in %s'):format(
        M.self_name(), table.concat(modified, ', ')), target)
      return
    end
    M.quit_now(target)
    return
  end
  if tries <= 0 then
    refuse(('%s is still running: its UI never detached'):format(M.self_name()), target)
    return
  end
  vim.defer_fn(function() M.quit_when_detached(tries - 1, target) end, 50)
end

function M.hand_off(path, command)
  M.log('hand_off', 'to ' .. path .. (command and (', running ' .. command) or ''))
  if command then
    deliver_detached(path, 'nvim_command', { command })
  end
  M.quit_when_detached(nil, path)
end

return M
