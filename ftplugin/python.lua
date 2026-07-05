-- Auto-sourced by Neovim whenever a buffer's filetype is set to "python"
-- (see :h ftplugin) — i.e. any .py file, not just marimo notebooks. There's
-- deliberately no "is this actually a marimo notebook" detection: pressing
-- <leader>nr on a plain/empty .py file is exactly how you'd start a brand
-- new marimo notebook in the first place, so there's no real file to
-- distinguish. Harmless on an ordinary script if never invoked.
local marimo = require("marimo-nvim")
local opts = { buffer = true }

vim.keymap.set("n", "<leader>nr", marimo.launch, vim.tbl_extend("force", opts, {
  desc = "Launch marimo for this file (browser output)",
}))
vim.keymap.set("n", "<leader>na", marimo.new_cell, vim.tbl_extend("force", opts, {
  desc = "Insert a new @app.cell",
}))
