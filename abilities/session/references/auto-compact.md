# LLM Error Recovery

Location: `lua/maxa/session/llm_error_recovery.lua`.

Purpose: hook Maxa AI chat completion and transport calls, detect LLM transport/context failures, and trigger retry or compaction. Token threshold reminders are handled by `abilities/session/hooks/ToolCallsCompleted.lua` and `hooks/ChatSubmitted.lua`, not here.

## Detection Pipeline

```text
chat.done(output, reasoning, tools, meta, opts)
  -> skip user cancel (`opts.status == "stopped"`) and soft subagent interrupt
  -> build context: output_empty, recent chat._last_http_error, has_tools, status
  -> detect_issue(chat, context)
       -> resolve_detector(adapter metadata)
       -> detector returns token_limit | network_issue | rate_limited | invalid_signature | permanent | nil
  -> token_limit       -> reset_network_retry -> trigger_auto_compact
  -> network_issue     -> trigger_network_retry when chat has submitted
  -> rate_limited      -> trigger_rate_limited_retry when chat has submitted
  -> invalid_signature -> mark reasoning tainted -> immediate retry
  -> permanent         -> clear retry state and stop automatic retry
  -> nil               -> original_done
  -> compact_self flag -> trigger_self_compact after current done
  -> successful non-empty response -> reset_network_retry
```

## Adapter Detectors

### `kiro_anthropic` / `kiro_anthropic_thinking`

```text
output_empty?
  no -> nil
  yes + has_tools -> nil
  yes + status != "success" -> nil
  yes + status == "success":
    tokens/max_tokens >= 0.80 -> token_limit
    otherwise                 -> network_issue
```

Token source: `chat.ui.tokens` or `estimate_tokens(messages)` using chars / 2.5.
Context window table includes `claude-sonnet-4-5: 200k`, `gpt-4o: 128k`, default `100k`.

### OpenAI Responses / compatible gateways

Uses HTTP or SSE error details captured by `_submit_http` and the Responses stream hook. The legacy detector function name remains internal, but classification is protocol/provider based rather than Copilot Proxy specific.

```text
last_error:
  local account-pool exhaustion -> rate_limited delayed recovery
  model_not_supported / unsupported_api_for_model -> permanent, no retry
  token_limit patterns    -> token_limit
  invalid_signature       -> invalid_signature
  retryable patterns      -> network_issue
  unknown                 -> nil
status == "error" + output_empty -> network_issue
output_empty + no error + no tools:
  last message is tool result -> nil
  otherwise                   -> network_issue
```

Pattern groups:

| Group | Patterns |
| --- | --- |
| Token limit | `model_max_prompt_tokens_exceeded`, `exceeds the limit`, `context_length_exceeded`, `maximum context length` |
| Retryable network | `Connection timed out`, `curl: (28)`, `curl: (92)`, `token expired`, `unauthorized` |
| Invalid signature | `Invalid.*signature.*thinking`, `invalid_request_body.*signature`, `Bad Request` |
| Permanent protocol/model | `model_not_supported`, `unsupported_api_for_model` |
| Local account pool | `No available accounts. All accounts are expired or rate-limited.` (provider=`local`) |

## Retry Mechanisms

### Network Retry

```lua
NETWORK_RETRY_CONFIG = { max_retries = 5, delays = { 10, 20, 30, 60, 60 } }
```

Flow: reset request/status/UI lock -> `vim.fn.timer_start(delay * 1000)` -> `chat:submit({ auto_submit = true })` -> track `_network_retry_count` / `_network_retry_pending` -> success resets retry -> exhaustion sets `_network_retry_exhausted` and notifies error. Ctrl+C cancels pending timer via `cancel_retry_timer`.

### Rate Limited Retry

```lua
RATE_LIMITED_RETRY_CONFIG = { max_retries = 5, delays = { 10, 20, 30, 60, 60 } }
```

Shows countdown in chat buffer through extmark virtual text, updated every 10s.

### Invalid Signature Retry

When an active compatible gateway rotates accounts, old reasoning signatures can become invalid.

1. Mark messages with `reasoning` as `_meta.reasoning_tainted = true`.
2. `form_messages` skips reasoning for tainted messages.
3. Retry immediately.
4. If all relevant reasoning is already tainted, stop retrying this class.

## Compression Triggers

Both paths call `handoff_compaction.start`; `compact_self` supplies preservation instructions without a mode. `/compact_silent` uses the same configured path; `/compact_rescue` uses its interactive selection path. The legacy mini-loop and rescue workspace are retired.

### Token Limit Rescue

1. Set `chat._auto_compact_in_progress = true`.
2. Temporarily block `chat.dispatch` `on_completed` / `on_error` during compression.
3. Call `original_done` to reset chat state.
4. Run `handoff_compaction.start(chat, on_success, on_error)` at the source safe boundary.
5. Success: restore orchestration and commit the successor; the shared controller submits that successor, never the retired source.
6. Failure: restore dispatch, fire `on_error` with message.

### Self Compact

1. `compact_self.lua` sets request fields and calls `trigger_self_compact(chat, instructions)`.
2. Run `handoff_compaction.start(chat, on_success, on_error, { instructions = "..." })` for preparation, tiers, configured selection, LLM-written omitted-history summary and index copying.
3. Fresh successor preserves source business configuration, required context and selected complete records, not the entire parent input prefix.
4. Failed/ended ordinary child invocations report errors and saved IDs; no compact_full overwrite fallback runs after executor completion.

## Hook Installation

```text
M.setup()
  -> hook existing Maxa AI chat buffers
  -> listen MaxaAIChatCreated
  -> hook_chat_done(chat)
       -> resolve detector
       -> hook_submit_http_for_error_capture for copilot/OpenAI Responses adapters
       -> hook chat.submit to track _has_submitted and reset retry count
       -> hook chat.done for detection + response pipeline
```

## Add Adapter Support

1. Add detector: `local function detect_new_adapter(chat, context) ... end`.
2. Register in `ADAPTER_DETECTORS`.
3. Add `_submit_http` error capture condition if needed.
4. Add error patterns when required.
5. Add context window size to `CONTEXT_WINDOW`.

## Chat State Fields

| Field | Purpose |
| --- | --- |
| `_auto_compact_hooked` | prevent double hook |
| `_auto_compact_disabled` | disable for rescue sessions |
| `_auto_compact_in_progress` | compression active |
| `_has_submitted` | user has submitted at least once |
| `_network_retry_count` | current retry count |
| `_network_retry_pending` | retry timer active |
| `_network_retry_cancelled` | user cancelled retry |
| `_network_retry_exhausted` | all retries exhausted |
| `_network_retry_timer` | timer ID for cancellation |
| `_network_retry_last_detail` | diagnostic text |
| `_rate_limited_retry_count` | rate-limit retry count |
| `_last_http_error` | captured HTTP error body |
| `_last_http_error_time` | capture timestamp |
| `_last_http_status` | HTTP status code |
| `_subagent_interrupted` | soft interrupt flag |

## Relationship To `context_status`

LLM recovery, AbilityHook token reminders, and lualine token display share low-level token data through `maxa.session.token_usage`. `context_status` / `_session_status` wraps it for LLM-facing tools, hooks, and historical sessions.

Rules:

- Use `token_usage` for live threshold detection and lualine display.
- Use `_session_status` in AbilityHook data for pre-submit token reminders.
- Use `context_status` for tool results, history queries, and parent-agent awareness.
- Do not add a separate token/window calculation path; extend `session_status.lua` or `token_usage.lua` instead.
