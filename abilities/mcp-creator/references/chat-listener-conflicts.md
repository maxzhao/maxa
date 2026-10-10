# Maxa AI Chat Listener Conflict Guide

Use this before implementing Native MCP logic that listens to Maxa AI Chat lifecycle, auto-submits, handles tool results, guards multi-turn workflows, or must coexist with auto compact, retry, or subagents.

## Read When

A feature needs any of the following:

- Listen to `MaxaAIChatSubmitted`, `MaxaAIChatDone`, `MaxaAIChatStopped`, `MaxaAIChatClosed`, or `MaxaAIToolsFinished`.
- Insert messages or call `chat:submit({ auto_submit = true })` after an LLM response.
- Patch or consider patching `Chat.done`, `chat.done`, `Chat.submit`, `chat.submit`, `Chat.add_message`, or `chat.tools_done`.
- Coexist with auto compact, network retry, token warning, tool-result auto-submit, or subagent sessions.
- Maintain cross-turn state for start/commit/trunk/guard workflows.

## Principles

### 1. Prefer side-channel event listeners

For observation/checking, use independent `User` autocmds with delayed checks. Do not patch core chat methods just to observe.

```lua
local group = vim.api.nvim_create_augroup("MyServerGuard", { clear = false })

vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "MaxaAIChatDone",
  callback = function(args)
    vim.defer_fn(function()
      vim.schedule(function()
        -- check chat state, then maybe act
      end)
    end, 50)
  end,
})
```

### 2. Patch only when changing core semantics

`Chat.done`, `Chat.submit`, `Chat.add_message`, and `chat.tools_done` are high-conflict. Patch only after defining hook order, restore strategy, and compatibility with existing modules.

### 3. Use independent autocmd groups

Each feature needs its own group, for example:

```lua
vim.api.nvim_create_augroup("MyServerGuard", { clear = false })
```

Do not reuse or clear other modules' groups.

### 4. Delay checks to avoid racing tool lifecycle

After `MaxaAIChatDone`, delay before mutating messages or submitting so done hooks, tool result writes, AbilityHooks, and auto-submit logic finish first.

```lua
vim.defer_fn(function()
  vim.schedule(function()
    if chat.current_request then return end
    -- inspect last message/tool/guard state
  end)
end, 50)
```

### 5. Automatic submit must use `auto_submit=true`

```lua
if not chat.current_request then
  chat:submit({ auto_submit = true })
end
```

This avoids manual-submit confirmation paths and aligns with internal tool/subagent/compact flows. Always verify chat/bufnr validity before submit.

## Existing Mechanisms And Boundaries

### `chat_request_watchdog`

File: `lua/maxa/lifecycle/chat_request_watchdog.lua`.

Owns request progress/empty-message/no-message watchdog and fallback auto-submit repair. It listens to submit/done/stopped/hidden/closed and patches `Chat.add_message`.

Do not add another watchdog for the same stuck/empty/no-progress auto-submit class. New features may listen in parallel with their own group but must not clear this group or duplicate its repair behavior.

### `chat_submitted_event`

File: `lua/maxa/lifecycle/chat_submitted_event.lua`.

Patches global `Chat.submit` to classify manual versus programmatic submissions and fire `ChatSubmitted` AbilityHook events. Automatic continuations must pass `auto_submit=true`. Do not patch global `Chat.submit` again merely to observe submissions.

### `llm_error_recovery`

File: `lua/maxa/session/llm_error_recovery.lua`.

Patches per-chat `chat.done`, `chat.submit`, and `chat.stop`; handles token warnings, `compact_self`, context-length errors, network retry, rate limits, and invalid signatures.

Do not wrap `chat.done` for ordinary recovery. On `MaxaAIChatDone`, delay checks and skip action if `chat.current_request` or retry/recovery state is active.

### Subagent sessions

Subagents run separate chats, often via `chat:submit({ auto_submit = true })`.

Guard/listener state must be isolated per chat, keyed by `chat.id` or `chat.bufnr`, and cleaned on closed/stopped events. Do not assume the current chat is the main Agent.

## Guard / Watchdog Pattern

Use when a Native tool starts a cross-turn workflow and the Agent may forget the next required tool call.

### State

```lua
local guards = {}

local function chat_key(chat)
  return tostring(chat and (chat.id or chat.bufnr) or "unknown")
end

guards[chat_key(chat)] = {
  name = name,
  attempt_id = attempt_id,
  active = true,
  reminder_count = 0,
  max_reminders = 3,
  last_action = "start", -- start | trunk | commit | cancelled
}
```

Prefer one active guard per chat/attempt class; avoid multiple simultaneous reminders.

### Tool-updated state

Do not infer state from UI text. Tool handlers must update guard state explicitly.

```lua
require("maxa.mcphub.native_servers.myserver.guard").start(chat, { name = name, attempt_id = attempt_id })
require("maxa.mcphub.native_servers.myserver.guard").mark_progress(chat, name, attempt_id, "trunk_called")
require("maxa.mcphub.native_servers.myserver.guard").cancel(chat, name, attempt_id, "commit_called")
```

If commit should cancel the guard, cancel after parameter validation and before commit side effects; failed commit should not cause duplicate reminders.

### Done-safe check

```lua
local function on_done(args)
  vim.defer_fn(function()
    vim.schedule(function()
      local chat = chat_from_event(args)
      local guard = chat and guards[chat_key(chat)]
      if not guard or not guard.active then return end
      if chat.current_request then return end

      local last = chat.messages and chat.messages[#chat.messages]
      if last and last.role == "tool" then return end

      -- inject reminder and auto-submit
    end)
  end, 50)
end
```

### Reminder injection

Use a `role = "user"` message with `_meta`; never fake tool results or create unmatched tool_call/tool_result pairs.

```lua
table.insert(chat.messages, {
  role = "user",
  content = table.concat({
    "Workflow guard: current attempt is still in progress.",
    "Continue with the next required tool defined by the loaded Ability.",
  }, "\n"),
  _meta = {
    tag = "my_server_guard",
    name = guard.name,
    attempt_id = guard.attempt_id,
    reminder_count = guard.reminder_count,
  },
})

if not chat.current_request then
  chat:submit({ auto_submit = true })
end
```

Cap repeats:

```lua
guard.reminder_count = guard.reminder_count + 1
if guard.reminder_count > guard.max_reminders then
  guard.active = false
  guards[key] = nil
  return
end
```

Default maximum: 3 reminders unless the feature has stronger evidence.

## Decision Table

| Need | Recommended | Avoid |
| --- | --- | --- |
| Check state after request completion | independent User autocmd + delayed check | patch `chat.done` |
| Fallback after tool result not continued | reuse existing watchdog where possible | duplicate tool-result listener/submitter |
| Insert reminder and continue | `role=user` + `_meta.tag` + `auto_submit=true` | manual submit, fake tool result |
| Native cross-turn state | key by chat and explicit handler state updates | parse UI buffer to infer state |
| Multiple listeners | independent augroup, `clear=false` or clear only self | reuse/clear other groups |

## Validation Checklist

- [ ] No patch to `Chat.done` / `Chat.submit` / `Chat.add_message` unless explicitly required and hook order is documented.
- [ ] Independent autocmd group; no clearing others.
- [ ] State isolated by `chat.id` / `chat.bufnr`.
- [ ] Closed/stopped chats clean state.
- [ ] Auto-submit checks `chat.current_request` and chat/bufnr validity.
- [ ] Last tool result is not preempted.
- [ ] Repeat limit or dedupe key prevents infinite loop.
- [ ] Injected messages include `_meta.tag`.
- [ ] Lua syntax/static tests pass.
- [ ] Minimal simulation tests cover the state machine without real LLM dependency.

## Native Reload Reminder

Files here usually affect `lua/maxa/mcphub/native_servers/**`. After Native MCP changes, run local static validation, then use the Native restart-resume path. Do not treat MCPHub restart as reliable Native reload.
