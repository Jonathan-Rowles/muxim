if vim.g.loaded_muxim then
  return
end
vim.g.loaded_muxim = true

if vim.fn.has('nvim-0.12') == 0 then
  return
end

local function default_setup()
  local muxim = require('muxim')
  if not muxim.setup_called then
    muxim.setup()
  end
  if vim.g.muxim_nested then
    require('muxim.remote').route_to_parent()
  end
end

if vim.v.vim_did_enter == 1 then
  vim.schedule(default_setup)
else
  vim.api.nvim_create_autocmd('VimEnter', {
    group = vim.api.nvim_create_augroup('muxim_default_setup', { clear = true }),
    once = true,
    callback = default_setup,
  })
end
