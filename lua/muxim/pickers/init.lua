local M = {}

M.backend = nil

local BACKENDS = {
  { name = 'telescope', plugin = 'telescope' },
}

local function resolve()
  if type(M.backend) == 'table' then
    return M.backend
  end
  if type(M.backend) == 'string' then
    local ok, backend = pcall(require, 'muxim.pickers.' .. M.backend)
    if ok then return backend end
    vim.notify(
      ("muxim: no picker backend '%s' (available: telescope, select)"):format(M.backend),
      vim.log.levels.ERROR)
    return require('muxim.pickers.select')
  end
  for _, entry in ipairs(BACKENDS) do
    if pcall(require, entry.plugin) then
      local ok, backend = pcall(require, 'muxim.pickers.' .. entry.name)
      if ok then return backend end
    end
  end
  return require('muxim.pickers.select')
end

local function call(name, ...)
  local backend = resolve()
  local fn = backend[name] or require('muxim.pickers.select')[name]
  return fn(...)
end

---@param dirs string[]?
function M.sessions(dirs) return call('sessions', dirs) end

function M.windows() return call('windows') end

return M
