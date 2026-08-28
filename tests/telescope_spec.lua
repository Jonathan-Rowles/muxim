local H = dofile('tests/helper.lua')

local plugin_dir = vim.env.MUXIM_PLUGIN_DIR or (vim.fn.stdpath('data') .. '/lazy')
vim.opt.rtp:append(plugin_dir .. '/telescope.nvim')
vim.opt.rtp:append(plugin_dir .. '/plenary.nvim')

if not pcall(require, 'telescope') then
  print('SKIP telescope_spec: no telescope.nvim under ' .. plugin_dir
    .. ' (point MUXIM_PLUGIN_DIR at a directory holding telescope.nvim and plenary.nvim)')
  vim.cmd('qall!')
  return
end

vim.o.columns = 200
vim.o.lines = 50

local state = require('telescope.actions.state')

local function prompt_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == 'TelescopePrompt' then
      return buf
    end
  end
end

local function picker_ready()
  local buf = prompt_buf()
  local picker = buf and state.get_current_picker(buf)
  vim.wait(2000, function()
    return picker and picker.manager and picker.manager:num_results() > 0
  end, 20)
  return buf, picker
end

local pickers = require('muxim.pickers')
local sources = require('muxim.sources')
local actions = require('muxim.actions')

local selected_by_ui
local real_select = vim.ui.select
vim.ui.select = function(entries, _, on_choice)
  selected_by_ui = entries
  on_choice(nil)
end

local notified
local real_notify = vim.notify
vim.notify = function(msg) notified = msg end

vim.cmd('tabonly')
vim.cmd('$tabnew')
vim.cmd('$tabnew')
local tabs = vim.api.nvim_list_tabpages()
vim.api.nvim_set_current_tabpage(tabs[1])

require('muxim.pickers.telescope').debounce = 0

local probe = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(probe, 0, -1, false, { 'local previewed = true', 'return previewed' })

pickers.backend = nil
pickers.windows()
local buf, picker = picker_ready()
H.eq(selected_by_ui, nil, 'with telescope on the runtimepath the select fallback is not used')
H.ok(buf ~= nil, 'the telescope backend is auto-detected and opens a prompt')
H.eq(picker.prompt_title, 'Choose window', 'window picker title')
H.eq(picker.manager:num_results(), 4, 'a session row, then one entry per tab')

picker:set_selection(0)
H.ok(vim.wait(2000, function()
  local preview = picker.previewer and picker.previewer.state and picker.previewer.state.bufnr
  if not preview or not vim.api.nvim_buf_is_valid(preview) then return false end
  return vim.api.nvim_buf_get_lines(preview, 0, -1, false)[1] == 'local previewed = true'
end, 20), 'the window picker previews the real buffer in that tab')

picker:set_selection(3)
local entry = state.get_selected_entry()
local text, spans = entry.display(entry)
H.contains(text, '3:', 'entries are formatted through sources.display')
H.eq(type(spans), 'table', 'and carry highlight spans telescope can render')
H.contains(entry.ordinal, '3', 'the ordinal is searchable text')
require('telescope.actions').select_default(buf)
H.ok(vim.wait(2000, function() return prompt_buf() == nil end, 20), 'selecting closes the picker')
H.eq(vim.api.nvim_get_current_tabpage(), tabs[3], 'and switches to the chosen tab')

local fake = {
  { name = 'alpha', path = '/tmp/muxim-telescope-spec-alpha.sock', live = true, current = false },
  { name = 'beta', path = '/tmp/muxim-telescope-spec-beta.sock', live = true, current = false },
}
local real_sessions = sources.sessions
sources.sessions = function() return fake end

local session = require('muxim.session')
local previewed
local real_preview_async = session.preview_async
session.preview_async = function(entry, callback)
  previewed = entry
  callback({ 'preview of ' .. entry.name, 'second line' },
    { { line = 2, col = 0, end_col = 6, group = 'MuximPreviewJob' } })
end
local killed
local real_kill = actions.kill
actions.kill = function(entry, force, callback)
  killed = { name = entry.name, force = force }
  callback(false, entry.name .. ': not killed')
end

pickers.sessions()
buf, picker = picker_ready()
H.contains(picker.prompt_title, 'x quit', 'the session picker advertises its kill keys')
H.eq(picker.manager:num_results(), 2, 'one entry per live session')

H.ok(vim.wait(2000, function() return previewed ~= nil end, 20), 'the previewer asks for session lines')
H.eq(previewed.name, 'alpha', 'for the selected session')
H.ok(vim.wait(2000, function()
  local preview = picker.previewer and picker.previewer.state and picker.previewer.state.bufnr
  return preview and vim.api.nvim_buf_get_lines(preview, 0, -1, false)[1] == 'preview of alpha'
end, 20), 'and shows them in the preview window')
local preview_buf = picker.previewer.state.bufnr
local extmarks = vim.api.nvim_buf_get_extmarks(preview_buf,
  require('muxim.pickers.telescope').NAMESPACE, 0, -1, { details = true })
H.eq(#extmarks, 1, 'the preview is highlighted from the marks the renderer returned')
H.eq(extmarks[1][4].hl_group, 'MuximPreviewJob', 'with the group it asked for')

vim.api.nvim_win_set_buf(0, buf)
notified = nil
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>x', true, false, true), 'x', false)
H.eq(killed and killed.name, 'alpha', 'x kills the selected session')
H.eq(killed.force, false, 'without force')
H.contains(notified, 'not killed', "and reports the kill's message")

killed = nil
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('X', true, false, true), 'x', false)
H.eq(killed and killed.force, true, 'X force-kills')

require('telescope.actions').close(buf)
vim.wait(200, function() return prompt_buf() == nil end, 20)

local ranked = {
  { name = 'navigator-vim', path = '/tmp/muxim-telescope-spec-live.sock', live = true, current = false },
  { name = 'nvim', dir = '/tmp/proj/nvim', path = '/tmp/muxim-telescope-spec-dead.sock', live = false, current = false },
}
sources.sessions = function() return ranked end
pickers.sessions()
buf, picker = picker_ready()
local function score_of(value)
  local item = { value = value, ordinal = sources.ordinal(value) }
  return picker.sorter:scoring_function('nvim', item.ordinal, item)
end
local live_score = score_of(ranked[1])
local dead_score = score_of(ranked[2])
H.ok(live_score >= 0, 'the weakly matching live session is not filtered out')
H.ok(dead_score >= require('muxim.pickers.telescope').DEAD_WEIGHT,
  'the picker sorter carries the dead weight on a dead project')
H.ok(dead_score > live_score,
  'so a dead project never outranks a matching live session, however exact its match')
require('telescope.actions').close(buf)
vim.wait(200, function() return prompt_buf() == nil end, 20)

local telescope_picker = require('muxim.pickers.telescope')
local tiered = telescope_picker.prioritise({
  scoring_function = function(_, prompt, line)
    return line:find(prompt, 1, true) and 0.5 or -1
  end,
})
local function tier_score(name, dir, live)
  return tiered:scoring_function('ratings-pla', name .. ' ' .. dir,
    { value = { name = name, dir = dir, live = live } })
end
local dead_name = tier_score('ratings-platform', '~/source/ratings-platform', false)
local dead_dir = tier_score('client', '~/source/ratings-platform/client', false)
local live_dir = tier_score('scripts', '~/source/ratings-platform/scripts', true)
H.ok(dead_name < dead_dir, 'a name match outranks a dir-only match absolutely')
H.eq(dead_dir, 0.5 + telescope_picker.DEAD_WEIGHT + telescope_picker.DIR_WEIGHT,
  'a dir-only dead match carries both weights')
H.ok(live_dir < dead_name, 'liveness still dominates: a live dir match beats a dead name match')

actions.kill = real_kill
sources.sessions = real_sessions
session.preview_async = real_preview_async
vim.ui.select = real_select
vim.notify = real_notify
pickers.backend = 'select'
H.finish('telescope_spec')
