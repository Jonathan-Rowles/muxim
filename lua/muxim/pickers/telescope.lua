local sources = require('muxim.sources')
local session = require('muxim.session')
local actions = require('muxim.actions')

local M = {}

M.debounce = 80

local function highlight_as(bufnr, filetype)
  pcall(vim.treesitter.stop, bufnr)
  if not filetype or filetype == '' then
    vim.bo[bufnr].syntax = ''
    return
  end
  local lang = vim.treesitter.language.get_lang(filetype)
  if lang and pcall(vim.treesitter.start, bufnr, lang) then return end
  pcall(function() vim.bo[bufnr].syntax = filetype end)
end

M.NAMESPACE = vim.api.nvim_create_namespace('muxim_preview')

local function cursor_mark(view)
  if not view or not view.cursor or not view.lines then return nil end
  if view.cursor < 1 or view.cursor > #view.lines then return nil end
  return { {
    line = view.cursor,
    col = 0,
    end_col = #view.lines[view.cursor],
    group = 'MuximPreviewCursor',
  } }
end

local function previewer(title, define)
  local generation = 0
  return require('telescope.previewers').new_buffer_previewer({
    title = title,
    define_preview = function(self, entry)
      generation = generation + 1
      local mine = generation
      local bufnr = self.state.bufnr
      local function show(lines, filetype, marks)
        if mine ~= generation or not vim.api.nvim_buf_is_valid(bufnr) then return end
        pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_clear_namespace(bufnr, M.NAMESPACE, 0, -1)
        highlight_as(bufnr, filetype)
        for _, mark in ipairs(marks or {}) do
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.NAMESPACE, mark.line - 1, mark.col, {
            end_col = mark.end_col,
            hl_group = mark.group,
          })
        end
      end
      local winid = self.state.winid
      local live = winid and vim.api.nvim_win_is_valid(winid)
      local size = live and {
        height = vim.api.nvim_win_get_height(winid),
        width = vim.api.nvim_win_get_width(winid),
      } or {}
      define(entry.value, show, function() return mine == generation end, size)
    end,
  })
end

local function session_preview()
  return previewer('Session', function(value, show, still_current)
    vim.defer_fn(function()
      if not still_current() then return end
      session.preview_async(value, function(lines, marks) show(lines, nil, marks) end)
    end, M.debounce)
  end)
end

local function window_preview()
  return previewer('Window', function(value, show, still_current, size)
    local win = value.tab and vim.api.nvim_tabpage_is_valid(value.tab)
        and require('muxim.tabline').content_window(value.tab)
    if win then
      local view = session.window_view(win, size.height, size.width)
      return show(view.lines, view.filetype, cursor_mark(view))
    end
    if not value.path then
      return show({ '(no window to preview)' })
    end
    vim.defer_fn(function()
      if not still_current() then return end
      session.tab_lines_async(value, function(lines, filetype, view)
        show(lines, filetype, cursor_mark(view))
      end, size.height, size.width)
    end, M.debounce)
  end)
end

M.DEAD_WEIGHT = 1000
M.DIR_WEIGHT = 100

function M.prioritise(sorter)
  local score = sorter.scoring_function
  sorter.scoring_function = function(self, prompt, line, entry, ...)
    local base = score(self, prompt, line, entry, ...)
    if base < 0 then return base end
    local value = entry and entry.value
    if not value then return base end
    local penalty = value.live == false and M.DEAD_WEIGHT or 0
    if value.name then
      local on_name = score(self, prompt, value.name, entry, ...)
      if on_name >= 0 then
        return on_name + penalty
      end
      penalty = penalty + M.DIR_WEIGHT
    end
    return base + penalty
  end
  return sorter
end

local function pick(entries, opts)
  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local telescope_actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local themes = require('telescope.themes')

  local function finder(list)
    return finders.new_table({
      results = list,
      entry_maker = function(entry)
        return {
          value = entry,
          display = function() return sources.display(entry) end,
          ordinal = sources.ordinal(entry),
        }
      end,
    })
  end

  pickers.new(themes.get_ivy(opts.theme or {}), {
    prompt_title = opts.title,
    previewer = opts.previewer,
    finder = finder(entries),
    sorter = M.prioritise(conf.generic_sorter({})),
    attach_mappings = function(prompt_bufnr, map)
      telescope_actions.select_default:replace(function()
        local selected = action_state.get_selected_entry()
        telescope_actions.close(prompt_bufnr)
        if selected then opts.on_select(selected.value) end
      end)
      if opts.on_kill then
        local function kill(force)
          local selected = action_state.get_selected_entry()
          if not selected then return end
          opts.on_kill(selected.value, force, function(ok, message)
            if message then
              vim.notify(message, vim.log.levels.WARN)
            end
            if ok and vim.api.nvim_buf_is_valid(prompt_bufnr) then
              local picker = action_state.get_current_picker(prompt_bufnr)
              if picker then picker:refresh(finder(opts.refresh()), { reset_prompt = false }) end
            end
          end)
        end
        map({ 'n' }, 'x', function() kill(false) end)
        map({ 'n' }, 'X', function() kill(true) end)
        map({ 'i' }, '<C-x>', function() kill(false) end)
      end
      return true
    end,
  }):find()
end

function M.sessions(dirs)
  pick(sources.sessions(dirs), {
    title = 'Choose session  (x quit, X force)',
    previewer = session_preview(),
    on_select = actions.enter,
    on_kill = actions.kill,
    refresh = function() return sources.sessions(dirs) end,
  })
end

function M.windows()
  pick(sources.windows(), {
    title = 'Choose window',
    previewer = window_preview(),
    on_select = actions.select_window,
  })
end

return M
