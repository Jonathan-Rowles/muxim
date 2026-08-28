local M = {}

M.PREFIX = 'muxim-'

M.SUN_PATH_MAX = vim.uv.os_uname().sysname == 'Linux' and 108 or 104
local SOCKET_SUFFIX = '.sock'

M.override_dir = nil

local resolved_dir = nil

local used_fallback = false

function M.is_fallback_dir()
  M.dir()
  return used_fallback
end

local function base_dir()
  local xdg = vim.env.XDG_RUNTIME_DIR
  if xdg and xdg ~= '' then
    return xdg .. '/muxim'
  end
  if vim.fn.has('win32') == 1 then
    return vim.fn.stdpath('run') .. '/muxim'
  end
  used_fallback = true
  return '/tmp/muxim-' .. vim.uv.getuid()
end

local function ensure(dir)
  local stat = vim.uv.fs_lstat(dir)
  if stat then
    if stat.type ~= 'directory' then
      error(('muxim: %s exists and is not a directory'):format(dir))
    end
    if stat.uid ~= vim.uv.getuid() then
      error(('muxim: %s is not owned by you'):format(dir))
    end
  else
    vim.fn.mkdir(dir, 'p', tonumber('700', 8))
  end
  return dir
end

function M.dir()
  if M.override_dir then
    return ensure(M.override_dir)
  end
  if not resolved_dir then
    local dir = base_dir()
    if dir:find('\n', 1, true) then
      error('muxim: runtime directory path contains a newline')
    end
    resolved_dir = ensure(dir)
  end
  return resolved_dir
end

function M.reset()
  resolved_dir = nil
end

function M.name_budget()
  return M.SUN_PATH_MAX - #M.dir() - 1 - #M.PREFIX - #SOCKET_SUFFIX - 1
end

function M.socket(name)
  local budget = M.name_budget()
  if budget < 8 then
    error(('muxim: runtime directory path is too long for a socket (%s)'):format(M.dir()))
  end
  if #name > budget then
    name = name:sub(1, budget)
  end
  return M.dir() .. '/' .. M.PREFIX .. name .. SOCKET_SUFFIX
end

function M.sockets()
  local paths = {}
  local ok, iter = pcall(vim.fs.dir, M.dir())
  if not ok then return paths end
  for entry, kind in iter do
    if kind ~= 'directory' and entry:sub(1, #M.PREFIX) == M.PREFIX and entry:sub(-#SOCKET_SUFFIX) == SOCKET_SUFFIX then
      paths[#paths + 1] = M.dir() .. '/' .. entry
    end
  end
  table.sort(paths)
  return paths
end

function M.name_from_socket(path)
  local base = vim.fn.fnamemodify(path, ':t')
  return (base:sub(#M.PREFIX + 1, -(#SOCKET_SUFFIX + 1)))
end

function M.display_name(path)
  local name = M.name_from_socket(path)
  return name:match('^%x%x%x%x%x%x%-(.+)$') or name
end

function M.state_file(name)
  return M.dir() .. '/' .. name
end

return M
