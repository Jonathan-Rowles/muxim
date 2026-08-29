local M = {}

function M.write_atomic(path, body, mode)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p', tonumber('700', 8))
  local tmp = path .. '.muxim-tmp.' .. vim.uv.os_getpid()
  local file = io.open(tmp, 'w')
  if not file then return false end
  local ok = file:write(body) and file:close()
  if not ok then
    os.remove(tmp)
    return false
  end
  if mode then
    vim.uv.fs_chmod(tmp, mode)
  end
  if not vim.uv.fs_rename(tmp, path) then
    os.remove(tmp)
    return false
  end
  return true
end

function M.read(path)
  local file = io.open(path, 'r')
  if not file then return nil end
  local raw = file:read('*a')
  file:close()
  return raw
end

function M.matches(path, body)
  local raw = M.read(path)
  return raw ~= nil and raw == body
end

return M
