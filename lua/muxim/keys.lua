local M = {}

M.prefix = nil

local bindings = {}
local mapped = {}
local shadowed = {}

local function split_binding(value)
  if type(value) == 'function' then
    return value, nil
  end
  if type(value) == 'table' then
    return value[1], value.desc or value[2]
  end
  return nil, nil
end

local function send_prefix()
  local sequence = vim.keycode(M.prefix)
  if vim.api.nvim_get_mode().mode == 't' then
    local chan = vim.bo.channel
    if chan and chan > 0 then
      vim.api.nvim_chan_send(chan, sequence)
    end
    return
  end
  vim.api.nvim_feedkeys(sequence, 'n', false)
end

local function global_mapping(mode, lhs)
  local target = vim.keycode(lhs)
  for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
    if vim.keycode(map.lhs) == target then
      return map
    end
  end
  return nil
end

local function apply()
  local function set(mode, lhs, rhs, desc)
    local existing = global_mapping(mode, lhs)
    if existing then
      shadowed[#shadowed + 1] = existing
    end
    vim.keymap.set(mode, lhs, rhs, { desc = desc })
    mapped[#mapped + 1] = { mode = mode, lhs = lhs }
  end
  for key, value in pairs(bindings) do
    local rhs, desc = split_binding(value)
    if rhs then
      set('n', M.prefix .. key, rhs, desc)
      set('t', M.prefix .. key, function()
        vim.cmd('stopinsert')
        rhs()
      end, desc)
    end
  end
  local function swallow()
    local eaten = vim.fn.getchar(0)
    if eaten == 0 then return end
    local key = type(eaten) == 'number' and vim.fn.nr2char(eaten) or eaten
    vim.api.nvim_echo(
      { { ('muxim: %s%s is not bound'):format(M.prefix, vim.fn.keytrans(key)), 'WarningMsg' } },
      false, {})
  end
  set('n', M.prefix, swallow, 'muxim prefix')
  set('t', M.prefix, swallow, 'muxim prefix')
  set('n', M.prefix .. M.prefix, send_prefix, 'send prefix')
  set('t', M.prefix .. M.prefix, send_prefix, 'send prefix')
end

local function restore(map)
  local function flag(v) return v == 1 or v == true end
  local opts = {
    noremap = flag(map.noremap),
    silent = flag(map.silent),
    expr = flag(map.expr),
    nowait = flag(map.nowait),
    desc = map.desc,
    callback = map.callback,
  }
  if flag(map.replace_keycodes) then
    opts.replace_keycodes = true
  end
  vim.api.nvim_set_keymap(map.mode, map.lhs, map.callback and '' or (map.rhs or ''), opts)
end

local function clear()
  for _, map in ipairs(mapped) do
    pcall(vim.keymap.del, map.mode, map.lhs)
  end
  for _, map in ipairs(shadowed) do
    pcall(restore, map)
  end
  mapped, shadowed = {}, {}
end

local function zoom()
  local saved = vim.t.muxim_zoom
  if saved then
    vim.t.muxim_zoom = nil
    for _, entry in ipairs(saved) do
      if vim.api.nvim_win_is_valid(entry.win) then
        pcall(vim.api.nvim_win_set_height, entry.win, entry.height)
        pcall(vim.api.nvim_win_set_width, entry.win, entry.width)
      end
    end
    return
  end
  if #vim.api.nvim_tabpage_list_wins(0) < 2 then
    return
  end
  local layout = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    layout[#layout + 1] = {
      win = win,
      height = vim.api.nvim_win_get_height(win),
      width = vim.api.nvim_win_get_width(win),
    }
  end
  vim.t.muxim_zoom = layout
  vim.cmd('wincmd _')
  vim.cmd('wincmd |')
end

local function copy_mode()
  if vim.api.nvim_get_mode().mode == 't' then
    vim.api.nvim_feedkeys(vim.keycode('<C-\\><C-n>'), 'n', false)
  end
end

local function rename_window()
  vim.ui.input({ prompt = 'Rename window: ', default = vim.t.muxim_name or '' }, function(name)
    if name == nil then return end
    vim.t.muxim_name = name ~= '' and name or nil
    pcall(vim.cmd, 'redrawtabline')
  end)
end

function M.help()
  local order = { 'Panes', 'Windows', 'Sessions', 'Other' }
  local groups = { Panes = {}, Windows = {}, Sessions = {}, Other = {} }
  local function row(key, desc)
    return ('  %s %-8s %s'):format(M.prefix, key, desc)
  end
  local digits = {}
  for key, value in pairs(bindings) do
    local rhs, desc = split_binding(value)
    if rhs then
      desc = desc or ''
      if key:match('^%d$') and desc:match('^select window %d+$') then
        digits[#digits + 1] = key
      else
        local group = (desc:match('pane') and 'Panes')
            or (desc:match('window') and 'Windows')
            or ((desc:match('session') or desc:match('client') or desc:match('project')) and 'Sessions')
            or 'Other'
        table.insert(groups[group], row(key, desc))
      end
    end
  end
  if #digits > 0 then
    table.sort(digits)
    table.insert(groups.Windows, row(digits[1] .. '-' .. digits[#digits], 'select window'))
  end
  local rows = {}
  for _, group in ipairs(order) do
    if #groups[group] > 0 then
      table.sort(groups[group])
      if #rows > 0 then rows[#rows + 1] = '' end
      rows[#rows + 1] = group
      vim.list_extend(rows, groups[group])
    end
  end
  if #rows == 0 then return end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  local width = 0
  for _, line in ipairs(rows) do width = math.max(width, #line) end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(0, math.floor((vim.o.lines - #rows) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = math.max(1, math.min(width + 2, vim.o.columns - 2)),
    height = math.max(1, math.min(#rows, vim.o.lines - 4)),
    style = 'minimal',
    border = 'rounded',
    title = ' muxim keys ',
  })
  vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf })
  vim.keymap.set('n', '<Esc>', '<cmd>close<cr>', { buffer = buf })
  vim.wo[win].cursorline = true
end

function M.defaults()
  local keys = {
    ['c'] = { function()
      require('muxim.terminal').open_in_tab()
      require('muxim.terminal').start_insert()
    end, 'new window' },
    ['d'] = { function() vim.cmd('detach') end, 'detach client' },
    ['t'] = { function() require('muxim.terminal').toggle() end, 'toggle terminal' },
    ['n'] = { function() vim.cmd('tabnext') end, 'next window' },
    ['p'] = { function() vim.cmd('tabprevious') end, 'previous window' },
    ['l'] = { function() pcall(vim.cmd, 'tabnext #') end, 'last window' },
    [','] = { rename_window, 'rename window' },
    ['&'] = { function() require('muxim').close_tab() end, 'kill window' },
    ['x'] = { function() require('muxim').close_pane() end, 'kill pane' },
    ['o'] = { function() vim.cmd('wincmd w') end, 'select next pane' },
    [';'] = { function() vim.cmd('wincmd p') end, 'last pane' },
    ['z'] = { zoom, 'zoom pane' },
    ['['] = { copy_mode, 'copy mode' },
    ['?'] = { M.help, 'list keys' },
    ['R'] = { function() vim.cmd('MuximTabRoot') end, 'set tab root from terminal' },
    ['a'] = { function() require('muxim.drawer').toggle() end, 'agent drawer' },
    ['A'] = { function() require('muxim.agents').focus_blocked() end, 'go to a blocked agent' },
    ['C'] = { function() vim.cmd('MuximAgent') end, 'new window running an agent' },
    ['<M-n>'] = { function() require('muxim.agents').focus_blocked() end, 'go to a blocked agent' },
    ['w'] = { function() require('muxim.pickers').windows() end, 'choose window' },
    ['s'] = { function() require('muxim.pickers').sessions() end, 'choose session' },
    ['<Up>'] = { function() vim.cmd('wincmd k') end, 'select pane up' },
    ['<Down>'] = { function() vim.cmd('wincmd j') end, 'select pane down' },
    ['<Left>'] = { function() vim.cmd('wincmd h') end, 'select pane left' },
    ['<Right>'] = { function() vim.cmd('wincmd l') end, 'select pane right' },
    ['<M-Up>'] = { function() vim.cmd('resize +5') end, 'resize pane up' },
    ['<M-Down>'] = { function() vim.cmd('resize -5') end, 'resize pane down' },
    ['<M-Left>'] = { function() vim.cmd('vertical resize -5') end, 'resize pane left' },
    ['<M-Right>'] = { function() vim.cmd('vertical resize +5') end, 'resize pane right' },
  }
  for i = 1, 9 do
    keys[tostring(i)] = { function() pcall(vim.cmd, 'tabnext ' .. i) end, 'select window ' .. i }
  end
  return keys
end

function M.bindings()
  return bindings
end

function M.setup(opts)
  clear()
  M.prefix = opts.prefix
  bindings = opts.keys
  apply()
end

function M.teardown()
  clear()
  M.prefix = nil
  bindings = {}
end

return M
