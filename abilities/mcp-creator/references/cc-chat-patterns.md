# Maxa AI Chat Integration Patterns

Native MCP Server patterns for Maxa AI Chat access, persisted state, hooks, adapter capability, and delayed actions.

## Get Chat Object

From MCP tool request:

```lua
local function handler(req, res)
  local chat = req.caller
    and req.caller.maxa_ai
    and req.caller.maxa_ai.chat

  if not chat then
    return res:error("No active chat session")
  end
end
```

`req.caller` exists only when MaxaAI invokes the MCP tool. Subagent/mock requests may not have it.

From bufnr:

```lua
local chat_mod = require("maxa.interactions.chat")
local chat = chat_mod.buf_get_chat(bufnr)
```

Latest chat:

```lua
local chat = require("maxa").last_chat()
```

## Chat Fields And Persistence

| Field | Meaning | Persists? |
| --- | --- | --- |
| `chat.messages` | message list | yes |
| `chat.messages[]._meta` | message metadata | yes |
| `chat.adapter` / `chat.adapter.name` | adapter instance/name | adapter name only |
| `chat.adapter.model.name` | model name | yes |
| `chat.adapter.features` | runtime feature declaration | no |
| `chat.ui.tokens` | runtime token count | no |
| `chat.opts.save_id` / `title` | history identity/title | yes |
| `chat.context_items` | context panel items | yes |
| `chat.status` / `chat.bufnr` | runtime state/buffer | no |
| `chat._xxx` | custom runtime field | no |

History saves: `save_id`, `title`, `messages`, `settings`, adapter name, `updated_at`, `context_items`, `schemas`, `in_use`, `cycle`, `title_refresh_count`, `cwd`, and `project_root`.

Persistence rules:

- `chat._xxx` runtime fields are lost after save/restore.
- Cross-save state must live in `messages[]._meta`, not runtime fields.
- Runtime fields are appropriate only for same-turn coordination, such as handler flag -> done hook check.

Persistent state pattern:

```lua
table.insert(chat.messages, {
  role = "user",
  content = "...",
  _meta = { tag = "my_feature", my_state = "value" },
})

local function get_my_state(messages)
  for _, msg in ipairs(messages) do
    if msg._meta and msg._meta.tag == "my_feature" then
      return msg._meta.my_state
    end
  end
  return nil
end
```

## Adapter Capability

Token support:

```lua
local has_tokens = chat.adapter
  and chat.adapter.features
  and chat.adapter.features.tokens == true
```

`chat.ui.tokens` updates during LLM response processing. After restore it may be 0/nil until a new response arrives.

Context window rule:

- Copilot `/v1/models` does not return context window.
- Maintain adapter/model prefix mappings manually when needed.
- Same model through different adapters may have different effective windows.
- Return `nil` for unknown model/window; callers must treat nil as untrusted and avoid critical threshold decisions.

Pattern:

```lua
local ADAPTER_CONTEXT_LIMITS = { copilot = 200000 }

local function resolve_adapter_limit(adapter_name)
  if ADAPTER_CONTEXT_LIMITS[adapter_name] then
    return ADAPTER_CONTEXT_LIMITS[adapter_name]
  end
  return nil
end
```

## Hooking Chat Lifecycle

### `done()` hook

Use only when necessary. Always call `original_done` unless intentionally taking over control flow.

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "MaxaAIChatCreated",
  callback = function(args)
    local chat = get_chat_from_bufnr(args.data.bufnr)
    if chat then hook_chat_done(chat) end
  end,
})

local function hook_chat_done(chat)
  if chat._my_hook_applied then return end
  chat._my_hook_applied = true

  local original_done = chat.done
  chat.done = function(self, output, reasoning, tools, meta, opts)
    if opts and opts.status == "stopped" then
      return original_done(self, output, reasoning, tools, meta, opts)
    end

    -- custom logic

    return original_done(self, output, reasoning, tools, meta, opts)
  end
end
```

`done()` args: `output`, `reasoning`, `tools`, `meta`, `opts`; `opts.status == "stopped"` means user cancellation.

If `original_done` is skipped accidentally, `current_request`, status, and UI locks may not reset.

### `submit()` hook

```lua
local original_submit = chat.submit
chat.submit = function(self, ...)
  -- before submit
  return original_submit(self, ...)
end
```

Patch `submit()` only with clear ordering and conflict analysis.

### Message injection

Invisible message:

```lua
table.insert(chat.messages, {
  role = "user",
  content = "message",
  _meta = { tag = "my_tag" },
  opts = { visible = false },
})
```

Visible message:

```lua
chat:add_message({ role = "user", content = "message" }, { visible = true })
```

`visible=false` sends to LLM but does not render to buffer.

## `_meta` And Compression

Standard tags preserved by compact filtering include `system_prompt_from_config`, `rules`, `file`, `variable`, `compact_summary`, and special image handling. Custom tags are removed by default unless registered in compact filters.

If a message must survive compression, update compact filtering rules. If it should be stripped before compression, add a focused strip helper such as `compact_utils.strip_transient_compaction_messages()`.

## Tool Handler + Done Hook Pattern

Use this when a tool should request an action after the current LLM turn finishes.

```text
LLM calls tool -> handler sets chat runtime flag -> returns
LLM turn completes -> done() hook checks flag -> action runs at safe point
```

```lua
local function handler(req, res)
  local chat = get_chat(req)
  chat._my_action_requested = true
  chat._my_action_params = req.params
  return res:text("Requested; will run after current turn"):send()
end

chat.done = function(self, output, ...)
  if self._my_action_requested then
    self._my_action_requested = nil
    local params = self._my_action_params
    self._my_action_params = nil
    do_my_action(self, params)
    return -- only if action intentionally takes over control flow
  end
  return original_done(self, output, ...)
end
```

Do not mutate messages and submit from inside the handler while the LLM is still streaming.

## Pitfalls

- Do not `chat:add_message()` + `chat:submit()` inside a handler during the active turn.
- Do not trust `chat.ui.tokens` immediately after restore.
- Do not use `chat._xxx` for cross-save state.
- Do not skip `original_done` accidentally.
- In delayed callbacks, verify chat and buffer validity:

```lua
if chat and chat.submit and chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
  chat:submit()
end
```
