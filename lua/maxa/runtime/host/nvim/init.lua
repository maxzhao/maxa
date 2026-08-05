-- filepath: lua/maxa/runtime/host/nvim/init.lua
--- maxa runtime host for Neovim: minimal Chat view (phase 0).
---
--- Scope (see .supermax/drafts/phase0-development-plan.md §5.7): this module
--- provides the minimal runnable Chat surface on top of the phase-0
--- `session` + `orchestrator` + `protocol` + `events` modules. It supports:
---
---   `:MaxaChat`   open (or focus) the Chat window pair
---   :MaxaStop     cancel the in-flight provider stream (soft-stop, terminal once)
---   :MaxaClose    close the Chat window pair + destroy the session
---   :MaxaProvider switch provider (default "mock"): mock | echo
---   :MaxaModel    switch display model label (default "mock-model")
---   :MaxaClear    clear the rendered messages (keeps session + current provider/model)
---
--- It is a pure *consumer* of the shared phase-0 contracts (§4 of the plan). It
--- does NOT reimplement the state machine (session/orchestrator own that) and it
--- never loads `codecompanion.*` / `mcphub.*` / `lua/util/hooks/*`. Provider/model
--- switching only re-arms the orchestrator's provider; real four-protocol adapters
--- belong to phase 1.
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
---     `_input_buf`) and their keymaps.
---   * Rendering is a full deterministic rewrite of the chat buffer from an
---     internal `items` message model (role + text) on every change. The chat
---     buffer is modifiable-off and owned solely by this module, so full rewrites
---     are safe. The input buffer is a separate scratch buffer.
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

-- LazyVim ecosystem dependency for the floating window pair (see R-01 in the
-- phase-0 plan §10). `snacks` is an allowed environment dependency (not in the
-- guard's forbidden list: only codecompanion.* / mcphub.* / util.hooks.* are).
local snacks = require("snacks")

local M = {}

M.name = "host.nvim"

-- Defaults (mock/echo providers; real adapters bind through config in W9).
M.DEFAULT_PROVIDER = protocol.providers.mock or "mock"
M.DEFAULT_MODEL = "mock-model"
-- ui.show_reasoning: false => reasoning renders as a collapsed summary line.
M.DEFAULT_SHOW_REASONING = false

--- Override the view defaults from the maxa config.
--- Called by `require("maxa").setup`; keeps host free of a maxa/init circular require.
---@param opts? table { provider?: string, model?: string, show_reasoning?: boolean }
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
  return M
end

--- UI text labels.
M.UI = {
  header_fmt = "[maxa] provider=%s model=%s session=%s",
  divider = string.rep("─", 48),
  user = "User",
  assistant = "Assistant",
  system = "System",
  tool = "Tool",
  -- W8 parts rendering labels.
  reasoning_open = "[reasoning]",
  reasoning_summary_fmt = "[reasoning %d chars]",
  tool_call_fmt = "[tool %s] (%s)",
  status_idle = "status: idle",
  status_busy = "status: busy (streaming…)",
  status_completed = "status: completed",
  status_failed = "status: failed",
  status_cancelled = "status: cancelled",
  closed = "session closed",
}

---------------------------------------------------------------------------
-- View instance
---------------------------------------------------------------------------
local View = {}
View.__index = View

--- Create a Chat view. UI is lazy: the window pair is only created by `open()`.
---@param opts? table {
---   provider?:    string provider name (default "mock"),
---   model?:       string model label (default "mock-model"),
---   events?:      table event bus (default: global events module),
---   auto_open?:   boolean open the window pair immediately (default false),
---   provider_params?: table forwarded to provider.stream on each submit,
--- }
---@return table view
function M.new(opts)
  opts = opts or {}
  local bus = opts.events or events
  local provider_name = opts.provider or M.DEFAULT_PROVIDER
  local provider = protocol.get(provider_name)

  -- The orchestrator owns the stream loop and asserts that a provider is attached
  -- before the first submit, so attach the initial provider before returning.
  local orch = orchestrator.new({
    model = opts.model or M.DEFAULT_MODEL,
    events = bus,
  })
  orch:use_provider(provider)

  local self = setmetatable({
    orch = orch,
    provider = provider,
    provider_name = provider_name,
    model = opts.model or M.DEFAULT_MODEL,
    events = bus,
    provider_params = opts.provider_params or {},
    items = {}, -- ordered message model { role=string, text=string,
    --             reasoning=string, tool_calls=table[] }
    status = "idle", -- idle | busy | completed | failed | cancelled | closed
    usage = nil, -- latest/final normalized usage (W8: schema.usage snapshot)
    show_reasoning = (opts.show_reasoning == nil) and M.DEFAULT_SHOW_REASONING or not not opts.show_reasoning,
    errors = {}, -- non-terminal informational errors surfaced to the user
    -- UI buffers/windows (nil until open()).
    _opened = false,
    _buf = nil,
    _input_buf = nil,
    _chat_win = nil,
    _input_win = nil,
    -- snacks layout + win objects (see open() / _reset_ui_refs()).
    _layout = nil,
    _chat_obj = nil,
    _input_obj = nil,
    -- subscriptions, torn down on close().
    _subs = {},
    -- how the most recent submit is driven (async used by UI; sync for headless).
    _async = false,
  }, View)

  self:_subscribe()
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
  -- Terminal success.
  sub(self.events.events.response_completed or "response.completed", function(payload)
    self.status = "completed"
    if payload and payload.usage then
      self.usage = payload.usage
    end
    self._async = false
    self:_render()
  end)
  -- Terminal failure (provider/protocol/timeout).
  sub(self.events.events.response_failed or "response.failed", function(payload)
    self.status = "failed"
    self.errors[#self.errors + 1] = (payload and payload.error) or { message = "unknown failure" }
    self._async = false
    self:_render()
  end)
  -- Terminal cancel (via :MaxaStop / provider auto-cancel).
  sub(self.events.events.response_cancelled or "response.cancelled", function(payload)
    self.status = "cancelled"
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

  -- chat buffer: modifiable-off scrollback, owned solely by this view.
  local chat_obj = snacks.win({
    show = false,
    position = "float",
    enter = false,
    bo = { modifiable = false, buftype = "nofile", swapfile = false },
  })
  -- input buffer: modifiable prompt; `<CR>` submits (buffer-local keymaps).
  local input_obj = snacks.win({
    show = false,
    position = "float",
    enter = false,
    bo = { buftype = "nofile", swapfile = false, modifiable = true },
  })

  -- Arrange the two windows as a vertical floating layout (input fixed to 3 rows).
  local layout = snacks.layout.new({
    show = false,
    wins = { chat = chat_obj, input = input_obj },
    layout = {
      position = "float",
      box = "vertical",
      width = 0.7,
      height = 0.8,
      { win = "chat", border = "rounded" },
      { win = "input", height = 3, border = "rounded" },
    },
    on_close = function()
      -- External close (e.g. `:q` on a float): drop the UI refs but keep the
      -- session alive so the next `:MaxaChat` / `open()` rebuilds the layout.
      self:_reset_ui_refs()
    end,
  })
  layout:show()

  -- Capture the snack-created buffers/windows after showing the layout.
  self._layout = layout
  self._chat_obj = chat_obj
  self._input_obj = input_obj
  self._buf = chat_obj.buf
  self._input_buf = input_obj.buf
  self._chat_win = chat_obj.win
  self._input_win = input_obj.win
  self._opened = true

  self:_add_input_mappings()
  self:_render()
  self:_focus_open_windows()
  vim.cmd("startinsert")
  return true
end

---@private Focus the already-open window pair (idempotent reopen).
function View:_focus_open_windows()
  if self._input_win and vim.api.nvim_win_is_valid(self._input_win) then
    vim.api.nvim_set_current_win(self._input_win)
  end
end

---@private Drop all UI (window pair) references without destroying the session.
--- Used both by `close()` and by the layout's `on_close` (external `:q` close),
--- so an already-destroyed layout never leaves stale buffer/window handles.
function View:_reset_ui_refs()
  self._layout = nil
  self._chat_obj = nil
  self._input_obj = nil
  self._buf = nil
  self._input_buf = nil
  self._chat_win = nil
  self._input_win = nil
  self._opened = false
end

---@private Bind `<CR>` submit mapping (and safe insert-mode Ctrl-C stop) to the input buffer.
function View:_add_input_mappings()
  local buf = self._input_buf
  if not buf then
    return
  end
  vim.keymap.set("i", "<CR>", function()
    self:_submit_from_input()
  end, { buffer = buf, desc = "maxa: submit chat input" })
  vim.keymap.set("i", "<C-c>", function()
    self:stop()
  end, { buffer = buf, desc = "maxa: cancel in-flight stream" })
  -- Buffer-local `<CR>` in normal mode on the input buffer behaves the same.
  vim.keymap.set("n", "<CR>", function()
    self:_submit_from_input()
  end, { buffer = buf, desc = "maxa: submit chat input" })
end

---@private Read the input buffer, clear it, and submit the captured text.
function View:_submit_from_input()
  local buf = self._input_buf
  if not buf or self.status == "closed" then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cleaned = {}
  for i = 1, #lines do
    local line = lines[i]
    if line and line ~= "" then
      cleaned[#cleaned + 1] = line
    end
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {}) -- clear the prompt
  if #cleaned == 0 then
    return
  end
  local text = table.concat(cleaned, "\n")
  -- UI path: play the streams, but keep a small delay so chunks render progressively.
  self:submit(text, { async = true })
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

--- Clear the rendered messages (keeps session + provider + model).
---@return self
function View:clear()
  self.items = {}
  self.errors = {}
  self.usage = nil
  if self.status ~= "closed" and self.status ~= "busy" then
    self.status = "idle"
  end
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
  return changed
end

--- Switch the provider (mock | echo). Re-arms the orchestrator's provider.
---@param name string provider name (see protocol.available()/providers)
---@return boolean ok
function View:set_provider(name)
  local ok_pc, err = pcall(protocol.get, name)
  if not ok_pc or not err then
    self.errors[#self.errors + 1] = { message = ("unknown provider %q"):format(tostring(name)) }
    self:_render()
    return false
  end
  self.provider = err
  self.provider_name = name
  self.orch:use_provider(err)
  self.usage = nil
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

---------------------------------------------------------------------------
-- Rendering (deterministic full rewrite of the chat buffer)
---------------------------------------------------------------------------

---@private Build the full line set for the chat buffer from the message model.
function View:_build_lines()
  local lines = {}
  local header = M.UI.header_fmt:format(self.provider_name, self.model, self.orch.session.id)
  lines[#lines + 1] = header
  lines[#lines + 1] = M.UI.divider
  for _, item in ipairs(self.items) do
    local role_label = M.UI[item.role] or item.role
    lines[#lines + 1] = ""
    lines[#lines + 1] = role_label
    if item.role == "assistant" then
      -- W8 reasoning part: collapsed summary by default (ui.show_reasoning=false);
      -- full content when the user opted in.
      local reasoning = item.reasoning or ""
      if reasoning ~= "" then
        if self.show_reasoning then
          lines[#lines + 1] = M.UI.reasoning_open
          for part in reasoning:gmatch("([^\n]*)\n?") do
            if part ~= "" or part:find("\n") then
              lines[#lines + 1] = part
            end
          end
        else
          lines[#lines + 1] = M.UI.reasoning_summary_fmt:format(#reasoning)
        end
      end
      -- W8 tool_call parts: name + status summary line (never executed here).
      for _, tc in ipairs(item.tool_calls or {}) do
        lines[#lines + 1] = M.UI.tool_call_fmt:format(tc.name or "?", tc.status or "started")
      end
    end
    if item.text and item.text ~= "" then
      for part in tostring(item.text):gmatch("([^\n]*)\n?") do
        if part ~= "" or part:find("\n") then
          lines[#lines + 1] = part
        end
      end
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
  return lines
end

---@private
function View:_status_line()
  if self.status == "closed" then
    return M.UI.closed
  end
  if self.status == "busy" then
    return M.UI.status_busy
  end
  if self.status == "completed" then
    -- W8 normalized usage status line: input/output/total (unknown stays absent).
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

---@private Rewrite the chat buffer lines. Safe because the chat buffer is
--- modifiable-off and exclusively owned by this view.
function View:_render()
  if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
    return
  end
  local lines = self:_build_lines()
  if #lines == 0 then
    lines = { "" }
  end
  local modifiable = vim.bo[self._buf].modifiable
  vim.bo[self._buf].modifiable = true
  local ok, err = pcall(vim.api.nvim_buf_set_lines, self._buf, 0, -1, false, lines)
  vim.bo[self._buf].modifiable = modifiable
  if not ok then
    -- Rendering is best-effort; record rather than crash the stream.
    self.errors[#self.errors + 1] = { message = ("render error: %s"):format(tostring(err)) }
  end
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

--- Close the default view.
---@return boolean changed
function M.close()
  local v = M._default
  if not v then
    return false
  end
  return v:close()
end

---@private Idempotent user-command registration.
function M.setup()
  if vim.fn.exists(":MaxaChat") == 2 then
    return
  end
  vim.api.nvim_create_user_command("MaxaChat", function()
    M.open()
  end, { desc = "maxa: open/focus the minimal Chat view", nargs = 0 })
  vim.api.nvim_create_user_command("MaxaStop", function()
    M.stop()
  end, { desc = "maxa: cancel the in-flight provider stream", nargs = 0 })
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
    local name = a.args ~= "" and a.args or M.DEFAULT_PROVIDER
    local v = M._get_default()
    v:set_provider(name)
  end, { desc = "maxa: switch provider (mock|echo)", nargs = "*" })
  vim.api.nvim_create_user_command("MaxaModel", function(a)
    local v = M._get_default()
    if a.args == "" then
      return
    end
    v:set_model(a.args)
  end, { desc = "maxa: set display model label", nargs = 1 })
end

-- Register commands on load so `:MaxaChat` exists whenever this module is required.
M.setup()

return M
