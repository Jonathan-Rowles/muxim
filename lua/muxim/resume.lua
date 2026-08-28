local M = {}

local function state_file()
  return require('muxim.runtime').state_file('nvim-last-server')
end

function M.record(path)
  local target = state_file()
  local tmp = target .. '.tmp'
  local f = io.open(tmp, 'w')
  if not f then return false end
  local ok = f:write(path) and f:close()
  if not ok then
    os.remove(tmp)
    return false
  end
  if not vim.uv.fs_rename(tmp, target) then
    os.remove(tmp)
    return false
  end
  return true
end

function M.last()
  local f = io.open(state_file(), 'r')
  if not f then return nil end
  local path = vim.trim(f:read('*a') or '')
  f:close()
  if path == '' then return nil end
  return path
end

function M.attach(path)
  local server = require('muxim.server')
  if vim.g.muxim_nested then
    vim.notify('muxim: refusing to attach from a nested instance', vim.log.levels.WARN)
    return false
  end
  local explicit = path ~= nil and path ~= ''
  path = explicit and path or M.last()
  if path and path ~= server.self_path and server.is_live(path) then
    return server.connect(path)
  end
  if explicit or (path and path == server.self_path) then
    return false
  end
  local candidates = {}
  for _, entry in ipairs(server.list()) do
    if not entry.current then
      candidates[#candidates + 1] = entry.path
    end
  end
  if #candidates == 1 and server.speaks_nvim(candidates[1]) then
    return server.connect(candidates[1])
  end
  return false
end

return M
