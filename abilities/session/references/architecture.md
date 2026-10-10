# Architecture

## Components

```text
Neovim + MaxaAI
├─ session history owner (`lua/maxa/session/history/`)
│  ├─ auto-save on RequestFinished / ToolsFinished / ChatSubmitted
│  ├─ title generation
│  ├─ Picker UI: browse, rename, delete, duplicate
│  └─ session restore through `create_chat`
├─ llm_error_recovery (`lua/maxa/session/llm_error_recovery.lua`)
│  ├─ hooks `chat.done()`
│  ├─ captures `_submit_http()` errors for selected adapters
│  ├─ detects `token_limit`, `network_issue`, `rate_limited`, `invalid_signature`
│  └─ triggers shared handoff compaction or retry
├─ JSON storage
│  ├─ `{base}/index.json`
│  ├─ `{base}/chats/*.json`
│  └─ `{base}/caches/*.json`
└─ session Native MCP Server
   ├─ query/status tools
   ├─ compression tools
   └─ slash commands: `compact_silent`, `compact_rescue`
```

## Storage Format

Directory:

```text
{base}/
├── index.json
├── chats/
│   └── <save_id>.json
└── caches/
    └── <sha256>.json
```

Base path resolution:

1. Current buffer project root containing `.maxa` -> `.maxa/history/`.
2. Loaded buffers scan -> same detection.
3. Oldfiles last 50 -> same detection.
4. Fallback -> `stdpath("data")/maxa-ai/history/`.

`Storage:get_chats()` and `Storage:save_chat()` re-check project dir on each call.

## Prompt-Cache Warmup Cache

`default_session_cache.lua` stores reusable default-session prefixes at `{base}/caches/<sha256>.json`.

Record fields include warmup messages, `context_items`, tool schemas/in_use, adapter/model/settings/request fingerprint, and `prefix_count`. Hash is built from the real request snapshot to avoid cross adapter/model/settings/tool reuse.

State:

- In-memory: `chat._default_session_cache_checked`.
- Persistent: `chat.messages[1]._meta.default_session_cache` with `checked/status/hash/request_digest/at/version`.
- Restored sessions set `_history_restored=true`; default-session auto warmup refuses them.
- Resume skips only when `request_digest` still matches current prefix.

Reasoning cleanup:

- Warmup cache stores final assistant content, not `reasoning`.
- Old cache records are sanitized before reuse and written back.

Deletion/reuse rules:

- Delete existing cache only when provider usage proves cache miss.
- Do not delete a newly created cache from the same real request.
- Non-default fresh SubAgent sessions must explicitly enable warmup; inherited/restored sessions should not warmup.

## Schemas

### `index.json`

```json
{
  "1234567890": {
    "save_id": "1234567890",
    "title": "Session title",
    "updated_at": 1704067200,
    "model": "claude-sonnet-4-20250514",
    "adapter": "copilot",
    "message_count": 42,
    "token_estimate": 15000,
    "cwd": "/home/user/project",
    "project_root": "/home/user/project"
  }
}
```

### Chat JSON

```json
{
  "save_id": "1234567890",
  "title": "Session title",
  "updated_at": 1704067200,
  "adapter": "copilot",
  "settings": { "model": "claude-sonnet-4-20250514" },
  "messages": [
    {
      "role": "system|user|llm|tool",
      "content": "...",
      "opts": { "visible": true, "tag": "file" },
      "_meta": { "duration_ms": 1234 },
      "tools": {
        "calls": [{ "id": "...", "function": { "name": "...", "arguments": "{}" } }],
        "call_id": "..."
      }
    }
  ],
  "context_items": [{ "id": "<tool>name</tool>", "source": "tool", "opts": {} }],
  "schemas": {},
  "in_use": {},
  "cycle": 3,
  "title_refresh_count": 1,
  "cwd": "/home/user/project",
  "project_root": "/home/user/project"
}
```

Message roles:

| Role | Meaning | Key fields |
| --- | --- | --- |
| `system` | initial system prompt | `opts.tag`, `opts.visible` |
| `user` | user input, tool results disguised as user | `tools.call_id` when tool result |
| `llm` | assistant response | `tools.calls[]` when tool calling |
| `tool` | tool execution result | `tools.call_id`, `_meta.duration_ms` |

## Data Flow

### Save

```text
LLM response completes
-> MaxaAIRequestFinished / ToolsFinished
-> session history callback
-> sanitize_tool_call_arguments(messages)
-> sanitize_messages_utf8(messages)
-> Storage:save_chat(chat)
   -> write chats/{save_id}.json
   -> update index.json
```

### Restore

```text
Picker selects save_id
-> Storage:load_chat(save_id)
-> UI:create_chat(chat_data)
   -> _pre_process_messages
      -> sanitize tool args
      -> remove orphan/incomplete tool groups
      -> extract pending user content
      -> deep-copy API-clean original_messages
      -> set display visibility and tool summaries
   -> Chat.new(opts)
   -> _post_process_chat
      -> replace chat.messages with original_messages
      -> restore context_items + tool_registry
      -> prefill pending user content
      -> restore Ability hooks
      -> highlight summaries and subagent folds
```

### Handoff compression

`handoff_compaction.lua` owns interactive/config commands, instructions-only compact_self and active token/threshold recovery: safe source save → real executor prepares successor context → probe-indexed tier segments → user/config user message → executor-written useful omitted summary → original records copied → verified type-preserving commit. `handoff_compact` is workspace-only with prepare/plan/apply phases. Source indices come from `history_session.get_messages_source`, not raw storage. Public run_agent handoff validation stays unchanged; internal commit is shared.

`/compact_silent` selects the configured profile; `/compact_rescue` displays the segment table and waits for a user message. Both are thin entrypoints to the same controller; the old mini-loop/rescue implementation and separate prompts are removed. Explicit range/history tools still share message/error/streaming primitives.

### Incremental collapse

`slash_commands/collapse.lua` saves a full persistent fork and closes the source before summarizing. Reverse-search `collapse_summary` for the next start; initially skip the protected foundation and contiguous tagged cache warmup request/response/tool results, retaining that prefix verbatim in place. It reuses fork/summary/render helpers, preserves required context and complete tool records, saves the tagged replacement, and leaves editable input without task auto-submit. Precise `collapse_tail` remains independent.

## File Map

| Target | Path |
| --- | --- |
| Storage/restore logic | `lua/maxa/session/history/storage.lua` |
| Picker UI | `lua/maxa/session/history/pickers/` |
| Title generation | `lua/maxa/session/history/title_generator.lua` |
| Session restore UI | `lua/maxa/session/history/ui.lua` |
| MCP query/compact tools | `lua/maxa/session/tools/` |
| Shared handoff compaction | `lua/maxa/session/handoff_compaction.lua` |
| Configured handoff entrypoint | `lua/maxa/session/slash_commands/compact_silent.lua` |
| Rescue compaction | `lua/maxa/session/slash_commands/compact_rescue.lua` |
| LLM error recovery / compact_self dispatch | `lua/maxa/session/llm_error_recovery.lua` |
| Token reminder hooks | `abilities/session/hooks/` |
| Shared compaction prompt | `lua/maxa/session/handoff_compaction_prompt.md` |
| History core helpers | `lua/maxa/session/history_core.lua` |
| Compaction message helpers | `lua/maxa/session/compaction_messages.lua` |
| Session persistence helpers | `lua/maxa/session/history_session.lua` |
| Loaded-item extraction | `lua/maxa/session/loaded_items.lua` |
| Streaming LLM shared module | `lua/maxa/mcphub/native_servers/shared/streaming_llm.lua` |

## Reference Routing

- Storage format / restore flow / extension API -> `references/history-ext-api.md`.
- Data flow / compression flow -> `references/architecture.md`.
- Detection strategy / adapter support -> `references/auto-compact.md`.

## Testing

- Configured compaction: `/compact_silent` -> source retained, verified successor submits.
- Interactive compaction: `/compact_rescue` -> segment table, user profile message, then successor transfer.
- Tool smoke: `@session:list_chats` -> bounded JSON result.
- Restore: save -> close -> Picker restore -> tool summaries and `context_items` preserved.
- Recovery: simulate token limit -> auto compaction; simulate ChatSubmitted token threshold -> pre-submit reminder.

## Troubleshooting

| Problem | Check |
| --- | --- |
| Tool summaries disappear after compaction | `ui.lua:_pre_process_messages` summary rebuild |
| `context_items` lost after restore | `ui.lua:_post_process_chat` context restore |
| `llm_error_recovery` not triggered | `ADAPTER_DETECTORS`, `session/init.lua` setup |
| false recovery trigger | `detect_issue`, `output_empty` logic |
| API 400 after compaction | `compact_utils.normalize_tool_messages` |
| endless network retry | `_network_retry_count` vs `max_retries` |
| saved to wrong directory | `get_project_history_dir()` detection order |
| Picker missing sessions | broken `index.json` or directory switch |

## `context_status` Contract

Purpose: LLM-facing session pressure summary shared by session and SubAgent result contracts. Producer: `lua/maxa/session/session_status.lua`.

Shape:

```json
{
  "save_id": "1780487197",
  "tokens": {
    "used": 173947,
    "limit": 300000,
    "percent": 58,
    "source": "actual"
  },
  "messages_json_bytes": 784254,
  "message_count": 465
}
```

Rules:

- `messages_json_bytes` is `#vim.json.encode(messages or {})`.
- `tokens.source` is `actual`, `meta`, `estimated`, or `unknown`.
- If `tokens.used` and `tokens.limit` exist, recompute `tokens.percent` from them.
- `get_session_stats.token_usage.current/context_window/ratio` must derive from `context_status.tokens`.

Entrypoints:

- `lua/maxa/session/session_status.lua`
- `lua/maxa/session/tools/get_session_status.lua`
- `lua/maxa/session/tools/get_chat_summary.lua`
- `lua/maxa/session/tools/get_session_stats.lua`
