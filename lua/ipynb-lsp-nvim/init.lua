-- Real pyright LSP (diagnostics, hover, go-to-definition, completion) inside
-- .ipynb buffers, via a hidden "shadow" buffer with the exact same line count:
-- markdown-cell lines (and IPython magic lines) are blanked to "", code-cell
-- lines are copied verbatim. Because the two buffers always share identical
-- line numbers, nothing here ever needs to remap a position — "line N in the
-- shadow buffer" and "line N in the real buffer" are always the same line.
--
-- Design goal: write as little new LSP logic as possible. pyright's own
-- default diagnostic processing, its own hover rendering, and Neovim's own
-- location-jumping utilities all run untouched — this module only redirects
-- *which document* a request targets, never reimplements what happens after.
local M = {}

-- real_bufnr -> shadow_bufnr
local shadows = {}
local sync_timers = {}

local MIRROR_NS = vim.api.nvim_create_namespace("ipynb_lsp_diagnostics")

local function is_magic_line(line)
  return line:match("^%s*[%%!]") ~= nil
end

-- Blanks markdown-cell lines (including their header) and IPython magic
-- lines; copies code-cell lines (including their header, a valid Python
-- comment) verbatim. Same line count in, same line count out.
local function build_shadow_lines(real_lines)
  local ipynb = require("ipynb-nvim")
  local out, in_markdown = {}, false
  for i, line in ipairs(real_lines) do
    if ipynb.is_header(line) then
      in_markdown = ipynb.header_is_markdown(line)
      out[i] = in_markdown and "" or line
    elseif in_markdown or is_magic_line(line) then
      out[i] = ""
    else
      out[i] = line
    end
  end
  return out
end

local function sync_shadow(real_bufnr)
  local shadow_bufnr = shadows[real_bufnr]
  if not shadow_bufnr or not vim.api.nvim_buf_is_valid(shadow_bufnr) then
    return
  end
  local real_lines = vim.api.nvim_buf_get_lines(real_bufnr, 0, -1, false)
  vim.api.nvim_buf_set_lines(shadow_bufnr, 0, -1, false, build_shadow_lines(real_lines))
end

-- Immediate, non-debounced resync — used right after saving, so diagnostics
-- are guaranteed current at that moment rather than possibly lagging behind
-- the debounce timer below.
M.sync_now = sync_shadow

function M.schedule_sync(real_bufnr)
  local timer = sync_timers[real_bufnr]
  if not timer then
    timer = vim.uv.new_timer()
    sync_timers[real_bufnr] = timer
  end
  timer:stop()
  timer:start(250, 0, vim.schedule_wrap(function()
    sync_shadow(real_bufnr)
  end))
end

local function shadow_client(real_bufnr)
  local shadow_bufnr = shadows[real_bufnr]
  if not shadow_bufnr then
    return nil, nil
  end
  local client = vim.lsp.get_clients({ bufnr = shadow_bufnr, name = "pyright" })[1]
  return client, shadow_bufnr
end

local function cursor_params(shadow_bufnr)
  local pos = vim.api.nvim_win_get_cursor(0)
  return {
    textDocument = { uri = vim.uri_from_bufnr(shadow_bufnr) },
    position = { line = pos[1] - 1, character = pos[2] },
  }
end

-- Hover reuses Neovim's own default rendering (vim.lsp.handlers) completely
-- unmodified. The one thing that has to be corrected: the default handler
-- silently drops the response unless `api.nvim_get_current_buf() == ctx.bufnr`
-- — and `ctx.bufnr` is whatever bufnr the request was sent with, not derived
-- from the URI. So the request must be sent with `shadow_bufnr` (so Neovim
-- flushes that buffer's own pending edits before asking pyright), and
-- `ctx.bufnr` is then corrected to `real_bufnr` inside our own handler
-- wrapper, right before handing off to the default renderer.
function M.hover()
  local real_bufnr = vim.api.nvim_get_current_buf()
  local client, shadow_bufnr = shadow_client(real_bufnr)
  if not client then
    vim.notify("ipynb-lsp-nvim: pyright isn't attached yet", vim.log.levels.WARN)
    return
  end
  sync_shadow(real_bufnr)
  client:request("textDocument/hover", cursor_params(shadow_bufnr), function(err, result, ctx, config)
    ctx.bufnr = real_bufnr
    vim.lsp.handlers["textDocument/hover"](err, result, ctx, config)
  end, shadow_bufnr)
end

-- Definition has no reusable "default handler" to delegate to in modern
-- Neovim (vim.lsp.buf.definition() does its own request+jump inline, tightly
-- coupled to the current buffer) — so this rewrites shadow URIs back to the
-- real buffer's URI, then jumps using Neovim's own public jump utility.
-- A location pointing at a *different* file (stdlib, another project file)
-- needs no rewriting and jumps completely normally.
function M.goto_definition()
  local real_bufnr = vim.api.nvim_get_current_buf()
  local client, shadow_bufnr = shadow_client(real_bufnr)
  if not client then
    vim.notify("ipynb-lsp-nvim: pyright isn't attached yet", vim.log.levels.WARN)
    return
  end
  sync_shadow(real_bufnr)
  client:request("textDocument/definition", cursor_params(shadow_bufnr), function(err, result)
    if err or not result or vim.tbl_isempty(result) then
      vim.notify("ipynb-lsp-nvim: no definition found", vim.log.levels.INFO)
      return
    end

    local shadow_uri = vim.uri_from_bufnr(shadow_bufnr)
    local real_uri = vim.uri_from_bufnr(real_bufnr)
    local locations = vim.islist(result) and result or { result }
    for _, loc in ipairs(locations) do
      if loc.uri == shadow_uri then
        loc.uri = real_uri
      end
      if loc.targetUri == shadow_uri then
        loc.targetUri = real_uri
      end
    end

    if #locations == 1 then
      -- jump_to_location is deprecated as of 0.11 in favor of show_document.
      vim.lsp.util.show_document(locations[1], client.offset_encoding, { reuse_win = true, focus = true })
    else
      vim.fn.setqflist({}, " ", {
        title = "LSP definitions",
        items = vim.lsp.util.locations_to_items(locations, client.offset_encoding),
      })
      vim.cmd("copen")
    end
  end, shadow_bufnr)
end

-- Manual-invoke completion (<C-x><C-o>) for v1 — Neovim's native
-- vim.lsp.completion is hardcoded to the current window's buffer with no
-- redirection hook at all (verified against source), so autotrigger-on-`.`
-- isn't achievable without separately replicating trigger-character
-- watching; deliberately deferred rather than gold-plating v1. This
-- omnifunc still reuses Neovim's own completion-item formatter
-- (`vim.lsp.completion._lsp_to_complete_items`) — a private, underscore-
-- prefixed function that could change on a future Neovim upgrade; the
-- fallback if it ever breaks is a small hand-written CompletionItem mapping.
function M.omnifunc(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local start = col
    while start > 0 and line:sub(start, start):match("[%w_]") do
      start = start - 1
    end
    return start
  end

  local real_bufnr = vim.api.nvim_get_current_buf()
  local client, shadow_bufnr = shadow_client(real_bufnr)
  if not client then
    return {}
  end
  -- No sync_shadow() call here, unlike hover/goto_definition: Neovim
  -- disallows buffer mutation from inside an omnifunc callback (E565
  -- "Not allowed to change text or change window", confirmed by actually
  -- triggering completion in insert mode, not just reasoning about it).
  -- The debounced TextChangedI sync (fired on every keystroke while typing)
  -- has virtually always already caught the shadow buffer up by the time a
  -- user pauses to invoke completion.

  local response = client:request_sync("textDocument/completion", cursor_params(shadow_bufnr), 2000, shadow_bufnr)
  if not response or not response.result then
    return {}
  end
  return vim.lsp.completion._lsp_to_complete_items(response.result, base, client.id)
end

-- Creates the shadow buffer for a real notebook buffer, starts pyright
-- against it, and wires diagnostic mirroring. Called once per real buffer
-- (from ftplugin/ipynb.lua).
function M.attach(real_bufnr)
  if shadows[real_bufnr] then
    return
  end

  local real_name = vim.api.nvim_buf_get_name(real_bufnr)
  local shadow_bufnr = vim.api.nvim_create_buf(false, true) -- unlisted, scratch
  vim.api.nvim_buf_set_name(shadow_bufnr, real_name .. ".shadow.py")
  vim.bo[shadow_bufnr].buftype = "nofile"
  vim.bo[shadow_bufnr].filetype = "python"
  vim.b[shadow_bufnr].ipynb_shadow = true
  shadows[real_bufnr] = shadow_bufnr

  sync_shadow(real_bufnr)

  -- automatic_enable's FileType-triggered attach silently skips
  -- buftype=nofile buffers, so pyright is started manually here instead —
  -- vim.lsp.start itself is a first-class native API, not a custom client.
  local pyright_config = vim.lsp.config.pyright
  if pyright_config then
    local overrides = {}
    -- Point pyright's analysis environment at the SAME venv ipynb-run-nvim
    -- actually executes cells in — otherwise pyright analyzes against
    -- whatever Python it auto-detects (often the system one), which can
    -- flag imports as "unresolved" for packages that are genuinely
    -- installed and working in the real kernel (confirmed empirically:
    -- matplotlib showed as unresolved against the wrong environment).
    local kernel_python = vim.fn.stdpath("data") .. "/ipynb-run-nvim/venv/bin/python"
    if vim.fn.filereadable(kernel_python) == 1 then
      overrides = { settings = { python = { pythonPath = kernel_python } } }
    end
    vim.lsp.start(vim.tbl_deep_extend("force", pyright_config, overrides), { bufnr = shadow_bufnr })
  else
    vim.notify("ipynb-lsp-nvim: pyright isn't configured (check mason-lspconfig setup)", vim.log.levels.WARN)
  end

  -- pyright's own diagnostics run completely normally against the shadow
  -- buffer; this just copies Neovim's own already-computed diagnostic items
  -- onto the real buffer whenever they change. Safe verbatim copy: line
  -- positions are already resolved as absolute offsets against text that's
  -- identical between the two buffers by construction.
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    buffer = shadow_bufnr,
    callback = function()
      vim.diagnostic.set(MIRROR_NS, real_bufnr, vim.diagnostic.get(shadow_bufnr))
    end,
  })

  vim.bo[real_bufnr].omnifunc = "v:lua.require'ipynb-lsp-nvim'.omnifunc"
end

function M.detach(real_bufnr)
  local shadow_bufnr = shadows[real_bufnr]
  if shadow_bufnr and vim.api.nvim_buf_is_valid(shadow_bufnr) then
    -- Deleting the buffer only detaches it from the client; since this
    -- client was started manually (vim.lsp.start, not the automatic
    -- vim.lsp.enable path), Neovim's "stop clients with zero attached
    -- buffers" bookkeeping doesn't apply to it — confirmed by testing: the
    -- pyright process kept running with 0 attached buffers until stopped
    -- explicitly here.
    local client = vim.lsp.get_clients({ bufnr = shadow_bufnr, name = "pyright" })[1]
    if client then
      client:stop()
    end
    vim.api.nvim_buf_delete(shadow_bufnr, { force = true })
  end
  shadows[real_bufnr] = nil
  local timer = sync_timers[real_bufnr]
  if timer then
    timer:stop()
    timer:close()
    sync_timers[real_bufnr] = nil
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("ipynb_lsp_nvim", { clear = true })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    pattern = "*.ipynb",
    callback = function(args)
      M.detach(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for real_bufnr, _ in pairs(shadows) do
        M.detach(real_bufnr)
      end
    end,
  })
end

return M
