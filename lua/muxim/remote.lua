local M = {}

M.BLOCKING_SUFFIXES = {
  'COMMIT_EDITMSG', 'MERGE_MSG', 'TAG_EDITMSG', 'SQUASH_MSG',
  'git-rebase-todo', 'addp-hunk-edit.diff',
}

local CONFIG_FLAGS = { ['-u'] = true, ['-i'] = true }

function M.blocking_edit(path)
  if path:find('/.git/', 1, true) or path:sub(1, 5) == '.git/' then return true end
  for _, suffix in ipairs(M.BLOCKING_SUFFIXES) do
    if path:sub(-#suffix) == suffix then return true end
  end
  return false
end

function M.route_to_parent(parent)
  parent = parent or vim.env.NVIM
  if not parent or parent == '' then return false end
  local uis = vim.api.nvim_list_uis()
  if #uis ~= 1 or not (uis[1].stdin_tty and uis[1].stdout_tty) then
    return false
  end
  local argv = vim.v.argv
  local args = {}
  local index = 2
  while index <= #argv do
    local arg = argv[index]
    if CONFIG_FLAGS[arg] then
      index = index + 2
    elseif arg == '--embed' then
      index = index + 1
    elseif arg == '--' then
      for rest = index + 1, #argv do
        args[#args + 1] = argv[rest]
      end
      break
    elseif arg:sub(1, 1) == '-' or arg:sub(1, 1) == '+' then
      return false
    else
      args[#args + 1] = arg
      index = index + 1
    end
  end
  local server = require('muxim.server')
  local dirs, files = {}, {}
  for _, arg in ipairs(args) do
    local abs = (vim.fn.fnamemodify(arg, ':p'):gsub('(.)/$', '%1'))
    if M.blocking_edit(abs) then return false end
    if vim.fn.isdirectory(abs) == 1 then
      dirs[#dirs + 1] = abs
    else
      files[#files + 1] = abs
    end
  end
  local function parent_call(call)
    return server.remote_expr(parent,
      ("v:lua.require'muxim.remote'.%s"):format(call), 3000) ~= nil
  end
  for _, dir in ipairs(dirs) do
    if not parent_call(("open_dir('%s')"):format(dir:gsub("'", "''"))) then
      return false
    end
  end
  if #files > 0 then
    if not parent_call('prepare()') then return false end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].buftype == '' and vim.api.nvim_buf_get_name(buf) ~= '' then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    local forward = { vim.v.progpath, '--server', parent, '--remote' }
    vim.list_extend(forward, files)
    if vim.system(forward, { timeout = 3000 }):wait().code ~= 0 then
      pcall(vim.cmd, 'silent! argdo edit!')
      return false
    end
  elseif #dirs == 0 then
    if not parent_call('focus()') then return false end
  end
  vim.cmd('qall!')
  return true
end

local TRACKED = { [''] = true, acwrite = true, help = true }

local last = { buf = nil, name = nil }

function M.track(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if not TRACKED[vim.bo[buf].buftype] then return end
  last.buf = buf
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= '' then last.name = name end
end

function M.setup()
  vim.api.nvim_create_autocmd('BufEnter', {
    group = vim.api.nvim_create_augroup('muxim_remote', { clear = true }),
    callback = function(args) M.track(args.buf) end,
  })
  M.track(vim.api.nvim_get_current_buf())
end

function M.prepare()
  vim.cmd('stopinsert')
  return ''
end

function M.open_dir(path)
  vim.cmd('stopinsert')
  vim.cmd.edit(vim.fn.fnameescape(path))
  return ''
end

function M.show_last_buffer()
  if last.buf and vim.api.nvim_buf_is_valid(last.buf)
      and TRACKED[vim.bo[last.buf].buftype] then
    vim.api.nvim_set_current_buf(last.buf)
    return
  end
  if last.name and pcall(vim.cmd.edit, vim.fn.fnameescape(last.name)) then
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf)
        and vim.bo[buf].buflisted
        and vim.bo[buf].buftype == '' then
      vim.api.nvim_set_current_buf(buf)
      return
    end
  end
  vim.cmd.edit(vim.fn.fnameescape(vim.fn.getcwd()))
end

function M.focus()
  vim.cmd('stopinsert')
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == '' then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype ~= 'terminal' then
        vim.api.nvim_set_current_win(win)
        return ''
      end
    end
  end
  M.show_last_buffer()
  return ''
end

return M
