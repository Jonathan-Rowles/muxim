vim.o.swapfile = false
vim.o.shell = '/bin/sh'
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
require('muxim.agents').SWEEP_MS = false
require('muxim').setup({ prefix = '<C-a>' })
