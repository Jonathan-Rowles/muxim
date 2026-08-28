local M = {}

M.follow_terminal_cwd = false

function M.session()
  return vim.fn.getcwd(-1, -1)
end

function M.get(tab)
  tab = tab or 0
  local ok, dir = pcall(vim.fn.getcwd, -1, vim.api.nvim_tabpage_get_number(tab))
  if ok and dir ~= '' then
    return dir
  end
  return M.session()
end

function M.set(dir, tab)
  dir = vim.fn.fnamemodify(vim.fn.expand(dir), ':p'):gsub('(.)/$', '%1')
  if vim.fn.isdirectory(dir) == 0 then
    vim.notify('muxim: not a directory: ' .. dir, vim.log.levels.ERROR)
    return false
  end
  local function apply()
    vim.cmd('tcd ' .. vim.fn.fnameescape(dir))
  end
  if tab and tab ~= 0 and tab ~= vim.api.nvim_get_current_tabpage() then
    vim.api.nvim_win_call(vim.api.nvim_tabpage_get_win(tab), apply)
  else
    apply()
  end
  return true
end

local function process_cwd(pid)
  local link = vim.uv.fs_readlink('/proc/' .. pid .. '/cwd')
  if link then
    return link
  end
  if vim.fn.executable('lsof') ~= 1 then
    return nil
  end
  local result = vim.system({ 'lsof', '-a', '-d', 'cwd', '-p', tostring(pid), '-Fn' },
    { text = true, timeout = 1000 }):wait()
  if result.code ~= 0 then
    return nil
  end
  for line in (result.stdout or ''):gmatch('[^\n]+') do
    local path = line:match('^n(/.*)$')
    if path then
      return path
    end
  end
  return nil
end

function M.terminal_cwd(buf)
  buf = buf or require('muxim.terminal').current()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
  local reported = vim.b[buf].osc7_dir
  if reported and vim.fn.isdirectory(reported) == 1 then
    return reported
  end
  local pid = vim.b[buf].terminal_job_pid
  if not pid then return nil end
  local dir = process_cwd(pid)
  if dir and vim.fn.isdirectory(dir) == 1 then
    return dir
  end
  return nil
end

function M.follow(buf)
  local dir = M.terminal_cwd(buf)
  if not dir then
    vim.notify('muxim: could not determine the terminal directory', vim.log.levels.WARN)
    return false
  end
  return M.set(dir)
end

function M.label(tab)
  local root = M.get(tab)
  if root == M.session() then return nil end
  return vim.fn.fnamemodify(root, ':~')
end

function M.setup()
  vim.api.nvim_create_autocmd('TermRequest', {
    group = vim.api.nvim_create_augroup('muxim_osc7', { clear = true }),
    callback = function(args)
      local dir, found = string.gsub(args.data.sequence or '', '\027]7;file://[^/]*', '')
      if found == 0 then return end
      dir = dir:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
      if vim.fn.isdirectory(dir) == 0 then return end
      vim.b[args.buf].osc7_dir = dir
      if M.follow_terminal_cwd then
        vim.schedule(function()
          if vim.api.nvim_get_current_buf() == args.buf and vim.fn.isdirectory(dir) == 1 then
            M.set(dir)
          end
        end)
      end
    end,
  })
end

return M
