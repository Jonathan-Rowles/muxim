local H = dofile('tests/helper.lua')

local sock = H.runtime_dir() .. '/insert.sock'
local file_a = H.runtime_dir() .. '/insert-a.txt'
local file_b = H.runtime_dir() .. '/insert-b.txt'
vim.fn.writefile({ 'a' }, file_a)
vim.fn.writefile({ 'b' }, file_b)

local job = vim.fn.jobstart({
  vim.v.progpath, '--listen', sock, '-u', H.minimal_init(), '-i', 'NONE', file_a,
}, { term = true, env = { NVIM = '' } })
H.ok(job > 0, 'a real nvim with a real pty started inside a terminal buffer')
H.ok(H.wait_live(sock, 10000), 'and is listening')

local function remote(args)
  local cmd = { vim.v.progpath, '--server', sock }
  vim.list_extend(cmd, args)
  return vim.trim(vim.fn.system(cmd))
end

local function expr(e)
  return remote({ '--remote-expr', e })
end

local function lua(chunk)
  return expr(("luaeval('(function() %s end)()')"):format(chunk))
end

local function mode()
  return expr('mode(1)')
end

H.ok(vim.wait(10000, function() return expr('v:vim_did_enter') == '1' end, 50),
  'and has finished startup, since the server answers RPC before sourcing its config')

local function settles_on(want, label)
  local last
  vim.wait(5000, function()
    last = mode()
    return last == want
  end, 50)
  H.eq(last, want, label)
end

local function send(keys)
  remote({ '--remote-send', keys })
end

lua('require("muxim.terminal").enter_insert = true')
settles_on('n', 'the inner nvim starts in normal mode on a file')

lua('require("muxim.terminal").toggle()')
settles_on('t', 'toggling the terminal on puts it in terminal mode')

send('<C-\\><C-n>')
settles_on('nt', 'escaping leaves terminal-normal mode, as any escape mapping would')

send('<C-\\><C-n>:vsplit ' .. file_b .. '<CR>')
settles_on('n', 'a file window is a file window')

send('<C-\\><C-n>:wincmd w<CR>')
settles_on('t', 'coming back to the terminal window enters terminal mode again')

local function scrolled_back()
  return expr('luaeval(\'require("muxim.terminal").reading_scrollback('
    .. 'vim.api.nvim_get_current_buf()) and "yes" or "no"\')')
end

H.eq(scrolled_back(), 'no', 'a terminal sitting at its prompt is not scrolled back')
send('seq 1 500<CR>')
H.ok(vim.wait(5000, function() return scrolled_back() == 'no' end, 50),
  'the output arrives without moving the view off the bottom')
send('<C-\\><C-n>:normal! gg<CR>')
H.ok(vim.wait(5000, function() return scrolled_back() == 'yes' end, 50),
  'scrolling up through 500 lines of output is reading scrollback')

send('<C-\\><C-n>:wincmd w<CR>')
settles_on('n', 'leaving for the file window')
send('<C-\\><C-n>:wincmd w<CR>')
settles_on('nt', 'coming back while scrolled back leaves the position alone')

send('<C-\\><C-n>:normal! G<CR>')
send('<C-\\><C-n>:wincmd w<CR>')
settles_on('n', 'over to the file window again')
send('<C-\\><C-n>:wincmd w<CR>')
settles_on('t', 'back at the bottom, terminal mode resumes')

send([[<C-\><C-n>:lua vim.api.nvim_exec_autocmds('WinEnter', {}); vim.wait(300);]]
  .. [[ vim.cmd('new'); vim.bo.buftype = 'nofile'; vim.bo.modifiable = false<CR>]])
settles_on('n', 'a nomodifiable buffer opened from the terminal window stays in normal mode')
H.eq(expr('v:errmsg'), '', 'and no E21 from a queued startinsert landing in it')
send('<C-\\><C-n>:bwipeout!<CR>')

lua('require("muxim.terminal").enter_insert = false')
send('<C-\\><C-n>:wincmd w<CR>')
settles_on('n', 'off to the file window with the option off')
send('<C-\\><C-n>:wincmd w<CR>')
settles_on('nt', 'with enter_insert off, nothing enters terminal mode for you')

remote({ '--remote-send', '<C-\\><C-n>:qall!<CR>' })
vim.fn.jobstop(job)

H.finish('terminal_insert_spec')
