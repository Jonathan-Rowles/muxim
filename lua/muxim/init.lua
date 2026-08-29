local M = {}

local function confirmed(msg)
  return vim.fn.confirm(msg, '&Yes\n&No', 2) == 1
end

local function reattach_hint()
  local prefix = require('muxim.keys').prefix
  if prefix then
    return ('reattach with %ss from another session'):format(prefix)
  end
  return 'reattach from another client'
end

M.on_last_close = function()
  local prompt = 'Last pane.\n'
      .. 'Quit closes this session and its buffers.\n'
      .. 'Detach leaves it running in the background; ' .. reattach_hint() .. '.'
  local choice = vim.fn.confirm(prompt, '&Quit\n&Detach\n&Cancel', 3)
  if choice == 1 then
    vim.cmd('confirm qall')
  elseif choice == 2 then
    vim.cmd('detach')
  end
end

M.remain_on_exit = false

M.adopt_foreign_terminals = false

M.keep_busy_terminals = true

local function normal_window_count()
  local count = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == '' then
      count = count + 1
    end
  end
  return count
end

function M.close_pane()
  if normal_window_count() > 1 or #vim.api.nvim_list_tabpages() > 1 then
    if confirmed('Close pane?') then
      vim.cmd('close')
    end
  else
    M.on_last_close()
  end
end

function M.close_tab()
  if #vim.api.nvim_list_tabpages() > 1 then
    if confirmed('Close tab?') then
      vim.cmd('tabclose')
    end
  else
    M.on_last_close()
  end
end

function M.close_exited_terminal(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local wins = vim.fn.win_findbuf(buf)
  if #wins ~= 1 then return end
  local win = wins[1]
  local tab = vim.api.nvim_win_get_tabpage(win)
  if #vim.api.nvim_tabpage_list_wins(tab) ~= 1 then return end
  if #vim.api.nvim_list_tabpages() < 2 then return end
  pcall(vim.api.nvim_win_close, win, true)
end

local function terminal_autocmds()
  local terminal = require('muxim.terminal')

  vim.api.nvim_create_autocmd('TermOpen', {
    group = vim.api.nvim_create_augroup('muxim_term_open', { clear = true }),
    callback = function(args)
      if not terminal.claim_pending(args.buf) then
        if not M.adopt_foreign_terminals then return end
        terminal.mark_managed(args.buf)
      end
      vim.bo[args.buf].bufhidden = 'hide'
      terminal.adopt(args.buf)
      if not terminal.registered() then
        terminal.register(args.buf)
      end
      vim.api.nvim_exec_autocmds('User', {
        pattern = 'MuximTermOpen',
        data = { buf = args.buf },
      })
    end,
  })

  vim.api.nvim_create_autocmd('TermClose', {
    group = vim.api.nvim_create_augroup('muxim_term_close', { clear = true }),
    callback = function(args)
      if not terminal.is_managed(args.buf) then return end
      local pid = vim.api.nvim_buf_is_valid(args.buf) and vim.b[args.buf].terminal_job_pid or nil
      local exit_code = vim.v.event and vim.v.event.status
      vim.api.nvim_exec_autocmds('User', {
        pattern = 'MuximTermClose',
        data = { buf = args.buf, pid = pid, exit_code = exit_code },
      })
      if M.remain_on_exit then return end
      vim.schedule(function() M.close_exited_terminal(args.buf) end)
    end,
  })

  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = vim.api.nvim_create_augroup('muxim_term_owner_tab', { clear = true }),
    callback = function(args)
      if vim.bo[args.buf].buftype == 'terminal' then
        terminal.adopt(args.buf)
      end
    end,
  })

  local insert_group = vim.api.nvim_create_augroup('muxim_term_insert', { clear = true })

  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter', 'TabEnter' }, {
    group = insert_group,
    callback = function()
      terminal.cancel_queued_insert(vim.api.nvim_get_current_buf())
      vim.schedule(function()
        if terminal.should_enter_insert(vim.api.nvim_get_current_buf()) then
          terminal.start_insert()
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ 'InsertEnter', 'TermEnter' }, {
    group = insert_group,
    callback = function() terminal.insert_engaged() end,
  })

  vim.api.nvim_create_autocmd('TabClosed', {
    group = vim.api.nvim_create_augroup('muxim_term_cleanup', { clear = true }),
    callback = function()
      vim.schedule(function()
        terminal.wipe_orphans({ keep_busy = M.keep_busy_terminals })
      end)
    end,
  })
end

M.enabled = false

M.setup_called = false

---@alias muxim.KeyBinding fun()|{ [1]: fun(), [2]: string? }

---@class muxim.TablineOpts
---@field sections table?
---@field highlights table<string, string|table>?
---@field showtabline integer|false?

---@class muxim.DrawerOpts
---@field width integer?
---@field side 'left'|'right'?
---@field highlights table<string, string|table>?
---@field format fun(entry: table): string?

---@class muxim.AgentsOpts
---@field notify boolean|'unfocused'|fun(notice: table)?
---@field notify_fleet boolean|'unfocused'|fun(notice: table)?
---@field notify_desktop boolean?
---@field commands table<string, boolean>|string[]?
---@field marks table<string, string>?
---@field drawer muxim.DrawerOpts?
---@field claude table?

---@class muxim.Opts
---@field prefix string? default '<C-b>'
---@field keys false|table<string, muxim.KeyBinding|false>?
---@field picker 'telescope'|'select'|table?
---@field projects string[]|fun(): string[]?
---@field tabline false|muxim.TablineOpts?
---@field nested boolean? full setup inside another session's terminal
---@field agents false|muxim.AgentsOpts?
---@field enter_insert boolean?
---@field on_terminal_hide fun()?
---@field on_last_close fun()?
---@field adopt_foreign_terminals boolean?
---@field keep_busy_terminals boolean?
---@field follow_terminal_cwd boolean?
---@field remain_on_exit boolean?

---@param opts muxim.Opts?
---@return boolean
function M.setup(opts)
  M.setup_called = true
  opts = opts or {}
  local server = require('muxim.server')
  local keys = require('muxim.keys')

  if vim.fn.has('nvim-0.12') == 0 then
    vim.notify(
      'muxim requires Neovim 0.12+ (it needs the :connect command to attach to sessions)',
      vim.log.levels.ERROR)
    return false
  end

  if opts.on_last_close then
    M.on_last_close = opts.on_last_close
  end

  if opts.remain_on_exit ~= nil then
    M.remain_on_exit = opts.remain_on_exit
  end

  if opts.adopt_foreign_terminals ~= nil then
    M.adopt_foreign_terminals = opts.adopt_foreign_terminals
  end

  if opts.keep_busy_terminals ~= nil then
    M.keep_busy_terminals = opts.keep_busy_terminals
  end

  if opts.enter_insert ~= nil then
    require('muxim.terminal').enter_insert = opts.enter_insert
  end

  if opts.on_terminal_hide ~= nil then
    require('muxim.terminal').on_terminal_hide = opts.on_terminal_hide
  end

  if opts.follow_terminal_cwd ~= nil then
    require('muxim.root').follow_terminal_cwd = opts.follow_terminal_cwd
  end

  terminal_autocmds()
  require('muxim.remote').setup()
  local drawer = require('muxim.drawer')
  drawer.set_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('muxim_highlights', { clear = true }),
    callback = drawer.set_highlights,
  })
  require('muxim.agents').setup(opts.agents)
  require('muxim.root').setup()
  require('muxim.commands').register()

  if server.nested() and not opts.nested then
    vim.g.muxim_nested = true
    vim.env.MUXIM_TERM = nil
    server.forget_parent()
    return false
  end
  vim.g.muxim_nested = nil

  if not server.ensure_named() then
    return false
  end
  require('muxim.agents').watch_fleet()

  if opts.keys ~= false then
    keys.setup({
      prefix = opts.prefix or '<C-b>',
      keys = vim.tbl_extend('force', keys.defaults(),
        type(opts.keys) == 'table' and opts.keys or {}),
    })
  else
    keys.teardown()
  end

  if opts.picker ~= nil then
    require('muxim.pickers').backend = opts.picker
  end

  if opts.projects ~= nil then
    require('muxim.sources').project_dirs = opts.projects
  end

  if opts.tabline ~= false then
    require('muxim.tabline').setup(type(opts.tabline) == 'table' and opts.tabline or nil)
  else
    require('muxim.tabline').teardown()
  end

  local function record_attachment()
    if #vim.api.nvim_list_uis() > 0 and server.self_path then
      require('muxim.resume').record(server.self_path)
    end
  end

  vim.api.nvim_create_autocmd('UIEnter', {
    group = vim.api.nvim_create_augroup('muxim_resume', { clear = true }),
    callback = record_attachment,
  })
  record_attachment()

  M.enabled = true
  server.announce_to_parent()
  return true
end

return M
