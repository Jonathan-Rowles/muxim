local H = dofile('tests/helper.lua')
local remote = require('muxim.remote')

H.eq(remote.blocking_edit('/repo/.git/COMMIT_EDITMSG'), true, 'a git commit message is a blocking edit')
H.eq(remote.blocking_edit('somewhere/MERGE_MSG'), true, 'so is a merge message, wherever it lives')
H.eq(remote.blocking_edit('/tmp/git-rebase-todo'), true, 'and a rebase todo')
H.eq(remote.blocking_edit('/repo/.git/any-file'), true, 'anything under .git blocks')
H.eq(remote.blocking_edit('.git/config'), true,
  'including RELATIVE .git paths: git config --edit hands the editor ".git/config" '
  .. 'from the toplevel, and routing it would make git accept the unedited file')
H.eq(remote.blocking_edit('/tmp/notes.txt'), false, 'an ordinary file does not')

H.eq(remote.route_to_parent(nil), false, 'no parent socket, no routing')
H.eq(remote.route_to_parent(''), false, 'an empty parent is no parent')

local work = H.runtime_dir() .. '/route-work'
vim.fn.mkdir(work, 'p')
vim.fn.writefile({ 'routed' }, work .. '/routed.txt')

vim.cmd('enew')
local job = vim.fn.jobstart({ vim.v.progpath, '-u', H.minimal_init(), '-i', 'NONE', 'routed.txt' },
  { term = true, cwd = work })
H.ok(job > 0, 'a nested nvim started inside a terminal, resolved however PATH resolved it')
local pid = vim.fn.jobpid(job)
H.ok(vim.wait(15000, function() return vim.fn.bufnr(work .. '/routed.txt') > 0 end, 100),
  'the nested instance hands its file to the owning session itself, so a shell rc '
  .. 'that buries the PATH wrapper under a real nvim cannot bring back the nested editor')
H.ok(H.wait_pid_gone(pid, 10000), 'and exits, leaving the shell prompt behind')

vim.cmd('enew')
vim.fn.mkdir(work .. '/.git', 'p')
vim.fn.writefile({ 'msg' }, work .. '/.git/COMMIT_EDITMSG')
local blocked = vim.fn.jobstart(
  { vim.v.progpath, '-u', H.minimal_init(), '-i', 'NONE', '.git/COMMIT_EDITMSG' },
  { term = true, cwd = work })
H.ok(blocked > 0, 'a nested nvim on a commit message started')
local blocked_pid = vim.fn.jobpid(blocked)
H.eq(vim.wait(3000, function() return not H.pid_alive(blocked_pid) end, 100), false,
  'a git commit message keeps the real blocking editor: routing it away would make '
  .. 'git see an instant exit and abort the commit, the bug the wrapper denylist already guards')
vim.fn.jobstop(blocked)

vim.cmd('enew')
local flagged = vim.fn.jobstart(
  { vim.v.progpath, '-u', H.minimal_init(), '-i', 'NONE', '-R', 'routed.txt' },
  { term = true, cwd = work })
H.ok(flagged > 0, 'a nested nvim with an editing flag started')
local flagged_pid = vim.fn.jobpid(flagged)
H.eq(vim.wait(3000, function() return not H.pid_alive(flagged_pid) end, 100), false,
  'any flag beyond config selection means the user wants a real editor here, so it stays')
vim.fn.jobstop(flagged)

H.finish('nested_route_spec')
