local H = dofile('tests/helper.lua')
local root = require('muxim.root')
local terminal = require('muxim.terminal')
local tabline = require('muxim.tabline')

local session_root = vim.uv.fs_realpath(root.session()) or root.session()
H.eq(root.get(), session_root, 'a fresh tab reports the session root')
H.eq(root.label(), nil, 'no tabline marker while the tab is at the session root')

local elsewhere = H.runtime_dir() .. '/elsewhere'
vim.fn.mkdir(elsewhere, 'p')
elsewhere = vim.uv.fs_realpath(elsewhere)

vim.cmd('$tabnew')
local moved_tab = vim.api.nvim_get_current_tabpage()
H.ok(root.set(elsewhere), 'set() accepts a real directory')
H.eq(root.get(), elsewhere, 'tab root moved')
H.eq(root.session(), session_root, 'the session root is untouched')
H.ok(root.label() ~= nil, 'tabline marks a tab rooted elsewhere')
H.contains(tabline.sections.tabs(), vim.fn.fnamemodify(elsewhere, ':~'), 'marker appears in the tabs section')

H.eq(root.set(elsewhere .. '/nope'), false, 'set() refuses a missing directory')
H.eq(root.get(), elsewhere, 'a refused set leaves the root alone')

local terminal_in_tab = terminal.open()
vim.cmd('stopinsert')
H.ok(vim.wait(3000, function()
  return root.terminal_cwd(terminal_in_tab) == elsewhere
end, 50), 'a terminal opened in the tab starts at the tab root')

vim.cmd('tabfirst')
H.eq(root.get(), session_root, 'the first tab kept its own root')

vim.api.nvim_set_current_tabpage(moved_tab)
local inherited = terminal.open_in_tab()
vim.cmd('stopinsert')
H.eq(root.get(), elsewhere, 'a new window inherits the root of the tab it came from')
H.ok(vim.wait(3000, function()
  return root.terminal_cwd(inherited) == elsewhere
end, 50), 'and its terminal starts there too')

vim.cmd('tabfirst')
local at_session = terminal.open_in_tab()
vim.cmd('stopinsert')
H.eq(root.get(), session_root, 'a window opened from a session-rooted tab stays at the session root')
H.ok(vim.wait(3000, function()
  return root.terminal_cwd(at_session) == session_root
end, 50), 'its terminal starts at the session root')

local subdir = H.runtime_dir() .. '/elsewhere/deeper'
vim.fn.mkdir(subdir, 'p')
subdir = vim.uv.fs_realpath(subdir)
vim.b[at_session].osc7_dir = subdir
H.eq(root.terminal_cwd(at_session), subdir, 'a reported OSC 7 dir wins over the process lookup')
H.ok(root.follow(at_session), 'follow() promotes the terminal cwd to the tab root')
H.eq(root.get(), subdir, 'tab root followed the terminal')

vim.b[at_session].osc7_dir = nil
H.eq(root.terminal_cwd(at_session), session_root,
  'with no OSC 7 the cwd is still resolved, whatever this platform provides')

local osc7 = ('\027]7;file://host%s'):format(subdir)
vim.api.nvim_exec_autocmds('TermRequest', {
  buffer = at_session,
  data = { sequence = osc7 },
})
H.eq(vim.b[at_session].osc7_dir, subdir, 'an OSC 7 sequence is parsed into the terminal cwd')

local spaced = H.runtime_dir() .. '/dir with spaces'
vim.fn.mkdir(spaced, 'p')
spaced = vim.uv.fs_realpath(spaced)
vim.api.nvim_exec_autocmds('TermRequest', {
  buffer = at_session,
  data = { sequence = '\027]7;file://host' .. spaced:gsub(' ', '%%20') },
})
H.eq(vim.b[at_session].osc7_dir, spaced, 'a percent-encoded OSC 7 path is decoded')

vim.b[at_session].osc7_dir = nil
vim.api.nvim_exec_autocmds('TermRequest', {
  buffer = at_session,
  data = { sequence = '\027]7;file://host' .. H.runtime_dir() .. '/no-such-dir' },
})
H.eq(vim.b[at_session].osc7_dir, nil, 'an OSC 7 path that is not a directory is ignored')

H.eq(root.follow_terminal_cwd, false, 'auto-follow is off by default')

root.follow_terminal_cwd = true
vim.cmd('$tabnew')
local following = terminal.open()
vim.cmd('stopinsert')
root.set(elsewhere)
vim.api.nvim_exec_autocmds('TermRequest', {
  buffer = following,
  data = { sequence = '\027]7;file://host' .. subdir },
})
H.drain()
H.eq(root.get(), subdir, 'auto-follow moves the tab root when the terminal reports a new cwd')

vim.cmd('$tabnew')
local inherited = root.get()
vim.api.nvim_exec_autocmds('TermRequest', {
  buffer = following,
  data = { sequence = '\027]7;file://host' .. elsewhere },
})
H.drain()
H.eq(root.get(), inherited, 'a report from a terminal in another tab does not move this root')
root.follow_terminal_cwd = false

H.finish('root_spec')
