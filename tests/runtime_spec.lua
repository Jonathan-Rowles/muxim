local H = dofile('tests/helper.lua')
local runtime = require('muxim.runtime')

H.contains(runtime.dir(), os.getenv('XDG_RUNTIME_DIR'), 'runtime dir honours XDG_RUNTIME_DIR when set')

-- Sessions can only find each other if every process agrees on one directory.
-- stdpath('run') is per-process on macOS, so this must not depend on it.
local function dir_without_xdg()
  local result = vim.system({
    vim.v.progpath, '--headless', '-u', 'tests/minimal_init.lua', '-i', 'NONE',
    '+lua io.write(require("muxim.runtime").dir())', '+q',
  }, { text = true, env = { XDG_RUNTIME_DIR = '', NVIM = '', MUXIM_SERVER = '' } }):wait()
  return vim.trim(result.stdout or '')
end

local first = dir_without_xdg()
H.ok(first ~= '', 'a process with no XDG_RUNTIME_DIR still resolves a runtime dir')
H.eq(dir_without_xdg(), first, 'two processes agree on the runtime dir with no XDG_RUNTIME_DIR')

local budget = runtime.name_budget()
H.ok(budget >= 8, 'runtime dir leaves a usable name budget')

local limit = vim.uv.os_uname().sysname == 'Linux' and 108 or 104
local longest = runtime.socket(string.rep('a', budget))
H.ok(#longest < limit, 'a max-budget socket path fits this platform sun_path limit')

-- libuv truncates an over-long sun_path silently: serverstart reports success
-- and the socket file never appears.
local started = pcall(vim.fn.serverstart, longest)
H.ok(started and vim.uv.fs_stat(longest) ~= nil, 'a max-budget socket really binds')
pcall(vim.fn.serverstop, longest)

H.eq(runtime.socket(string.rep('b', budget + 40)), runtime.socket(string.rep('b', budget)),
  'over-long names are truncated to the budget')

H.finish('runtime_spec')
