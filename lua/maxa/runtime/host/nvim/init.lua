-- filepath: lua/maxa/runtime/host/nvim/init.lua
--- maxa runtime host for Neovim: minimal Chat view (phase 0).
---
--- Scope (see .supermax/drafts/phase0-development-plan.md §5.7): this module
--- provides the minimal runnable Chat surface on top of the phase-0
--- `session` + `orchestrator` + `protocol` + `events` modules. It supports:
---
---   `:MaxaChat`   open (or focus) the Chat window pair
---   :MaxaStop     cancel the in-flight provider stream/tool batch (hard cancel;
---                 terminal cancelled, no continuation marker — old semantics kept)
---   :MaxaSoftStop drain the current response/tool batch, then suppress
---                 automatic continuation (never cancels the provider/tools)
---   :MaxaContextStop <percent|+N|off>  arm one-shot context-limit stop:
---                 at the target usage ratio request a soft stop (busy) or
---                 block the next automatic submit (idle); "off" disarms
---   :MaxaClose    close the Chat window pair + destroy the session
---   :MaxaProvider switch provider (default "mock"): mock | echo | deepseek-chat |
---                 deepseek-responses | deepseek-anthropic (W10: real providers
---                 resolve through the effective LazyVim opts config + protocol adapters)
---   :MaxaModel    switch display model label (default "mock-model")
---   :MaxaClear    clear the rendered messages (keeps session + current provider/model)
---
--- It is a pure *consumer* of the shared phase-0 contracts (§4 of the plan). It
--- does NOT reimplement the state machine (session/orchestrator own that) and it
--- never loads `codecompanion.*` / `mcphub.*` / `lua/util/hooks/*`. Provider/model
--- switching only re-arms the orchestrator's provider. Real provider binding (W10):
--- `View:set_provider` falls back to `config.resolve_provider(config.effective, name)`
--- (effective config = lua/maxa defaults + LazyVim opts), binds the protocol adapter,
--- and hands the orchestrator pre-built adapter params (flattened timeouts + anthropic
--- url/headers).
---
--- Design notes:
---   * `submit(text, opts)` is UI-independent: it works headlessly (no window pair
---     required) so deterministic smoke tests / recordings can drive it directly.
---     `opts.async=false` (default) drives the provider synchronously and returns
---     the orchestrator result; `opts.async=true` drives it via the nvim timer so
---     the streaming renderer updates progressively (the UI-visible path).
---   * The window pair is a `snacks` floating layout (R-01 rework): a vertical box
---     with a `chat` window on top and an `input` window below, both created via
---     `snacks.win` and arranged by `snacks.layout.new`. Open/close plumbing
---     delegates to snacks; this module keeps owning the buffers (`_buf` /
---     integrated input area at the buffer tail) and its keymaps.
---   * Rendering (chat-ui-render, phase 1.5 subpackage 3.1) builds the full
---     target line set from the internal `items` message model (role + text +
---     reasoning + tool_calls) and applies it with a minimal diff: streaming
---     deltas append in place (`nvim_buf_set_text`, see host/nvim/render.lua),
---     structural changes replace only the diverging range. The chat buffer is
---     markdown-treesitter highlighted, decorated with
---     header/separator extmarks, and owned solely by this module. The input
---     buffer is a separate scratch buffer.
---   * Closing the layout externally (e.g. `:q` on a float) tears down the UI
---     references but keeps the session alive, so `:MaxaChat` / `open()` rebuilds
---     the window pair; only `:MaxaClose` / `View:close()` destroys the session.
---   * Streaming is observed through the shared event bus (`events.on`): the view
---     listens for `response.started` / `message.delta` / terminal events and
---     re-renders accordingly. Subscriptions are torn down on `close()`.
---
--- Wiring (`:MaxaChat` command) is registered by `setup()`, which `load` calls so
--- the command exists whenever this module is required. Startup auto-load of this
--- module is the integrator's concern (validated/committed by the main agent),
--- not a responsibility of this file.

local guard = require("maxa.runtime.guard")

local orchestrator = guard.require("maxa.runtime.orchestrator")
local protocol = guard.require("maxa.runtime.protocol")
local events = guard.require("maxa.runtime.events")
local schema = guard.require("maxa.runtime.schema")
local config = guard.require("maxa.runtime.config")
-- chat-ui-render (phase 1.5 subpackage 3.1): incremental buffer writer +
-- header/separator extmark decorations + streaming cursor virtual text.
local render = guard.require("maxa.runtime.host.nvim.render")
-- chat-ui-status (phase 1.5 subpackage 3.5): read-only global status/spinner
-- projection (lualine consumes the spine separately from Chat rendering).
local status = guard.require("maxa.runtime.host.nvim.status")

-- LazyVim ecosystem dependency for the floating window pair (see R-01 in the
-- phase-0 plan §10). `snacks` is an allowed environment dependency (not in the
-- guard's forbidden list: only codecompanion.* / mcphub.* / util.hooks.* are).
local snacks = require("snacks")

local M = {}

M.name = "host.nvim"
-- Input-area decoration namespace (chat-ui-input): intro placeholder virtual
-- text on the input buffer; never persisted into its content.
M.INPUT_NS = vim.api.nvim_create_namespace("maxa.chat.input")
-- Chat keymap registry (chat-ui-actions): buffer-local keymaps are registry
-- entries, not hard-coded orchestration callbacks (chat-ui spec). `fn` names a
-- View method; `args` are forwarded. Registered by `View:_register_keymaps`.
M.KEYMAPS = {
  { buf = "chat", mode = "i", keys = "<CR>", desc = "submit chat input", fn = "_submit_from_input" },
  { buf = "chat", mode = "n", keys = "<CR>", desc = "submit chat input", fn = "_submit_from_input" },
  { buf = "chat", mode = "i", keys = "<C-c>", desc = "cancel in-flight stream", fn = "stop" },
  { buf = "chat", mode = "i", keys = "<C-s>", desc = "soft-stop after current response/tools", fn = "soft_stop" },
  { buf = "chat", mode = "i", keys = "<C-g>", desc = "show keymap help", fn = "_show_keymap_help" },
  { buf = "chat", mode = "i", keys = "<Up>", desc = "recall older input", fn = "_history_nav", args = { -1 } },
  { buf = "chat", mode = "i", keys = "<Down>", desc = "recall newer input", fn = "_history_nav", args = { 1 } },
  { buf = "chat", mode = "v", keys = "ga", desc = "attach visual selection to input", fn = "_attach_selection" },
  { buf = "chat", mode = "n", keys = "q", desc = "stop in-flight stream", fn = "stop" },
  { buf = "chat", mode = "n", keys = "gs", desc = "soft-stop after current response/tools", fn = "soft_stop" },
  { buf = "chat", mode = "n", keys = "<C-c>", desc = "close chat view", fn = "close" },
  { buf = "chat", mode = "n", keys = "gx", desc = "clear chat messages", fn = "clear" },
  { buf = "chat", mode = "n", keys = "]]", desc = "next message header", fn = "_goto_header", args = { 1 } },
  { buf = "chat", mode = "n", keys = "[[", desc = "previous message header", fn = "_goto_header", args = { -1 } },
  { buf = "chat", mode = "n", keys = "g?", desc = "show keymap help", fn = "_show_keymap_help" },
}

-- (Repository-root derivation was previously used for dev `.maxa/runtime.yaml`
-- resolution. Configuration is now LazyVim opts and provider resolution goes
-- through config.effective; the dev-asset credential boundary lives in
-- lua/maxa/init.lua inject_dev_env. No M.ROOT export is needed anymore.)

-- Defaults (mock/echo providers; real adapters bind through config in W10).
M.DEFAULT_PROVIDER = protocol.providers.mock or "mock"
M.DEFAULT_MODEL = "mock-model"
-- ui.show_reasoning: false => reasoning renders as a collapsed summary line.
M.DEFAULT_SHOW_REASONING = false
-- Chat window layout (chat-ui layout): "vertical" (right-half split, default),
-- "horizontal" (bottom split), "float" (centered half-width float).
M.DEFAULT_LAYOUT = "vertical"

--- Override the view defaults from the maxa config.
--- Called by `require("maxa").setup`; keeps host free of a maxa/init circular require.
---@param opts? table { provider?: string, model?: string, show_reasoning?: boolean, layout?: string }
---@return table self
function M.set_defaults(opts)
  opts = opts or {}
  if opts.provider then
    M.DEFAULT_PROVIDER = opts.provider
  end
  if opts.model then
    M.DEFAULT_MODEL = opts.model
  end
  if opts.show_reasoning ~= nil then
    M.DEFAULT_SHOW_REASONING = not not opts.show_reasoning
  end
  if opts.layout then
    M.DEFAULT_LAYOUT = opts.layout
  end
  return M
end

-- UI text labels.
M.UI = {
  header_fmt = "[maxa] provider=%s model=%s session=%s",
  divider = string.rep("─", 48),
  user = "User",
  assistant = "Assistant",
  system = "System",
  tool = "Tool",
  -- W8 parts rendering labels.
  reasoning_header = "### Reasoning",
  response_header = "### Response",
  reasoning_summary_fmt = "[reasoning %d chars]",
  -- Tool status icons (chat-ui-folds): icon prefix + tool name.
  tool_pending_icon = "⏳",
  tool_in_progress_icon = "⚡",
  tool_completed_icon = "✅",
  tool_failed_icon = "❌",
  tool_call_fmt = "%s %s",
  -- Streaming-cursor virtual-text marker (never persisted into buffer content).
  cursor_marker = "▍",
  -- Input-area placeholder (chat-ui-input): shown only while the prompt is
  -- empty; never persisted into the input buffer.
  input_intro = "Ask anything… (Enter to send)",
  status_idle = "status: idle",
  status_busy = "status: busy (streaming…)",
  status_completed = "status: completed",
  status_failed = "status: failed",
  status_cancelled = "status: cancelled",
  status_soft_stop = "status: soft-stop requested",
  closed = "session closed",
}

--- Border for a docked split: only the inner edge facing the main editor is
--- drawn (right split -> left edge; bottom split -> top edge; left/top splits
--- are reserved for future layouts). Floats keep the full rounded border.
--- 8-element nvim border table: {tl, top, tr, right, br, bottom, bl, left}.
---@param position string|nil snacks layout position ("right"|"bottom"|"float")
---@return string|string[]
function M._edge_border(position)
  if position == "right" then
    return { " ", " ", " ", " ", " ", " ", " ", "│" } -- left edge only
  end
  if position == "left" then
    return { " ", " ", " ", "│", " ", " ", " ", " " } -- right edge only
  end
  if position == "bottom" then
    return { " ", "─", " ", " ", " ", " ", " ", " " } -- top edge only
  end
  if position == "top" then
    return { " ", " ", " ", " ", " ", "─", " ", " " } -- bottom edge only
  end
  return "rounded"
end

---@private Tool status -> UI icon (chat-ui-folds). Unknown statuses fall back
--- to the pending icon.
function M.tool_icon(status)
  if status == "completed" then
    return M.UI.tool_completed_icon
  end
  if status == "failed" then
    return M.UI.tool_failed_icon
  end
  if status == "in_progress" then
    return M.UI.tool_in_progress_icon
  end
  return M.UI.tool_pending_icon
end
---------------------------------------------------------------------------
-- View instance
---------------------------------------------------------------------------
local View = {}
View.__index = View

-- W8: registry of live view instances (for best-effort nvim-exit teardown).
-- Views register in M.new and unregister on close()/shutdown(); M.shutdown()
-- iterates the registry so every owned orchestrator/handle is closed at exit.
M._views = {}

-- W8: VimLeavePre hook registration is lazy (first view creation) so requiring
-- the host module headless has no autocmd side effects.
local _exit_hook_registered = false
local function ensure_exit_hook()
  if _exit_hook_registered then
    return
  end
  _exit_hook_registered = true
  pcall(vim.api.nvim_create_autocmd, "VimLeavePre", {
    callback = function()
      M.shutdown()
    end,
    desc = "maxa: best-effort runtime shutdown (cancel owned handles)",
  })
end

--- Create a Chat view. UI is lazy: the window pair is only created by `open()`.
---@param opts? table {
---   provider?:    string provider name (default "mock"),
---   model?:       string model label (default "mock-model"),
---   events?:      table event bus (default: global events module),
---   auto_open?:   boolean open the window pair immediately (default false),
---   provider_params?: table forwarded to provider.stream on each submit,
--- }
---@return table view
---@private Resolve a provider for a fresh view (or set_provider): built-in
--- (mock/echo) via the protocol registry; real providers via the effective
--- LazyVim opts config (config.effective). Mirrors View:set_provider.
---@param name string provider name
---@return table|nil provider built-in provider adapter (mock/echo path)
---@return table|nil record config provider record (real path, adapter bound)
---@return table|nil params pre-built adapter setup params (real path)
---@return table|nil err resolve failure (unknown provider / no adapter)
local function resolve_provider_for_view(name)
  local ok_pc, provider = pcall(protocol.get, name)
  if ok_pc and type(provider) == "table" then
    return provider, nil, nil, nil
  end
  local record, rerr = config.resolve_provider(config.effective, name)
  if not record then
    return nil, nil, nil, rerr
  end
  if not record.adapter then
    pcall(require, "maxa.runtime.protocol.adapters." .. record.protocol)
    local adapter = protocol.get_adapter(record.protocol)
    if adapter then
      record:bind(adapter)
    end
  end
  if not record.adapter then
    return nil,
      nil,
      nil,
      {
        message = ("no adapter for provider %q (protocol %s)"):format(tostring(name), tostring(record.protocol)),
      }
  end
  local params = {
    model = record.model,
    stream = true,
    base_url = record.base_url,
    api_key_env = record.api_key_env,
    connect_timeout_ms = record.request and record.request.connect_timeout_ms,
    timeout_ms = record.request and record.request.timeout_ms,
    proxy_env = record.request and record.request.proxy_env,
  }
  if record.protocol == "anthropic_messages" then
    params.url = record.base_url:gsub("/+$", "") .. "/v1/messages"
    params.headers = {
      ["content-type"] = "application/json",
      ["x-api-key"] = os.getenv(record.api_key_env or ""),
    }
  end
  return nil, record, params, nil
end
function M.new(opts)
  opts = opts or {}
  local bus = opts.events or events
  local provider_name = opts.provider or M.DEFAULT_PROVIDER
  local provider, record, params, rerr = resolve_provider_for_view(provider_name)

  -- The orchestrator owns the stream loop and asserts that a provider is attached
  -- before the first submit, so attach the initial provider before returning.
  local orch = orchestrator.new({
    model = opts.model or M.DEFAULT_MODEL,
    events = bus,
  })
  if record then
    -- Real provider (W10.2): the orchestrator binds the adapter when the key is
    -- available, otherwise falls back to the local mock (offline dev keeps the
    -- UI usable); the record model label is applied either way.
    orch:use_provider_record(record, { params = params })
  elseif provider then
    orch:use_provider(provider)
  else
    -- Unknown provider: keep the UI usable with the local mock and surface the
    -- resolve error (non-terminal) instead of failing view creation.
    orch:use_provider(protocol.get("mock"))
  end

  local self = setmetatable({
    orch = orch,
    provider = orch.provider,
    provider_name = provider_name,
    model = (record and record.model) or opts.model or M.DEFAULT_MODEL,
    events = bus,
    provider_params = opts.provider_params or {},
    items = {}, -- ordered message model { role=string, text=string,
    --             reasoning=string, tool_calls=table[] }
    status = "idle", -- idle | busy | completed | failed | cancelled | closed
    soft_stop = false, -- W6: soft stop requested (manual or context-stop); the
    -- status projection shows "soft-stop requested" once the drain boundary lands
    usage = nil, -- latest/final normalized usage (W8: schema.usage snapshot)
    show_reasoning = (opts.show_reasoning == nil) and M.DEFAULT_SHOW_REASONING or not not opts.show_reasoning,
    layout = opts.layout or M.DEFAULT_LAYOUT,
    errors = {}, -- non-terminal informational errors surfaced to the user
    -- UI buffers/windows (nil until open()).
    _opened = false,
    _buf = nil,
    _chat_win = nil,
    -- Input history (chat-ui-input): session-scoped prompt history + cursor
    -- into it for <Up>/<Down> recall; nil index means a fresh prompt.
    _input_history = {},
    _input_history_idx = nil,
    -- Rendered-region row count (chat-ui-input): rows 1.._render_end belong to
    -- the message render; the input area (header + user input) follows after.
    _render_end = 0,
    -- snacks layout + win objects (see open() / _reset_ui_refs()).
    _layout = nil,
    _chat_obj = nil,
    -- subscriptions, torn down on close().
    _subs = {},
    -- how the most recent submit is driven (async used by UI; sync for headless).
    _async = false,
    -- chat-ui-render state: render revision (bumped on structural changes only,
    -- so streaming deltas within one revision append exclusively), diff stats
    -- (observable for the incremental-append contract), follow-to-bottom, and
    -- the bound chat buffer / treesitter attach flag.
    _render_revision = 0,
    _render_stats = { appends = 0, rewrites = 0, noops = 0 },
    _follow = true,
    _bound_buf = nil,
    _ts_attached = false,
    -- W8: session View entity bound at open() (attached to the chat buffer);
    -- detach() releases it without touching the session/request.
    _session_view = nil,
  }, View)
  if rerr then
    self.errors[#self.errors + 1] = {
      message = ("provider %q: %s"):format(tostring(provider_name), tostring(rerr.message or "resolve failed")),
    }
  end

  self:_subscribe()
  ensure_exit_hook()
  M._views[#M._views + 1] = self
  if opts.auto_open then
    self:open()
  end
  return self
end

--- The global/default view instance (lazy). `:MaxaChat` operates on it.
M._default = nil

---@private
function M._get_default()
  if not M._default or M._default:_is_closed_view() then
    M._default = M.new()
  end
  return M._default
end

---@private
function View:_is_closed_view()
  return self.status == "closed"
end

---@private Ensure the session View entity exists for the current chat buffer
--- (W8 async-lifecycle view ownership). Created at open() with the real buffer
--- number; headless consumers (tests) may attach a synthetic bufnr. A detached
--- or closed previous entity gets a FRESH identity on the next open (views are
--- per-attachment; the session keeps the old record for audit).
---@param bufnr integer|nil chat buffer number
---@return table|nil view entity
function View:_attach_session_view(bufnr)
  local cur = self._session_view
  if cur and (cur.state == "attached" or cur.state == "hidden") then
    return cur
  end
  local v, err = self.orch.session:new_view({ bufnr = bufnr })
  if not v then
    self.errors[#self.errors + 1] = err
    return nil
  end
  self._session_view = v
  return v
end

--- Detach the view from the session (W8 view-delete): the buffer/window is
--- gone, the session View entity moves to detached, and ALL UI references are
--- dropped. The session and any in-flight request CONTINUE unaffected — later
--- renders become inert (no valid buffer) and projections stay pure state.
--- Idempotent: repeated detach (buffer delete + layout close) is a no-op.
---@param reason? string diagnostic reason (default "buffer/window deleted")
---@return boolean changed true when this call performed the detach
function View:detach(reason)
  if self:_is_closed_view() then
    return false
  end
  local changed = false
  if self._session_view then
    changed = self.orch.session:detach_view(self._session_view, reason) or changed
  end
  self:_reset_ui_refs()
  return changed
end

---@private Register streaming / session events. Unsubscribes are retained for close().
function View:_subscribe()
  local on = self.events.on
  local function sub(ev, cb)
    local off = on(ev, cb)
    self._subs[#self._subs + 1] = off
  end

  -- W8: request.started arrives paired with response.started; _begin_stream is
  -- idempotent (status=busy, assistant item reused), so both subscriptions are safe.
  sub(self.events.events.request_started or "request.started", function()
    self:_begin_stream()
  end)
  sub(self.events.events.response_started or "response.started", function()
    self:_begin_stream()
  end)
  sub(self.events.events.message_delta or "message.delta", function(payload)
    self:_on_delta(payload)
  end)
  -- W8 parts events drive the parts renderer.
  sub(self.events.events.reasoning_delta or "reasoning.delta", function(payload)
    self:_on_reasoning_delta(payload)
  end)
  sub(self.events.events.tool_call_started or "tool_call.started", function(payload)
    self:_on_tool_call_started(payload)
  end)
  sub(self.events.events.tool_call_delta or "tool_call.delta", function()
    -- Argument fragments do not change the status-line projection; render is
    -- driven by started/completed. Subscribed (no-op) so the bus stays warm for
    -- later phases that show argument previews.
  end)
  sub(self.events.events.tool_call_completed or "tool_call.completed", function(payload)
    self:_on_tool_call_completed(payload)
  end)
  sub(self.events.events.usage_updated or "usage.updated", function(payload)
    self:_on_usage_updated(payload)
  end)
  -- W6 soft-stop request state (manual request / toggle-off / context-stop
  -- trigger). Mirrors the orchestrator flag so the status projection shows
  -- "soft-stop requested" while the current response/tool batch drains.
  sub(self.events.events.soft_stop_requested or "chat.soft_stop_requested", function(payload)
    self.soft_stop = not not (payload and payload.requested)
    self:_render()
  end)
  -- W6 soft-stop completion boundary: the drain consumed the request; the
  -- session landed at waiting_for_user (or stopped/closed). Clear the flag.
  sub(self.events.events.soft_stop_completed or "chat.soft_stop_completed", function()
    self.soft_stop = false
    self:_render()
  end)
  -- Terminal success.
  sub(self.events.events.response_completed or "response.completed", function(payload)
    self.status = "completed"
    self.soft_stop = false
    if payload and payload.usage then
      self.usage = payload.usage
    end
    self._async = false
    self:_render()
  end)
  -- Terminal failure (provider/protocol/timeout).
  sub(self.events.events.response_failed or "response.failed", function(payload)
    self.status = "failed"
    self.soft_stop = false
    self.errors[#self.errors + 1] = (payload and payload.error) or { message = "unknown failure" }
    self._async = false
    self:_render()
  end)
  -- Terminal cancel (via :MaxaStop / provider auto-cancel).
  sub(self.events.events.response_cancelled or "response.cancelled", function(payload)
    self.status = "cancelled"
    self.soft_stop = false
    self._async = false
    self:_render()
  end)
  -- Explicit session close (orchestrator:close / :MaxaClose).
  sub(self.events.events.chat_closed or "chat.closed", function()
    self.status = "closed"
    self._async = false
    self:_render()
  end)
end

---@private Ensure the in-flight assistant item exists and return it. Creates a
--- parts-capable item (text/reasoning/tool_calls) when the last item is not an
--- assistant turn (e.g. right after the user turn was appended).
function View:_assistant_item()
  local last = self.items[#self.items]
  if last and last.role == "assistant" then
    return last
  end
  local item = { role = "assistant", text = "", reasoning = "", tool_calls = {} }
  self.items[#self.items + 1] = item
  return item
end

---@private Reset stream-state before a new assistant turn starts.
function View:_begin_stream()
  if self.status == "closed" then
    return
  end
  self.status = "busy"
  local item = self:_assistant_item()
  if item.pending then
    item.pending = nil
  end
  -- Structural change: a new assistant turn started (new render revision).
  self._render_revision = self._render_revision + 1
  self:_render()
end

---@private Incremental assistant text update from message.delta (full accumulated text).
function View:_on_delta(payload)
  if self.status == "closed" then
    return
  end
  local item = self:_assistant_item()
  local text = (payload and payload.text) or (payload and payload.delta) or ""
  if text ~= "" then
    if payload and payload.text then
      item.text = text -- full accumulated text replaces (orchestrator always sends it)
    else
      item.text = (item.text or "") .. text
    end
  end
  item.pending = nil
  self:_render()
end

---@private Incremental reasoning update from reasoning.delta (W8).
function View:_on_reasoning_delta(payload)
  if self.status == "closed" then
    return
  end
  local item = self:_assistant_item()
  if payload and type(payload.text) == "string" then
    item.reasoning = payload.text -- full accumulated reasoning wins when provided
  else
    item.reasoning = (item.reasoning or "") .. ((payload and payload.delta) or "")
  end
  self:_render()
end

---@private Track a started tool call (W8; recorded only, never executed).
function View:_on_tool_call_started(payload)
  if self.status == "closed" then
    return
  end
  local item = self:_assistant_item()
  local call_id = payload and payload.call_id
  local found = false
  for _, c in ipairs(item.tool_calls or {}) do
    if c.call_id == call_id then
      found = true
      break
    end
  end
  if not found and call_id then
    item.tool_calls[#item.tool_calls + 1] = {
      call_id = call_id,
      name = (payload and payload.name) or "?",
      status = "started",
    }
  end
  self:_render()
end

---@private Mark a tool call completed (W8).
function View:_on_tool_call_completed(payload)
  if self.status == "closed" then
    return
  end
  local item = self:_assistant_item()
  local call_id = payload and payload.call_id
  for _, c in ipairs(item.tool_calls or {}) do
    if c.call_id == call_id then
      c.status = "completed"
    end
  end
  self:_render()
end

---@private Track the latest normalized usage snapshot (W8; final one wins on
--- response.completed, so this only feeds the live status line).
function View:_on_usage_updated(payload)
  if self.status == "closed" then
    return
  end
  if payload and payload.usage then
    self.usage = payload.usage
  end
  self:_render()
end

---------------------------------------------------------------------------
-- Commands / lifecycle
---------------------------------------------------------------------------

--- Open (or focus) the Chat window pair. Builds a `snacks` floating layout
--- (chat window on top, input window below) on first open; afterwards, or when
--- the layout was closed externally, it just rebuilds / refocuses it.
---@return boolean opened true when the window pair was (re)opened
function View:open()
  if self.status == "closed" then
    return false
  end
  if self._layout and self._layout:valid() then
    self:_focus_open_windows()
    return true
  end
  -- Single chat buffer (chat-ui-input integrated input area): the whole buffer
  -- is modifiable; the rendered message region is rewritten by _render while
  -- the input area (header line + user input) at the tail is user-owned.
  local chat_obj = snacks.win({
    show = false,
    position = "float",
    enter = false,
    bo = { modifiable = true, buftype = "nofile", swapfile = false },
  })
  -- Window layout (chat-ui layout): default "vertical" = right-half split;
  -- "horizontal" = bottom split; "float" = centered half-width float.
  local placement
  if self.layout == "horizontal" then
    placement = { position = "bottom", height = 0.5 }
  elseif self.layout == "float" then
    placement = { position = "float", width = 0.5, height = 0.8 }
  else
    placement = { position = "right", width = 0.5 }
  end
  local layout = snacks.layout.new({
    show = false,
    wins = { chat = chat_obj },
    layout = vim.tbl_deep_extend("force", placement, {
      box = "vertical",
      { win = "chat", border = M._edge_border(placement.position) },
    }),
    on_close = function()
      -- External close (e.g. `:q`): W8 view-delete — detach the view (session
      -- View entity -> detached) and drop the UI refs; the session stays alive
      -- so the next `:MaxaChat` / `open()` rebuilds the layout.
      self:detach("layout closed")
    end,
  })
  layout:show()
  -- Capture the snack-created buffer/window after showing the layout.
  self._layout = layout
  self._chat_obj = chat_obj
  self._buf = chat_obj.buf
  self._chat_win = chat_obj.win
  self._opened = true
  -- W8: bind the session View entity to this chat buffer (created at open;
  -- headless consumers can attach a synthetic bufnr without a window pair).
  self:_attach_session_view(self._buf)
  -- chat-ui-render: attach markdown treesitter + decorations + follow autocmd
  -- to the chat buffer before the first render.
  self:_bind_render_buffer(self._buf, self._chat_win)
  self:_init_input_area()
  self:_add_input_mappings()
  self:_refresh_input_intro()
  self:_render()
  -- chat-ui-status: this view is now the one lualine projects.
  status.set_active_view(self)
  self:_focus_open_windows()
  vim.cmd("startinsert")
  return true
end

---@private Focus the already-open window pair (idempotent reopen).
---@private Focus the chat window (idempotent reopen).
function View:_focus_open_windows()
  if self._chat_win and vim.api.nvim_win_is_valid(self._chat_win) then
    vim.api.nvim_set_current_win(self._chat_win)
  end
end

---@private Drop all UI (window pair) references without destroying the session.
--- Used both by `close()` and by the layout's `on_close` (external `:q` close),
--- so an already-destroyed layout never leaves stale buffer/window handles.
---@private Drop all UI references without destroying the session.
--- Used both by `close()` and by the layout's `on_close` (external `:q` close),
--- so an already-destroyed layout never leaves stale buffer/window handles.
function View:_reset_ui_refs()
  self._layout = nil
  self._chat_obj = nil
  self._buf = nil
  self._chat_win = nil
  self._opened = false
end

---@private Bind `<CR>` submit mapping (and safe insert-mode Ctrl-C stop) to the input buffer.
---@private Register all buffer-local keymaps from the M.KEYMAPS registry
--- (chat-ui-actions) plus the input-area growth/intro autocmd. The historical
--- name is kept for tests; keymaps themselves now come from the registry.
---@private Initialize the integrated input area at the tail of the chat buffer:
--- the input header line + one blank content line (chat-ui-input; CodeCompanion
--- ready_chat_buffer semantics). Runs once per open() on the fresh buffer; the
--- rendered region starts empty (0 rows), so the input area is rows 1..2.
function View:_init_input_area()
  local buf = self._buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- Idempotent: if the input header is already the first row, leave the buffer
  -- untouched (scratch buffers start with one blank row, so a row-count guard
  -- would wrongly skip initialization).
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines > 0 and lines[1] == M.UI.user then
    return
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { M.UI.user, "" })
end
function View:_add_input_mappings()
  self:_register_keymaps()
  local buf = self._buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- Input area growth + intro placeholder refresh (chat-ui-input): when the
  -- input content exceeds a few rows the chat float grows up to a sane cap.
  local group = vim.api.nvim_create_augroup("maxa_chat_input", { clear = false })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = buf,
    group = group,
    desc = "maxa: chat float grows with input content + intro refresh",
    callback = function()
      self:_refresh_input_intro()
      local win = self._chat_win
      if not win or not vim.api.nvim_win_is_valid(win) then
        return
      end
      local n = vim.api.nvim_buf_line_count(buf)
      local area_rows = n - (self._render_end or 0)
      if area_rows > 4 then
        pcall(vim.api.nvim_win_set_height, win, math.min(n + 2, 24))
      end
    end,
  })
end

---@private Read the input buffer, clear it, and submit the captured text.
function View:_submit_from_input()
  local buf = self._buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) or self.status == "closed" then
    return
  end
  local render_end = self._render_end or 0
  local total = vim.api.nvim_buf_line_count(buf)
  if total <= render_end then
    return
  end
  -- Integrated input area: header line at render_end+1, user content after it.
  local area = vim.api.nvim_buf_get_lines(buf, render_end, -1, false)
  local cleaned = {}
  for i = 2, #area do
    local line = area[i]
    if line and line ~= "" then
      cleaned[#cleaned + 1] = line
    end
  end
  -- Clear the input content, keep the header line.
  vim.api.nvim_buf_set_lines(buf, render_end + 1, -1, false, { "" })
  self:_refresh_input_intro()
  if #cleaned == 0 then
    return
  end
  local text = table.concat(cleaned, "\n")
  self:_push_input_history(text)
  -- UI path: play the streams, but keep a small delay so chunks render progressively.
  self:submit(text, { async = true })
end
---@private Record a submitted prompt into the session input history (dedup of
--- consecutive identical prompts; chat-ui-input).
---@param text string
function View:_push_input_history(text)
  if text == nil or text == "" then
    return
  end
  if self._input_history[#self._input_history] == text then
    return
  end
  self._input_history[#self._input_history + 1] = text
  self._input_history_idx = nil
end

---@private Recall prompt history in the input buffer. `dir` is -1 (older) or
--- 1 (newer). Navigation applies only when the prompt is empty or when it is
--- already showing the recalled entry (so repeated <Up> walks the history and
--- <Down> returns towards a fresh prompt).
---@param dir integer
function View:_history_nav(dir)
  local h = self._input_history
  if #h == 0 then
    return
  end
  local buf = self._buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local render_end = self._render_end or 0
  local total = vim.api.nvim_buf_line_count(buf)
  if total <= render_end then
    return
  end
  local area = vim.api.nvim_buf_get_lines(buf, render_end, -1, false)
  local header = area[1] or M.UI.user
  local content = {}
  for i = 2, #area do
    content[#content + 1] = area[i]
  end
  local current = table.concat(content, "\n")
  local empty = #content == 0 or (#content == 1 and content[1] == "")
  local in_history = self._input_history_idx ~= nil and h[self._input_history_idx] == current
  if not empty and not in_history then
    return
  end
  local idx = self._input_history_idx
  if idx == nil then
    idx = dir < 0 and #h or 1 -- Up from a fresh prompt -> newest; Down -> oldest
  else
    idx = idx + dir
  end
  if idx < 1 or idx > #h then
    return
  end
  self._input_history_idx = idx
  local new_lines = { header }
  for part in h[idx]:gmatch("([^\n]*)\n?") do
    if part ~= "" or part:find("\n") then
      new_lines[#new_lines + 1] = part
    end
  end
  vim.api.nvim_buf_set_lines(buf, render_end, -1, false, new_lines)
  local win = self._chat_win
  if win and vim.api.nvim_win_is_valid(win) then
    local last = new_lines[#new_lines] or ""
    vim.api.nvim_win_set_cursor(win, { render_end + #new_lines, #last })
  end
  self:_refresh_input_intro()
end

---@private Refresh the intro placeholder virtual text on the input buffer:
--- visible only while the prompt is empty; never persisted into content.
function View:_refresh_input_intro()
  local buf = self._buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.INPUT_NS, 0, -1)
  local render_end = self._render_end or 0
  local total = vim.api.nvim_buf_line_count(buf)
  if total <= render_end then
    return
  end
  local area = vim.api.nvim_buf_get_lines(buf, render_end, -1, false)
  -- Empty input: header followed only by blank rows.
  local empty = true
  for i = 2, #area do
    if area[i] ~= "" then
      empty = false
      break
    end
  end
  if empty then
    if vim.api.nvim_buf_line_count(buf) <= render_end + 1 then
      vim.api.nvim_buf_set_lines(buf, render_end + 1, -1, false, { "" })
    end
    vim.api.nvim_buf_set_extmark(buf, M.INPUT_NS, render_end + 1, 0, {
      virt_text = { { M.UI.input_intro, "Comment" } },
      virt_text_pos = "overlay",
    })
  end
end

---@private Attach the chat buffer's visual selection to the input area as a
--- fenced code block (chat-ui-input). Column math uses byte columns, matching
--- `getpos()`/`string.sub` byte semantics.
function View:_attach_selection()
  local chat_buf = self._buf
  if not chat_buf or not vim.api.nvim_buf_is_valid(chat_buf) then
    return
  end
  local vpos = vim.fn.getpos("v")
  local cpos = vim.fn.getpos(".")
  if vpos[2] == 0 or cpos[2] == 0 then
    return
  end
  local start_row, start_col = math.min(vpos[2], cpos[2]), math.min(vpos[3], cpos[3])
  local end_row, end_col = math.max(vpos[2], cpos[2]), math.max(vpos[3], cpos[3])
  local m = vim.fn.mode()
  -- Linewise (V) / blockwise (^V) selections keep whole lines: their columns
  -- are anchors (1), not text boundaries, so trimming would corrupt content.
  if m == "V" or m == "\x16" then
    start_col, end_col = 1, nil
  end
  local lines = vim.api.nvim_buf_get_lines(chat_buf, start_row - 1, end_row, false)
  if #lines == 0 then
    return
  end
  if start_col > 1 then
    lines[1] = lines[1]:sub(start_col, -1)
  end
  if end_col and end_col < #lines[#lines] then
    lines[#lines] = lines[#lines]:sub(1, end_col)
  end
  local fenced = "```text\n" .. table.concat(lines, "\n") .. "\n```"
  -- Append the fenced block into the integrated input area (after the header).
  local render_end = self._render_end or 0
  local total = vim.api.nvim_buf_line_count(chat_buf)
  if total <= render_end then
    return
  end
  local area = vim.api.nvim_buf_get_lines(chat_buf, render_end, -1, false)
  local header = area[1] or M.UI.user
  local content = {}
  for i = 2, #area do
    content[#content + 1] = area[i]
  end
  local parts = vim.split(fenced, "\n", { plain = true })
  local new_lines = { header }
  for _, l in ipairs(content) do
    if l ~= "" then
      new_lines[#new_lines + 1] = l
    end
  end
  if #new_lines > 1 then
    new_lines[#new_lines + 1] = ""
  end
  for _, l in ipairs(parts) do
    new_lines[#new_lines + 1] = l
  end
  vim.api.nvim_buf_set_lines(chat_buf, render_end, -1, false, new_lines)
  self:_refresh_input_intro()
end
---@private Register every M.KEYMAPS entry on its target buffer (chat/input).
--- Registry entries carry mode/keys/desc/fn(+args); callbacks are bound to this
--- view instance (chat-ui-actions).
function View:_register_keymaps()
  local bufs = { chat = self._buf }
  for _, km in ipairs(M.KEYMAPS) do
    local buf = bufs[km.buf]
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.keymap.set(km.mode, km.keys, function()
        local fn = self[km.fn]
        if type(fn) == "function" then
          if km.args then
            fn(self, unpack(km.args))
          else
            fn(self)
          end
        end
      end, { buffer = buf, desc = km.desc })
    end
  end
end

---@private Move the chat cursor to the next (dir=1) / previous (dir=-1)
--- role-header line (User/Assistant/System/Tool) (chat-ui-actions).
function View:_goto_header(dir)
  local buf = self._buf
  local win = self._chat_win
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local count = vim.api.nvim_buf_line_count(buf)
  local labels = {
    [M.UI.user] = true,
    [M.UI.assistant] = true,
    [M.UI.system] = true,
    [M.UI.tool] = true,
  }
  for i = 1, count do
    local row = cur + dir * i
    if row < 1 or row > count then
      break
    end
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
    if labels[line] then
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      return
    end
  end
end

---@private Show the chat keymap registry in a small float window.
function View:_show_keymap_help()
  local lines = {
    "maxa chat keymaps (input area: <C-g>; chat window normal mode: g?)",
    "------------------",
    "  folds:  zM fold all reasoning  zR unfold all  zo/zc cursor fold",
    "  folds:  ]] / [[ jump message headers, then zo/zc on ### Reasoning",
  }
  for _, km in ipairs(M.KEYMAPS) do
    lines[#lines + 1] = ("  %-5s %-8s %s"):format(km.buf, km.keys, km.desc)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = 64
  -- zindex above the snacks chat float (default 50) so the help panel is not
  -- hidden behind the chat window.
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = #lines + 2,
    row = 2,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " maxa chat ",
    zindex = 60,
  })
  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, nowait = true, desc = "maxa: close keymap help" })
  vim.keymap.set("n", "<Esc>", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, nowait = true, desc = "maxa: close keymap help" })
end

---@private Interactively pick a provider (mock/echo + config providers)
--- (chat-ui-actions). Falls back to direct set_provider when no UI is present.
function View:_pick_provider()
  local candidates = { "mock", "echo" }
  -- Real providers come from the effective LazyVim opts config
  -- (lua/maxa/init.lua defaults + user opts, merged by maxa.setup).
  local eff = config.effective
  if eff and eff.provider and eff.provider.definitions then
    for id in pairs(eff.provider.definitions) do
      candidates[#candidates + 1] = id
    end
  end
  vim.ui.select(candidates, {
    prompt = "maxa provider",
    format_item = function(x)
      return tostring(x)
    end,
  }, function(choice)
    if choice then
      self:set_provider(choice)
    end
  end)
end

---@private Interactively set the display model label (chat-ui-actions).
function View:_pick_model()
  vim.ui.input({ prompt = "maxa model: ", default = self.model }, function(input)
    if input and input ~= "" then
      self:set_model(input)
    end
  end)
end

--- Submit a user input through the orchestrator loop (submit → stream → terminal).
--- UI-independent: usable headlessly for deterministic smoke tests.
---@param text string user input
---@param opts? table { async?, provider_params? } forwarded to orchestrator:submit
---@return table result see orchestrator:submit
function View:submit(text, opts)
  opts = opts or {}
  if self.status == "closed" then
    return {
      rejected = true,
      error = schema.new_error(schema.ERROR.INVALID_ARGUMENT, "chat view is closed; cannot submit", nil, true),
    }
  end
  -- Append the visible user turn to the message model before streaming.
  self.items[#self.items + 1] = { role = "user", text = text or "" }
  -- Structural change: a new user turn entered the conversation model.
  self._render_revision = self._render_revision + 1

  local async = not not opts.async
  self._async = async
  local provider_params = vim.tbl_deep_extend("force", {}, self.provider_params, opts.provider_params or {})

  local res = self.orch:submit(text, {
    async = async,
    intent = "manual",
    provider_params = provider_params,
  })
  if res and res.rejected then
    -- Rejected (e.g. duplicate submit while the session is busy): undo the
    -- user turn appended optimistically before submission, so no phantom user
    -- message without a response remains in the conversation model.
    local last = self.items[#self.items]
    if last and last.role == "user" then
      table.remove(self.items)
    end
    -- Surface rejection (e.g. duplicate submit) and drop a no-op render.
    self.errors[#self.errors + 1] = res.error
    self:_render()
  end
  if res and not res.rejected then
    -- W6: an accepted submit starts a fresh chain — the orchestrator resets its
    -- soft-stop marker, so the view mirrors the cleared flag (the old request's
    -- drain boundary is consumed; a new soft stop must be requested anew).
    self.soft_stop = false
  end
  if res and (res.terminal_state or res.async) then
    -- The streaming callbacks / terminal event will reconcile status + render.
    self:_render()
  end
  return res
end

--- Cancel the in-flight provider stream (soft-stop → terminal CANCELLED, once).
---@return boolean cancelled true when this call performed the cancel
function View:stop()
  -- Gate on the orchestrator busy state (the authority for whether a stream is
  -- in flight); the view rendering status lags the first deferred chunk.
  if not self.orch:is_busy() then
    return false
  end
  local cur = self.orch._current
  if not cur or not cur.handle then
    return false
  end
  -- Cancel the in-flight provider handle directly. The phase-0 baseline
  -- orchestrator:stop() passes the handle as the cancel callback, tripping the
  -- protocol handle.cancel arity (it treats the arg as an on_cancelled callback)
  -- and then errors. Calling handle.cancel with the correct (no-arg) arity is a
  -- consumer-side workaround that stays within this module.
  local ok, won = pcall(cur.handle.cancel)
  if ok and won then
    return true
  end
  -- Cancel was already performed by another caller (or already terminal); safe no-op.
  return false
end

--- Soft-stop after the current response/tool batch (W6; `:MaxaSoftStop`,
--- `<C-s>`/`gs` keymaps). Delegates to orchestrator:soft_stop: accepted only
--- while the session is busy, a repeat request toggles it off, and the
--- provider/tools are NEVER cancelled — the current work drains to its natural
--- terminal, results are persisted, and the next automatic continuation is
--- suppressed (decision-table soft_stop slot -> wait + AgentLoop parked).
--- Updates the view soft-stop flag and status projection; UI-independent
--- (headless-testable, no window pair or user interaction required).
---@return table result orchestrator soft_stop result
function View:soft_stop()
  local res = self.orch:soft_stop()
  if res then
    if res.accepted then
      self.soft_stop = true
    elseif res.toggled_off then
      self.soft_stop = false
    elseif res.error then
      -- Typed rejection (closed session / not busy): surface as an error note.
      self.errors[#self.errors + 1] = res.error
    end
  end
  self:_render()
  return res
end

--- Arm the one-shot context-limit stop (`:MaxaContextStop`). Delegates to
--- orchestrator:context_stop_arm: parses absolute (70/"70%") or relative (+N)
--- targets against the current usage ratio; usage unavailable fails closed.
--- When the limit is reached while busy, a one-shot soft stop is requested
--- (status projection shows "status: soft-stop requested"); while idle the next
--- automatic submit is blocked. UI-independent (headless-testable).
---@param target string|number "70" | "70%" | "+10" | 70
---@return boolean ok
---@return nil|table err typed error when arm failed
function View:context_stop(target)
  local ok, err = self.orch:context_stop_arm(target)
  if not ok then
    self.errors[#self.errors + 1] = err
    self:_render()
    return false, err
  end
  local ratio = self.orch._context_stop and self.orch._context_stop.target_ratio
  vim.notify(
    string.format("Context limit stop armed at %d%% (of provider context window).", math.floor((ratio or 0) * 100)),
    vim.log.levels.INFO
  )
  self:_render()
  return true, nil
end
--- Clear the rendered messages (keeps session + provider + model).
---@return self
function View:clear()
  self.items = {}
  self.errors = {}
  self.usage = nil
  if self.status ~= "closed" and self.status ~= "busy" then
    self.status = "idle"
  end
  -- Structural change: the whole conversation model was dropped.
  self._render_revision = self._render_revision + 1
  self:_render()
  return self
end

--- Close the Chat window pair + destroy the underlying session. Idempotent.
---@return boolean changed
function View:close()
  local changed = false
  if self.status ~= "closed" then
    changed = self.orch:close() or changed
  end
  -- W8: the session View entity follows the destroyed session to `closed`
  -- (record-only transition; idempotent, works from attached/hidden/detached).
  if self._session_view then
    self.orch.session:close_view(self._session_view, "view close")
  end
  -- Mark the view closed directly. The baseline orchestrator/session `close()` never
  -- emits `chat.closed` (the event name exists in the events bus but has no emitter),
  -- so relying on that subscription leaves `status` stale and lets a closed view
  -- reopen over a destroyed session. Setting it here (host/nvim-only change) keeps
  -- `:MaxaClose` behaving as documented: view closed + session destroyed.
  if self.status ~= "closed" then
    self.status = "closed"
    self._async = false
  end
  -- Tear down subscriptions to avoid rendering into a dead buffer.
  for _, off in ipairs(self._subs) do
    pcall(off)
  end
  self._subs = {}
  -- Destroy the snacks layout (wipes the scratch buffers) if still present;
  -- `layout:close()` is guarded against double-close and clears its own refs.
  if self._layout then
    pcall(function()
      self._layout:close()
    end)
  end
  self:_reset_ui_refs()
  -- W8: a closed view leaves the live-view registry (no exit-teardown target).
  for i, v in ipairs(M._views) do
    if v == self then
      table.remove(M._views, i)
      break
    end
  end
  return changed
end

--- Switch the provider. Local mock/echo first (protocol registry, unchanged
--- phase-0 behavior); any other name resolves through the effective LazyVim opts
--- config (W10.2): `config.resolve_provider(config.effective, name)` -> bind the
--- protocol adapter -> build the real adapter params from the record
--- (model/base_url/api_key_env/connect_timeout_ms/timeout_ms/proxy_env, live.lua
--- st_params shape; anthropic additionally needs caller-supplied url/headers) ->
--- hand them to the orchestrator via `use_provider_record(record, { params = ... })`,
--- which keeps the offline mock fallback when no api key is available.
---@param name string provider name (mock|echo or a config provider id)
---@return boolean ok
function View:set_provider(name)
  local ok_pc, provider = pcall(protocol.get, name)
  if ok_pc and type(provider) == "table" then
    self.provider = provider
    self.provider_name = name
    self.orch:use_provider(provider)
    self.usage = nil
    self._render_revision = self._render_revision + 1 -- header change
    self:_render()
    return true
  end

  -- Real provider path (W10.2): resolve through the effective LazyVim opts config
  -- (defaults in lua/maxa/init.lua, user overrides in lua/plugins/maxa.lua opts).
  local record, rerr = config.resolve_provider(config.effective, name)
  if not record then
    self.errors[#self.errors + 1] = {
      message = ("unknown provider %q: %s"):format(tostring(name), tostring(rerr and rerr.message or "resolve failed")),
    }
    self:_render()
    return false
  end
  -- Ensure the protocol adapter module is loaded (adapters self-register on
  -- require under their protocol name; resolve_provider only binds what is
  -- already registered). The registry, not the module return value, is the
  -- adapter source: adapter modules may return a wrapper table (openai_chat
  -- returns `M` with `M.adapter`), so get_adapter is authoritative.
  if not record.adapter then
    pcall(require, "maxa.runtime.protocol.adapters." .. record.protocol)
    local adapter = protocol.get_adapter(record.protocol)
    if adapter then
      record:bind(adapter)
    end
  end
  if not record.adapter then
    self.errors[#self.errors + 1] = {
      message = ("no adapter for provider %q (protocol %s)"):format(tostring(name), tostring(record.protocol)),
    }
    self:_render()
    return false
  end

  -- Build the real adapter setup params from the record (live.lua st_params
  -- shape: flattened timeouts/proxy_env; anthropic stream() requires url/headers).
  local params = {
    model = record.model,
    stream = true,
    base_url = record.base_url,
    api_key_env = record.api_key_env,
    connect_timeout_ms = record.request and record.request.connect_timeout_ms,
    timeout_ms = record.request and record.request.timeout_ms,
    proxy_env = record.request and record.request.proxy_env,
  }
  if record.protocol == "anthropic_messages" then
    params.url = record.base_url:gsub("/+$", "") .. "/v1/messages"
    params.headers = {
      ["content-type"] = "application/json",
      ["x-api-key"] = os.getenv(record.api_key_env or ""),
    }
  end

  -- Mount: orchestrator binds the real adapter when the key is available,
  -- otherwise falls back to the local mock (offline dev keeps the UI usable);
  -- the record model label is applied either way.
  self.orch:use_provider_record(record, { params = params })
  self.provider_name = name
  self.model = record.model or self.model
  self.provider = self.orch.provider
  self.usage = nil
  self._render_revision = self._render_revision + 1 -- header change
  self:_render()
  return true
end

--- Set the display model label (passthrough to the provider stream params).
---@param model string model label
---@return boolean ok
function View:set_model(model)
  if type(model) ~= "string" or model == "" then
    return false
  end
  self.model = model
  self.orch.model = model
  self.usage = nil
  self._render_revision = self._render_revision + 1 -- header change
  self:_render()
  return true
end

---@return table snapshot { provider=string, model=string, status=string,
---                          items=table, usage=table|nil, busy=boolean }
function View:snapshot()
  return {
    provider = self.provider_name,
    model = self.model,
    status = self.status,
    items = vim.deepcopy(self.items or {}),
    usage = self.usage,
    busy = self.orch:is_busy(),
  }
end

---@return table orchestrator snapshot (delegated for headless assertions).
function View:orch_snapshot()
  return self.orch:snapshot()
end

--------------------------------------------------------------------------
-- Rendering (chat-ui-render: incremental append + decorations; the full
-- line set stays the single snapshot source of truth for re-render
-- equivalence)
--------------------------------------------------------------------------

---@private Build the complete target render: lines + decoration markers +
--- streaming-cursor anchor. `_render` applies this with a minimal diff
--- (render.apply) and `_build_lines` exposes the pure snapshot (tests /
--- headless assertions), so full re-render and incremental rendering always
--- converge to the same visible content.
---@return table { lines=string[], markers=table[] { line=int, kind=string },
---                 cursor_line=int|nil }
function View:_build()
  local out = { lines = {}, markers = {}, cursor_line = nil }
  local lines = out.lines
  local last_item = self.items[#self.items]

  -- Top header + full-width separator (render_headers semantics: header
  -- highlight + separator extmark).
  lines[#lines + 1] = M.UI.header_fmt:format(self.provider_name, self.model, self.orch.session.id)
  out.markers[#out.markers + 1] = { line = #lines, kind = "header" }
  lines[#lines + 1] = M.UI.divider
  out.markers[#out.markers + 1] = { line = #lines, kind = "separator" }

  for _, item in ipairs(self.items) do
    local role_label = M.UI[item.role] or item.role
    -- Message structure: role header (User/Assistant/System/Tool) with
    -- double blank line spacing between messages.
    lines[#lines + 1] = ""
    lines[#lines + 1] = ""
    lines[#lines + 1] = role_label
    out.markers[#out.markers + 1] = { line = #lines, kind = "header" }
    if item.role == "assistant" then
      -- W8 reasoning part: always rendered as a typed collapsible block
      -- (`### Reasoning` header + body + `### Response`; chat-ui-folds). The
      -- body is a real level-1 fold; `show_reasoning` only controls the default
      -- foldlevel (false => folded, true => expanded) and the fold foldtext
      -- shows the `[reasoning N chars]` summary.
      local reasoning = item.reasoning or ""
      if reasoning ~= "" then
        lines[#lines + 1] = M.UI.reasoning_header
        out.markers[#out.markers + 1] = {
          line = #lines,
          kind = "reasoning",
          id = ("reasoning:%d"):format(#self.items),
          summary = M.UI.reasoning_summary_fmt:format(#reasoning),
        }
        for part in reasoning:gmatch("([^\n]*)\n?") do
          if part ~= "" or part:find("\n") then
            lines[#lines + 1] = part
          end
        end
        lines[#lines + 1] = M.UI.response_header
      end
      -- W8 tool_call parts: icon + name status line (never executed here);
      -- chat-ui-folds adds per-status icons/colors with a stable id.
      for _, tc in ipairs(item.tool_calls or {}) do
        local icon = M.tool_icon(tc.status)
        lines[#lines + 1] = M.UI.tool_call_fmt:format(icon, tc.name or "?")
        out.markers[#out.markers + 1] = {
          line = #lines,
          kind = "tool",
          status = tc.status or "started",
          id = ("tool:%s"):format(tc.call_id or "?"),
        }
      end
    end
    if item.text and item.text ~= "" then
      for part in tostring(item.text):gmatch("([^\n]*)\n?") do
        if part ~= "" or part:find("\n") then
          lines[#lines + 1] = part
        end
      end
    end
    -- Streaming-cursor anchor: the last content line of the in-flight
    -- assistant turn (only while busy; the footer lines come after it).
    if self.status == "busy" and item == last_item then
      out.cursor_line = #lines
    end
  end

  -- Informational errors (rejections / stuck diagnostics are surfaced inline).
  for _, err in ipairs(self.errors) do
    if err and err.message then
      lines[#lines + 1] = ""
      lines[#lines + 1] = ("[error %s] %s"):format(err.code or "?", err.message)
    end
  end

  -- Status footer.
  lines[#lines + 1] = ""
  lines[#lines + 1] = self:_status_line()
  return out
end

---@private Full line snapshot of the target render (kept for headless
--- assertions: tests/w8, tests/w10 and re-render equivalence checks).
function View:_build_lines()
  return self:_build().lines
end

---@private
function View:_status_line()
  if self.status == "closed" then
    return M.UI.closed
  end
  if self.status == "busy" then
    -- W6: while a soft stop is requested the busy projection switches to the
    -- drain label ("status: soft-stop requested"); the provider/tools are
    -- still running until the drain boundary clears the flag.
    if self.soft_stop then
      return M.UI.status_soft_stop
    end
    return M.UI.status_busy
  end
  if self.status == "completed" then
    -- W8/W10 normalized usage status line: input/output/total + cached/reasoning
    -- tokens when the provider reported them (unknown stays absent).
    local usage = self.usage
    local bits = {}
    if usage then
      if usage.input_tokens ~= nil then
        bits[#bits + 1] = ("in=%d"):format(usage.input_tokens)
      end
      if usage.output_tokens ~= nil then
        bits[#bits + 1] = ("out=%d"):format(usage.output_tokens)
      end
      if usage.total_tokens ~= nil then
        bits[#bits + 1] = ("total=%d"):format(usage.total_tokens)
      end
      if usage.cached_input_tokens ~= nil then
        bits[#bits + 1] = ("cached=%d"):format(usage.cached_input_tokens)
      end
      if usage.reasoning_tokens ~= nil then
        bits[#bits + 1] = ("reason=%d"):format(usage.reasoning_tokens)
      end
    end
    if #bits > 0 then
      return M.UI.status_completed .. " (" .. table.concat(bits, " ") .. ")"
    end
    return M.UI.status_completed
  end
  if self.status == "failed" then
    return M.UI.status_failed
  end
  if self.status == "cancelled" then
    return M.UI.status_cancelled
  end
  return M.UI.status_idle
end

--- Read-only status projection for external consumers (chat-ui-status):
--- global statusline components consume the view spine without touching Chat
--- rendering. `text` is the projected status line; busy states carry a
--- spinner frame.
---@return table { status=string, usage=table|nil, text=string }
function View:projection()
  local text = self:_status_line()
  if self.status == "busy" then
    text = ("%s %s"):format(status.spinner_frame(), text)
  end
  return { status = self.status, usage = self.usage, text = text }
end

---@private Render the chat buffer incrementally. Computes the full target
--- line set from the message model (snapshot-equivalent) and applies it with a
--- minimal diff (`render.apply`): streaming deltas append in place via
--- `nvim_buf_set_text`, structural/state changes replace only the diverging
--- range. Then re-applies decorations, follow-to-bottom and the streaming
--- cursor virtual text (which is never persisted into buffer content).
function View:_render()
  if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
    return
  end
  local built = self:_build()
  -- chat-ui-input: the diff is bounded to the rendered region (_render_end);
  -- the integrated input area (header + user input) at the buffer tail is
  -- preserved verbatim. After success, the rendered region grows/shrinks to
  -- the new target size.
  local ok, mode = pcall(render.apply, self._buf, built.lines, self._render_stats, self._render_end)
  if not ok then
    -- Rendering is best-effort; record rather than crash the stream.
    self.errors[#self.errors + 1] = { message = ("render error: %s"):format(tostring(mode)) }
    return
  end
  self._render_end = #built.lines
  if mode ~= "noop" then
    render.apply_extmarks(self._buf, built.lines, built.markers)
    -- chat-ui-folds: keep foldtext summaries in sync with the rendered lines
    -- (the reasoning fold summary shows the body char count) and apply the
    -- default foldlevel from show_reasoning (folded <=> not show_reasoning).
    render.clear_fold_summaries(self._buf)
    for _, m in ipairs(built.markers) do
      if m.kind == "reasoning" and m.summary then
        render.set_fold_summary(self._buf, m.line, m.summary)
      end
    end
    render.set_foldlevel(self._chat_win, not self.show_reasoning)
    self:_follow_bottom()
  end
  -- Streaming cursor placeholder: virtual text on the last content line of the
  -- in-flight turn; cleared whenever the view is not streaming.
  render.clear_cursor(self._buf)
  if built.cursor_line then
    local row = built.cursor_line - 1
    local line_text = vim.api.nvim_buf_get_lines(self._buf, row, row + 1, false)[1] or ""
    vim.api.nvim_buf_set_extmark(self._buf, render.CURSOR_NS, row, #line_text, {
      virt_text = { { M.UI.cursor_marker, render.HL.cursor } },
      virt_text_pos = "eol",
    })
  end
end

---@private Bind a chat buffer to the modern renderer: markdown treesitter
--- highlighting (`vim.treesitter.get_parser(bufnr, "markdown")` semantics),
--- decoration namespaces and the follow autocmd. Idempotent per buffer.
---@param buf integer chat buffer
---@param win integer chat window
function View:_bind_render_buffer(buf, win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if self._bound_buf == buf then
    return
  end
  self._bound_buf = buf
  render.setup_highlights()
  -- Markdown treesitter highlighting (chat-ui-render plan 3.1): code blocks,
  -- headings and lists are highlighted by the markdown parser.
  self._ts_attached = pcall(vim.treesitter.start, buf, "markdown")
  -- chat-ui-folds: expr-fold binding for `### Reasoning` collapsible blocks;
  -- foldtext summaries are refreshed on every render.
  render.fold_bind(buf, win, { folded = not self.show_reasoning })
  self._render_stats = { appends = 0, rewrites = 0, noops = 0 }
  -- W8 view-delete: a deleted chat buffer (e.g. `:bdelete`) detaches the view
  -- and preserves the session/request; render callbacks become inert through
  -- the invalid-buffer guard in _render.
  local buf_group = vim.api.nvim_create_augroup("maxa_chat_buf_delete", { clear = false })
  vim.api.nvim_create_autocmd("BufDelete", {
    buffer = buf,
    group = buf_group,
    desc = "maxa: buffer deleted -> view detached (session survives)",
    callback = function()
      self:detach("buffer deleted")
    end,
  })
  -- Follow semantics: manual scroll-up pauses following; reaching the bottom
  -- resumes it (ui/init.lua follow() semantics).
  local group = vim.api.nvim_create_augroup("maxa_chat_follow", { clear = false })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = buf,
    group = group,
    desc = "maxa: chat follow pauses on manual scroll up",
    callback = function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local w = vim.fn.bufwinid(buf)
      if w <= 0 then
        return
      end
      local row = vim.api.nvim_win_get_cursor(w)[1]
      self._follow = row >= vim.api.nvim_buf_line_count(buf)
    end,
  })
end

---@private Scroll the chat window to the bottom when following is enabled.
function View:_follow_bottom()
  if not self._follow then
    return
  end
  local win = self._chat_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(self._buf), 0 })
end

--- Enable/disable automatic follow-to-bottom. When disabled (e.g. the user
--- scrolled up manually), content growth does not move the cursor; re-enabling
--- jumps back to the bottom.
---@param enabled boolean
---@return self
function View:set_follow(enabled)
  self._follow = not not enabled
  if self._follow then
    self:_follow_bottom()
  end
  return self
end

--- Best-effort per-view teardown for nvim exit (W8): the orchestrator is shut
--- down quietly (owned handles cancelled, timers stopped, session closed),
--- subscriptions are removed and UI refs dropped. No rendering, no new events;
--- safe for a view whose buffer is already gone. Idempotent.
---@return table report orchestrator shutdown report
function View:shutdown()
  local report = { closed = self:_is_closed_view() }
  if not self:_is_closed_view() then
    report = self.orch:shutdown()
    self.status = "closed"
    self._async = false
  end
  for _, off in ipairs(self._subs) do
    pcall(off)
  end
  self._subs = {}
  self:_reset_ui_refs()
  for i, v in ipairs(M._views) do
    if v == self then
      table.remove(M._views, i)
      break
    end
  end
  return report
end

---------------------------------------------------------------------------
-- Module-level operations / commands
---------------------------------------------------------------------------

--- Open the default Chat view (used by `:MaxaChat`).
---@return table view
function M.open()
  local v = M._get_default()
  v:open()
  return v
end

--- Stop the default view's in-flight stream.
---@return boolean cancelled
function M.stop()
  local v = M._default
  if not v then
    return false
  end
  return v:stop()
end

--- Soft-stop the default view (drain then suppress continuation).
---@return table|nil orchestrator soft_stop result (nil when no view exists)
function M.soft_stop()
  local v = M._default
  if not v then
    return nil
  end
  return v:soft_stop()
end

--- Module-level context-limit stop control (`:MaxaContextStop`).
--- Args: <percent|+N|off> — "70" / "70%" absolute, "+10" relative, "off" disarms.
---@param args string|nil command arguments (may be "")
---@return boolean ok
function M.context_stop(args)
  local v = M._default
  if not v then
    vim.notify("MaxaContextStop: no Chat view is open (:MaxaChat first)", vim.log.levels.WARN)
    return false
  end
  args = args or ""
  if args == "" then
    vim.notify('usage: :MaxaContextStop <percent|+N|off>  (e.g. 70, "70%", +10)', vim.log.levels.INFO)
    return false
  end
  if args == "off" or args == "disarm" then
    v.orch:context_stop_disarm()
    vim.notify("Context limit stop disarmed.", vim.log.levels.INFO)
    v:_render()
    return true
  end
  return v:context_stop(args)
end

--- Close the default view.
---@return boolean changed
function M.close()
  local v = M._default
  if not v then
    return false
  end
  return v:close()
end

--- Best-effort runtime teardown for nvim exit (W8; `VimLeavePre` hook). Every
--- live view's orchestrator is shut down quietly (owned provider/tool handles
--- cancelled, timers stopped, session closed); failures are collected into the
--- returned report and never create new work. Idempotent. Headless-testable:
--- calling this directly simulates the exit hook without leaving nvim.
---@return table report { views=integer, failures=table[] }
function M.shutdown()
  local report = { views = 0, failures = {} }
  -- Snapshot the registry: shutdown may unregister views while iterating.
  local views = {}
  for _, v in ipairs(M._views) do
    views[#views + 1] = v
  end
  for _, v in ipairs(views) do
    local ok, err = pcall(v.shutdown, v)
    if not ok then
      report.failures[#report.failures + 1] = { what = "view", error = tostring(err) }
    end
    report.views = report.views + 1
  end
  return report
end

---@private Demo stream chunks: a long reasoning block + one tool call + usage,
--- so the reasoning fold and tool status icons are directly visible offline.
---@return table[] normalize chunk records
function M._demo_chunks()
  local n = require("maxa.runtime.protocol.normalize")
  local reasoning = {}
  for i = 1, 40 do
    reasoning[i] = ("thinking step %d about the request. "):format(i)
  end
  return {
    n.reasoning_delta(table.concat(reasoning)),
    n.message_delta("I inspected "),
    n.tool_call_started("call_demo_1", "read_file"),
    n.tool_args_delta("call_demo_1", '{"path": "demo.txt"}'),
    n.tool_call_completed("call_demo_1", '{"content": "demo file"}'),
    n.message_delta("the demo file and summarized it."),
    n.usage_updated(n.normalize_usage({ input_tokens = 120, output_tokens = 40, total_tokens = 160 })),
    n.usage_updated(
      n.normalize_usage({ input_tokens = 120, output_tokens = 40, total_tokens = 160 }, { final = true })
    ),
  }
end

--- Open a demo session: mock stream with reasoning + tool call + usage, so the
--- reasoning fold and tool status icons are directly visible (offline, no key).
---@return table view
function M.open_demo()
  local v = M._get_default()
  v.provider_params = { chunks = M._demo_chunks(), delay = 20 }
  v:open()
  v:submit("demonstrate reasoning and tools", { async = true })
  return v
end

---@private Idempotent user-command registration.
function M.setup()
  -- Idempotence via a module flag, NOT command existence: lazy.nvim registers
  -- placeholder commands for the plugin `cmd` list, so exists(":MaxaChat") is 2
  -- before the real registration ever runs and would wrongly skip it.
  if M._setup_done then
    return
  end
  M._setup_done = true
  vim.api.nvim_create_user_command("MaxaChat", function()
    M.open()
  end, { desc = "maxa: open/focus the minimal Chat view", nargs = 0 })
  vim.api.nvim_create_user_command("MaxaStop", function()
    M.stop()
  end, { desc = "maxa: hard-cancel the in-flight provider stream/tool batch (terminal cancelled)", nargs = 0 })
  vim.api.nvim_create_user_command("MaxaSoftStop", function()
    M.soft_stop()
  end, {
    desc = "maxa: drain the current response/tool batch, then suppress automatic continuation (never cancels)",
    nargs = 0,
  })
  vim.api.nvim_create_user_command("MaxaContextStop", function(a)
    M.context_stop(a.args)
  end, {
    desc = 'maxa: arm one-shot context-limit stop (<percent|+N|off>; e.g. 70, "70%", +10)',
    nargs = "*",
  })
  vim.api.nvim_create_user_command("MaxaClose", function()
    M.close()
  end, { desc = "maxa: close the Chat view and destroy the session", nargs = 0 })
  vim.api.nvim_create_user_command("MaxaClear", function()
    local v = M._default
    if v then
      v:clear()
    end
  end, { desc = "maxa: clear the rendered messages", nargs = 0 })
  vim.api.nvim_create_user_command("MaxaProvider", function(a)
    local v = M._get_default()
    if a.args ~= "" then
      v:set_provider(a.args)
    else
      v:_pick_provider()
    end
  end, {
    desc = "maxa: switch provider (no arg: interactive picker)",
    nargs = "*",
  })
  vim.api.nvim_create_user_command("MaxaModel", function(a)
    local v = M._get_default()
    if a.args ~= "" then
      v:set_model(a.args)
    else
      v:_pick_model()
    end
  end, { desc = "maxa: set display model label (no arg: interactive input)", nargs = "*" })
  vim.api.nvim_create_user_command("MaxaDemo", function()
    M.open_demo()
  end, { desc = "maxa: demo session (mock reasoning + tool call stream)", nargs = 0 })
end

-- Register commands on load so `:MaxaChat` exists whenever this module is required.
M.setup()

return M
