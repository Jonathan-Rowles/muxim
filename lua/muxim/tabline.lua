local M = {}

M.timer = nil

M.EXPR = '%!v:lua.MuximTabline()'

local sections = {}

function M.escape(text)
  return (tostring(text or ''):gsub('%c', ' '):gsub('%%', '%%%%'))
end

local function buf_label(buf)
  if vim.bo[buf].buftype == 'terminal' then
    return require('muxim.terminal').label(buf) or vim.fn.fnamemodify(vim.o.shell, ':t')
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then
    return '[No Name]'
  end
  return vim.fn.fnamemodify(name, ':t')
end

function M.content_windows(tab)
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_config(win).relative == '' then
      wins[#wins + 1] = win
    end
  end
  return wins
end

function M.content_window(tab)
  local current = vim.api.nvim_tabpage_get_win(tab)
  if vim.api.nvim_win_get_config(current).relative == '' then return current end
  return M.content_windows(tab)[1] or current
end

function M.tab_label(tab)
  local ok, name = pcall(vim.api.nvim_tabpage_get_var, tab, 'muxim_name')
  if ok and name and name ~= '' then
    return name
  end
  return buf_label(vim.api.nvim_win_get_buf(M.content_window(tab)))
end

M.sections = {}

function M.sections.server()
  local path = require('muxim.server').self_path
  if not path then return '' end
  local name = require('muxim.runtime').display_name(path)
  if name == '' then return '' end
  return '%#MuximTabServer# ' .. M.escape(name) .. ' %#MuximTabFill#'
end

function M.sections.tabs()
  local parts = {}
  local current = vim.api.nvim_get_current_tabpage()
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local hl = tab == current and '%#MuximTabSel#' or '%#MuximTab#'
    local label = M.escape(M.tab_label(tab))
    local root = require('muxim.root').label(tab)
    if root then
      label = label .. ' ' .. M.escape(root)
    end
    local agent = require('muxim.agents').tab_mark(tab)
    if agent then
      label = label .. M.escape(agent)
    end
    parts[#parts + 1] = hl .. '%' .. i .. 'T ' .. i .. ':' .. label .. ' %T'
  end
  parts[#parts + 1] = '%#MuximTabFill#'
  return table.concat(parts)
end

function M.sections.spacer()
  return '%#MuximTabFill#%='
end

function M.sections.clock()
  return '%#MuximTabTime#' .. os.date('%H:%M %d-%b-%y') .. ' '
end

function M.render()
  local parts = {}
  for _, section in ipairs(sections) do
    local value = section
    if type(section) == 'function' then
      local ok, result = pcall(section)
      value = ok and result or ''
    end
    parts[#parts + 1] = value and tostring(value) or ''
  end
  return table.concat(parts)
end

function _G.MuximTabline()
  local ok, result = pcall(function() return require('muxim.tabline').render() end)
  return ok and result or ''
end

function M.refresh()
  pcall(vim.cmd, 'redrawtabline')
end

M.defaults = {
  M.sections.server,
  M.sections.tabs,
  M.sections.spacer,
  M.sections.clock,
}

local user_highlights = {}

local links = {
  MuximTabServer = 'Directory',
  MuximTab = 'TabLine',
  MuximTabSel = 'TabLineSel',
  MuximTabFill = 'TabLineFill',
  MuximTabTime = 'Comment',
}

local function set_highlights()
  for group, target in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
  local overrides = type(user_highlights) == 'function' and user_highlights() or user_highlights
  for group, spec in pairs(overrides or {}) do
    vim.api.nvim_set_hl(0, group, spec)
  end
end

local previous_showtabline = nil
local applied_showtabline = nil

function M.setup(opts)
  opts = opts or {}
  if opts.highlights then
    user_highlights = opts.highlights
  end
  sections = opts.sections or M.defaults
  set_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('muxim_tabline', { clear = true }),
    callback = set_highlights,
  })
  if opts.showtabline ~= false then
    local wanted = opts.showtabline or 2
    if vim.o.showtabline ~= wanted then
      if previous_showtabline == nil then
        previous_showtabline = vim.o.showtabline
      end
      vim.o.showtabline = wanted
    end
    applied_showtabline = wanted
  end
  vim.o.tabline = M.EXPR
  local redraw = vim.api.nvim_create_augroup('muxim_tabline_redraw', { clear = true })
  vim.api.nvim_create_autocmd({ 'TermLeave', 'TabEnter', 'BufWinEnter', 'BufWritePost' }, {
    group = redraw,
    callback = M.refresh,
  })
  vim.api.nvim_create_autocmd('User', {
    group = redraw,
    pattern = 'MuximAgentState',
    callback = M.refresh,
  })
  if M.timer then
    M.timer:stop()
    M.timer:close()
    M.timer = nil
  end
  local interval = opts.refresh
  if interval == nil then interval = 15000 end
  if interval then
    assert(type(interval) == 'number' and interval > 0, 'muxim: tabline refresh must be a positive number or false')
    M.timer = vim.uv.new_timer()
    M.timer:start(interval, interval, vim.schedule_wrap(M.refresh))
    vim.api.nvim_create_autocmd('VimLeavePre', {
      group = vim.api.nvim_create_augroup('muxim_tabline_timer', { clear = true }),
      callback = function()
        if M.timer then
          M.timer:stop()
          M.timer:close()
          M.timer = nil
        end
      end,
    })
  end
end

function M.teardown()
  if M.timer then
    M.timer:stop()
    M.timer:close()
    M.timer = nil
  end
  if vim.o.tabline == M.EXPR then
    vim.o.tabline = ''
  end
  if previous_showtabline ~= nil and vim.o.showtabline == applied_showtabline then
    vim.o.showtabline = previous_showtabline
  end
  previous_showtabline, applied_showtabline = nil, nil
  for _, group in ipairs({ 'muxim_tabline', 'muxim_tabline_redraw', 'muxim_tabline_timer' }) do
    pcall(vim.api.nvim_del_augroup_by_name, group)
  end
end

return M
