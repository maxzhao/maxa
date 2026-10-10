# Session History API

Location: `lua/maxa/session/history/`.

Purpose: Maxa AI-owned chat persistence. `require("maxa.session").history()` exposes the initialized public history API; `require("maxa.session.history_session").get_history_api()` is the session-helper accessor.

## Exports API

```lua
exports.get_location()                         -- string|nil storage base path
exports.save_chat(chat?)                       -- save chat; nil falls back to last_chat
exports.browse_chats(filter_fn?)               -- open picker with optional filter
exports.get_chats(filter_fn?)                  -- table<string, ChatIndexData>
exports.load_chat(save_id)                     -- ChatData|nil
exports.delete_chat(save_id)                   -- boolean
exports.duplicate_chat(save_id, new_title?)    -- string|nil new_save_id
```

## Storage Class

Location: `storage.lua`.

Key methods:

```lua
Storage.new(opts)                    -- detect project dir, ensure dirs, clean expired
Storage:save_chat(chat)              -- validate -> sanitize -> save file -> update index
Storage:load_chat(id)                -- read chats/{id}.json -> ChatData
Storage:get_chats(filter_fn?)        -- read index.json -> optional filter -> metadata table
Storage:get_last_chat(filter?)       -- most recently updated chat
Storage:delete_chat(id)              -- delete file + remove index entry
Storage:rename_chat(id, title)       -- update index + chat file
Storage:duplicate_chat(id, title?)   -- deep copy -> new save_id -> save
Storage:clean_expired_chats()        -- delete chats older than expiration_days
Storage:get_location()               -- base_path
```

Save pipeline:

```text
validate_chat_object(chat)
-> re-check get_project_history_dir()
-> temporarily restore Gemini thinking adapter/model names
-> sanitize_tool_call_arguments(messages)
-> sanitize_messages_utf8(messages)
-> write chats/{save_id}.json
-> update index.json metadata
```

## Types

```lua
---@class MaxaAI.History.ChatIndexData
---@field save_id string
---@field title string?
---@field updated_at number
---@field model string
---@field adapter string
---@field message_count number
---@field token_estimate number
---@field cwd string?
---@field project_root string?
```

```lua
---@class MaxaAI.History.ChatData
---@field save_id string
---@field title string?
---@field messages table[]
---@field settings table
---@field adapter string
---@field updated_at number
---@field context_items table[]
---@field schemas table
---@field in_use table
---@field cycle number
---@field title_refresh_count number
---@field cwd string?
---@field project_root string?
```

## UI Restore

### `_pre_process_messages(chat_data)`

Input: saved `messages`. Output: `pending_user_content`, `original_messages`.

Steps:

1. Sanitize invalid tool call arguments.
2. Find last LLM message with tool calls and check completeness.
3. Remove duplicate tool results, keeping first.
4. Remove incomplete tool-call groups.
5. Extract pending user content from a trailing user message.
6. Deep-copy original API-clean messages.
7. Set tool visibility: hide ordinary tool results, show handoff messages.
8. Build display-only tool summaries for LLM tool-call messages.

### `_post_process_chat(chat, chat_data, original_messages, pending_user_content)`

Steps:

1. Replace `chat.messages` with API-clean `original_messages`.
2. Restore `context_items`, `tool_registry.schemas`, and `tool_registry.in_use`.
3. Clean default context display, then re-render context.
4. Prefill edit area with `pending_user_content`.
5. Restore Ability hooks from messages.
6. Highlight summary lines and create subagent folds.

### Picker

Backends: `telescope`, `snacks`, `fzf-lua`, `default`.
Actions: open existing chat, select/load from file, delete with confirm, rename, duplicate.

## Events

| Event | Handler |
| --- | --- |
| `MaxaAIChatCreated` | set title, generate save_id, load last chat |
| `MaxaAIRequestFinished` | auto-save chat interaction |
| `MaxaAIToolsFinished` | auto-save |
| `MaxaAIChatSubmitted` | title generation/refresh, auto-save |
| `MaxaAIChatCleared` | delete if configured, reset save_id |

## Configuration

```lua
{
  auto_save = true,
  expiration_days = 0,              -- 0 = never expire
  continue_last_chat = false,
  delete_on_clearing_chat = false,
  auto_generate_title = true,
  title_generation_opts = {
    adapter = nil,                   -- defaults to chat adapter
    model = nil,
    refresh_every_n_prompts = 0,
    max_refreshes = 3,
  },
  picker = "snacks",                -- telescope | snacks | fzf-lua | default
  dir_to_save = stdpath("data") .. "/maxa-ai/history",
}
```

## Session Status API

`session` exposes session pressure as `context_status`.

Tools:

- `get_session_status(save_id)` returns the status wrapper for a saved chat.
- `get_chat_summary(save_id)` includes `context_status` with summary metadata.
- `get_session_stats(save_id?)` includes `context_status`; legacy `token_usage` must mirror `context_status.tokens`.

Parent-agent usage for child session pressure:

```yaml
run:
  title: "Inspect child session status"
  scope: tool
  command: "@session:get_session_status"
  args: '{"save_id":"<child-save-id>"}'
```

`messages_json_bytes` is serialized byte size, not token estimate; display as bytes, not percent.
