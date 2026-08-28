local M = {}

M.MANAGED = 'muxim_managed'

M.enter_insert = false

M.on_terminal_hide = nil

local pending_managed = false

local managed_bufs = {}

function M.mark_managed(buf)
  managed_bufs[buf] = true
  vim.b[buf][M.MANAGED] = true
end

function M.claim_pending(buf)
  if pending_managed then
    pending_managed = false
    M.mark_managed(buf)
    return true
  end
  return M.is_managed(buf)
end

function M.is_managed(buf)
  if managed_bufs[buf] then return true end
  if vim.api.nvim_buf_is_valid(buf) and vim.b[buf][M.MANAGED] == true then
    managed_bufs[buf] = true
    return true
  end
  return false
end

function M.is_terminal(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == 'terminal'
end

function M.register(buf)
  vim.t.muxim_terminal = buf
end

function M.registered()
  local buf = vim.t.muxim_terminal
  return M.is_terminal(buf) and buf or nil
end

function M.window_in_tab()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == 'terminal' then
      return win, buf
    end
  end
  return nil, nil
end

function M.current()
  local buf = M.registered()
  if buf then return buf end
  local _, visible = M.window_in_tab()
  return visible
end

function M.job_is_running(buf)
  local job = vim.b[buf].terminal_job_id
  if not job then return false end
  return vim.fn.jobwait({ job }, 0)[1] == -1
end

function M.pid(buf)
  buf = buf or M.current()
  return buf and vim.b[buf].terminal_job_pid or nil
end

function M.label(buf)
  local cmd = vim.api.nvim_buf_get_name(buf):match('^term://.-//%d+:(.*)')
  if cmd and cmd ~= '' then
    return vim.fn.fnamemodify(vim.split(cmd, ' ')[1], ':t')
  end
  return nil
end

function M.open(cmd)
  vim.cmd('enew')
  local buf = vim.api.nvim_get_current_buf()
  pending_managed = true
  local ok_env, env = pcall(require('muxim.agents').env, buf)
  local ok, job = pcall(vim.fn.jobstart, cmd or { vim.o.shell },
    { term = true, env = ok_env and env or nil })
  pending_managed = false
  if not ok or job <= 0 then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    error('muxim: could not start terminal job', 0)
  end
  vim.b[buf].muxim_agent_env = ok_env and env ~= nil
  vim.bo[buf].swapfile = false
  M.mark_managed(buf)
  M.register(buf)
  return buf
end

function M.open_in_tab(cmd)
  local root = require('muxim.root').get()
  vim.cmd('$tabnew')
  require('muxim.root').set(root)
  return M.open(cmd)
end

function M.focus(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_set_current_win(win)
      return
    end
  end
  vim.api.nvim_set_current_buf(buf)
end

function M.ensure()
  local buf = M.current()
  if buf then
    M.register(buf)
    if vim.api.nvim_get_current_buf() ~= buf then
      M.focus(buf)
    end
    return buf
  end
  if vim.bo[vim.api.nvim_get_current_buf()].buftype == 'terminal' then
    vim.cmd('split')
  end
  return M.open()
end

local function hide_terminal(buf)
  local alt = vim.fn.bufnr('#')
  if alt > 0 and alt ~= buf and vim.api.nvim_buf_is_valid(alt) and not M.is_terminal(alt) then
    vim.api.nvim_set_current_buf(alt)
    return true
  end
  if M.on_terminal_hide then
    M.on_terminal_hide(buf)
    return true
  end
  require('muxim.remote').show_last_buffer()
  return true
end

function M.toggle()
  local current = vim.api.nvim_get_current_buf()
  if M.is_terminal(current) then
    M.register(current)
    vim.cmd('stopinsert')
    hide_terminal(current)
    return nil
  end

  local win, visible = M.window_in_tab()
  if win then
    M.register(visible)
    vim.api.nvim_set_current_win(win)
    M.start_insert()
    return visible
  end

  local buf = M.registered() or M.hidden_for_tab() or M.orphaned()
  if buf then
    M.register(buf)
    vim.api.nvim_set_current_buf(buf)
  else
    buf = M.open()
  end
  M.start_insert()
  return buf
end

local insert_queued_for = nil

function M.start_insert()
  insert_queued_for = vim.api.nvim_get_current_buf()
  vim.cmd('startinsert')
end

function M.insert_engaged()
  insert_queued_for = nil
end

function M.cancel_queued_insert(buf)
  if insert_queued_for == nil or insert_queued_for == buf then return end
  insert_queued_for = nil
  vim.cmd('stopinsert')
end

function M.reading_scrollback(buf)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= buf then
    return false
  end
  return vim.fn.line('w$', win) < vim.fn.line('$', win)
end

function M.should_enter_insert(buf)
  return M.enter_insert
      and M.is_terminal(buf)
      and M.is_managed(buf)
      and vim.api.nvim_get_current_buf() == buf
      and M.job_is_running(buf)
      and not M.reading_scrollback(buf)
end

M.INTERRUPT_TIMEOUT = 5000

function M.send(buf, cmd, run_immediately)
  if run_immediately == nil then run_immediately = true end
  local function push(data)
    if not vim.api.nvim_buf_is_valid(buf) then return false end
    local chan = vim.bo[buf].channel
    if not chan or chan <= 0 then return false end
    return (pcall(vim.api.nvim_chan_send, chan, data))
  end
  local KILL_LINE = '\021'
  local function write()
    if run_immediately then
      push(KILL_LINE .. 'clear\n' .. cmd .. '\n')
    else
      push(KILL_LINE .. cmd)
    end
  end

  if not M.busy(buf) then
    return write()
  end

  if not push('\003') then return end
  local timer = vim.uv.new_timer()
  local waited = 0
  timer:start(10, 10, vim.schedule_wrap(function()
    if timer:is_closing() then return end
    waited = waited + 10
    local settled = not vim.api.nvim_buf_is_valid(buf) or not M.busy(buf)
    if settled or waited >= M.INTERRUPT_TIMEOUT then
      timer:stop()
      timer:close()
      if settled then write() end
    end
  end))
end

local function best_hidden(accept)
  local best, best_lastused = nil, -1
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and M.is_terminal(buf) and M.is_managed(buf) and accept(buf) then
      local info = vim.fn.getbufinfo(buf)[1]
      if info and #info.windows == 0 and info.lastused > best_lastused then
        best, best_lastused = buf, info.lastused
      end
    end
  end
  return best
end

function M.hidden_for_tab()
  local tab = vim.api.nvim_get_current_tabpage()
  return best_hidden(function(buf) return vim.b[buf].muxim_owner_tab == tab end)
end

local function registered_by_valid_tabs()
  local registered = {}
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local ok, buf = pcall(vim.api.nvim_tabpage_get_var, tab, 'muxim_terminal')
    if ok and buf then
      registered[buf] = true
    end
  end
  return registered
end

function M.orphaned()
  local registered = registered_by_valid_tabs()
  return best_hidden(function(buf)
    return not registered[buf] and not M.owner(buf)
  end)
end

function M.owner(buf)
  local tab = vim.b[buf].muxim_owner_tab
  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    return tab
  end
  return nil
end

function M.adopt(buf, force)
  if not force and M.owner(buf) then
    return
  end
  vim.b[buf].muxim_owner_tab = vim.api.nvim_get_current_tabpage()
end

local function child_pids(pid)
  local f = io.open('/proc/' .. pid .. '/task/' .. pid .. '/children', 'r')
  if f then
    local children = vim.trim(f:read('*a') or '')
    f:close()
    return vim.split(children, '%s+', { trimempty = true })
  end
  if vim.fn.executable('pgrep') ~= 1 then
    return nil
  end
  local result = vim.system({ 'pgrep', '-P', tostring(pid) }, { text = true }):wait()
  if result.code ~= 0 then
    return {}
  end
  return vim.split(vim.trim(result.stdout or ''), '%s+', { trimempty = true })
end

function M.busy(buf)
  local pid = vim.b[buf].terminal_job_pid
  if not pid then
    return false
  end
  local kids = child_pids(pid)
  if kids == nil then
    return nil
  end
  return #kids > 0
end

function M.wipe_orphans(opts)
  opts = opts or {}
  local wiped, kept = {}, {}
  local registered = registered_by_valid_tabs()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf)
        and vim.bo[buf].buftype == 'terminal'
        and M.is_managed(buf)
        and #vim.fn.win_findbuf(buf) == 0
        and not M.owner(buf)
        and not registered[buf] then
      if opts.keep_busy and M.busy(buf) ~= false then
        kept[#kept + 1] = M.label(buf) or 'terminal'
      else
        wiped[#wiped + 1] = M.label(buf) or 'terminal'
        local chan = vim.bo[buf].channel
        local pid = vim.b[buf].terminal_job_pid
        if pid then
          for _, child in ipairs(child_pids(pid) or {}) do
            local child_pid = tonumber(child)
            if child_pid then
              pcall(vim.uv.kill, -child_pid, 'sigterm')
              pcall(vim.uv.kill, child_pid, 'sigterm')
            end
          end
          pcall(vim.uv.kill, -pid, 'sigterm')
        end
        if chan and chan > 0 then
          pcall(vim.fn.jobstop, chan)
          pcall(vim.fn.jobwait, { chan }, 2000)
        end
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
  if #wiped > 0 and opts.notify ~= false then
    vim.notify('muxim: closed terminal ' .. table.concat(wiped, ', '))
  end
  return wiped, kept
end

return M
