local sources = require('muxim.sources')
local actions = require('muxim.actions')

local M = {}

local function choose(entries, prompt, on_select)
  if #entries == 0 then
    vim.notify('Nothing to choose', vim.log.levels.WARN)
    return
  end
  vim.ui.select(entries, {
    prompt = prompt,
    format_item = function(entry) return (sources.display(entry)) end,
  }, function(entry)
    if entry then on_select(entry) end
  end)
end

function M.sessions(dirs)
  choose(sources.sessions(dirs), 'Choose session', actions.enter)
end

function M.windows()
  choose(sources.windows(), 'Choose window', actions.select_window)
end

return M
