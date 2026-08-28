local H = { failed = 0, passed = 0 }

function H.eq(actual, expected, label)
  if actual == expected then
    H.passed = H.passed + 1
    print('  ok  ' .. label)
  else
    H.failed = H.failed + 1
    print(('FAIL  %s: expected %s, got %s'):format(label, vim.inspect(expected), vim.inspect(actual)))
  end
end

function H.ok(cond, label)
  H.eq(not not cond, true, label)
end

function H.contains(haystack, needle, label)
  H.ok(type(haystack) == 'string' and haystack:find(needle, 1, true) ~= nil, label)
end

function H.finish(name)
  print(('%s: %d passed, %d failed'):format(name, H.passed, H.failed))
  if H.failed > 0 then
    vim.cmd('cquit 1')
  else
    vim.cmd('qall!')
  end
end

function H.runtime_dir()
  return os.getenv('XDG_RUNTIME_DIR') or '/tmp'
end

function H.wait_live(path, ms)
  return vim.wait(ms or 8000, function()
    return require('muxim.server').is_live(path)
  end, 50)
end

function H.track_pid(pid)
  local f = io.open(H.runtime_dir() .. '/test-pids', 'a')
  if f then
    f:write(pid, '\n')
    f:close()
  end
end

function H.drain()
  local done = false
  vim.schedule(function() done = true end)
  vim.wait(2000, function() return done end, 10)
end

function H.pid_alive(pid)
  local number = tonumber(pid)
  if not number then
    error('pid_alive got a non-numeric pid: ' .. vim.inspect(pid))
  end
  local ok, result = pcall(vim.uv.kill, number, 0)
  return ok and result == 0
end

function H.wait_pid_gone(pid, ms)
  return vim.wait(ms or 2000, function() return not H.pid_alive(pid) end, 50)
end

function H.child_pid_of(pid, ms)
  local child
  vim.wait(ms or 5000, function()
    local out = vim.fn.trim(vim.fn.system('pgrep -P ' .. pid))
    child = vim.split(out, '\n')[1]
    return child ~= ''
  end, 50)
  return child
end

function H.minimal_init()
  return vim.fn.fnamemodify('tests/minimal_init.lua', ':p')
end

function H.spawn_server(path, dir, init)
  local job = vim.fn.jobstart({
    vim.v.progpath, '--headless', '-u', init or H.minimal_init(), '-i', 'NONE',
    '--listen', path, dir or '.',
  }, { detach = true, env = { NVIM = '' } })
  if job > 0 then
    H.track_pid(vim.fn.jobpid(job))
  end
  return H.wait_live(path)
end

function H.lines(target)
  local final
  require('muxim.session').lines_async(target, function(lines, done)
    if done then final = lines end
  end)
  vim.wait(3000, function() return final ~= nil end, 20)
  return final
end

function H.kill(path)
  local server = require('muxim.server')
  server.kill(path, true)
  return vim.wait(3000, function() return not server.is_live(path) end, 50)
end

return H
