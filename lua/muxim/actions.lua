local server = require('muxim.server')

local M = {}

function M.open(entry)
  return server.open(entry.dir or entry.path)
end

function M.connect(entry)
  if entry.current then return false end
  server.connect(entry.path)
  return true
end

function M.enter(entry)
  if entry.current then return false end
  if entry.live then
    return M.connect(entry)
  end
  return server.open(entry.dir or entry.path)
end

function M.select_window(entry)
  if entry.kind == 'session' then
    return M.enter(entry)
  end
  if entry.tab and vim.api.nvim_tabpage_is_valid(entry.tab) then
    vim.api.nvim_set_current_tabpage(entry.tab)
    return true
  end
  if entry.path and entry.index then
    local goto_tab = ("v:lua.require'muxim.session'.goto_tab(%d)"):format(entry.index)
    local went = server.remote_expr(entry.path, goto_tab)
    if not server.connect(entry.path) then return false end
    if went == nil then
      server.remote_expr(entry.path, goto_tab)
    end
    return true
  end
  return false
end

local function describe_modified(name, modified, separator)
  return ('%s has %d unsaved buffer%s:%s%s'):format(
    name, #modified, #modified == 1 and '' or 's',
    separator, table.concat(modified, separator))
end

function M.kill(entry, force, callback)
  callback = callback or function() end
  if entry.current or vim.tbl_contains(vim.fn.serverlist(), entry.path) then
    return callback(false, 'Cannot kill the server you are attached to')
  end
  if force then
    local modified = server.modified_on(entry.path)
    local prompt
    if modified == nil and server.is_live(entry.path) then
      prompt = entry.name .. ' did not answer the unsaved-changes check (busy or blocked).'
          .. '\nForce-quit anyway? Anything unsaved there would be DISCARDED.'
    elseif modified and #modified > 0 then
      prompt = describe_modified(entry.name, modified, '\n  ')
          .. '\nForce-quit and DISCARD these changes?'
    end
    if prompt and vim.fn.confirm(prompt, '&Yes\n&No', 2) ~= 1 then
      return callback(false, entry.name .. ': not killed')
    end
  end
  server.kill(entry.path, force)
  server.on_gone(entry.path, force and 4000 or 2000, function(dead)
    if dead then
      return callback(true)
    end
    local modified = server.modified_on(entry.path)
    if modified and #modified > 0 then
      return callback(false,
        describe_modified(entry.name, modified, ' ') .. '. X force-quits and DISCARDS them')
    end
    callback(false, entry.name .. ' did not exit (busy or blocked); X force-quits')
  end)
end

return M
