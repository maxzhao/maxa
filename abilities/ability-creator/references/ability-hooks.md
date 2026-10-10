# AbilityHook Authoring Reference

AbilityHook is the event-driven message injection mechanism for Abilities.

Formats, mutually exclusive per Ability/event:

- `hooks/{EventName}.md`: Markdown hook with frontmatter and `## role` message sections.
- `hooks/{EventName}.lua`: Lua hook returning a table with `render(ctx)`.

If both `.md` and `.lua` exist for the same Ability and `EventName`, the framework reports a compatibility error and skips that event. Different Abilities may listen to the same event.

## Markdown Hook

```markdown
---
enabled: true        # optional; default true; false skips loading
load: startup        # startup | on_load
scope: session       # global | session | cascade
inject_at: post      # pre | post; default post
filter:              # optional; omitted means match all
  field_name: "value"
opts:
  visible: false
---

## user

Perform operation X...

## llm

I will perform X with these steps...
```

## Lua Hook

```lua
return {
  enabled = true,
  load = "on_load",
  scope = "session",
  inject_at = "post",
  filter = function(ctx)
    return ctx.data.field_name == "value"
  end,
  opts = {
    visible = false,
    meta = { tag = "example_hook" },
  },
  render = function(ctx)
    return {
      { role = "user", content = "Perform operation X...", _meta = { phase = "request" } },
      { role = "llm", content = "I will perform X with these steps..." },
    }
  end,
}
```

Lua rules:

- Must `return` a table and provide `render(ctx)`.
- Do not use static `prompts = { ... }` or return a bare function.
- `filter`: omitted, table, or `function(ctx)`; truthy matches, false/nil skips, errors warn and skip.
- `render(ctx)`: returns prompt list; nil/`{}` means no injection and does not consume `once`; errors behave the same.
- Lua prompts may include `_meta`; framework merges `opts.meta` and prompt `_meta` for cleanup/audit, not LLM-visible content.
- `ctx`: `event_name`, `data`, `bufnr`, `chat_id`, `hook_path`, `ability_dir`; no chat object.
- `ctx.data` receives `_session_status` when available, including token, message-byte, and message-count data.

## Field Reference

| Field | Values | Description |
| --- | --- | --- |
| `enabled` | boolean | Optional; default `true`; `false` skips parsing/registration. |
| `load` | `startup` / `on_load` | Register during startup or when the Ability loads. |
| `scope` | `global` / `session` / `cascade` | Global, current session, or current session plus child agents. |
| `inject_at` | `pre` / `post` | Injection timing; use `pre` only for synchronous event sources. |
| `filter` | object / Lua function | Event-data matching; Markdown supports object only, Lua supports object/function. |
| `opts` | object | `visible`, `once`, `ephemeral`, `meta`. |
| `render` | function | Lua hooks only; dynamically returns prompt list. |

## Message Roles

Markdown roles: `## user`, `## llm`. Lua roles: `user`, `llm`.

| Role | Use case |
| --- | --- |
| `user` | Concrete action instructions or context supplied during the session |
| `llm` | Self-reminder, plan, silent commitment |

`system` and unknown roles are invalid because AbilityHooks inject messages after a session has started. Common patterns: `llm` only for auxiliary hooks; `user+llm` for multi-step action; `user` only for concise one-step requirements.

## Silent Mode

Use silent mode for auxiliary hooks such as loading Abilities, recording lessons, or evaluating knowledge capture when the LLM should continue interrupted work.

Requirements:

1. `llm` starts with “I need to silently...” or “I will silently...”.
2. Keep core steps; remove output/report templates.
3. End with “do not report hook results and continue the interrupted work directly.”

Example:

```markdown
## llm
I need to silently load the development rules with `load(target="xxx")`; after loading, do not report the result and continue the interrupted work directly.
```

## Message Structure Constraints

The framework merges hook messages from the same tick by role before injection (`user` -> `llm`). Each hook must remain single-turn.

Allowed: `user`, `llm`, `user+llm`.

Forbidden: `user+llm+user+llm`; the `llm -> user` boundary makes the first half look like a completed turn.

Merge multi-step instructions into one `user` section and place the execution plan in the corresponding `llm` section.

## Built-In Events

`bufnr` is injected automatically. Payload fields below must be explicitly provided by the event source.

| Event | When it fires | Required payload fields |
| --- | --- | --- |
| `ChatSubmitted` | Chat submission received before LLM request | `chat_id, user_message, is_user_input, auto_submit` |
| `ToolCallError` | Tool call invalid or execution failed | `tool_id, reason, params` |
| `ToolCallsCompleted` | Tool-call batch completed | `chat_id, batch_id, mode, call_count, calls` |
| `TaskStatusChanged` | Task status updated | `task_id, tag, title, prev_status, new_status` |
| `AbilityLoaded` | Changed Ability revision committed | `ability_name` |
| `CompactStarted` | Compression started | none |
| `AutoCompactCompleted` | Automatic compression completed | none |
| `TaskStarted` | LLM starts executing a task | `task_id, tag, title` |
| `TaskPhaseChanged` | LLM enters a new phase | `task_id, tag, title, phase` |
| `TaskCompleted` | LLM completes a task | `task_id, tag, title` |
| `FileOperation` | File tool succeeded | `operation, path, rel_path, tool` |

Notes:

- `ChatSubmitted.is_user_input=true` means direct user submission. Agent-loop, tool-result, auto-submit, and programmatic submissions use `false`.
- `ToolCallsCompleted` supports `pre` and `post`; `pre` fires synchronously before tool auto-submit continuation, `post` fires after a scheduling boundary.
- `ToolCallsCompleted.calls[]` contains normalized call data. For `multicall`, consume member calls and their separate full results; the declaration reports closure facts, not a labeled nested result array. The `runs` form expands into flat member calls in input order.

## Firing Events

LLM-fired events must include complete payloads. If an Ability instructs `fire`, document the full `data` schema or a complete call example. Do not write shortened instructions such as “fire `TaskPhaseChanged` with `phase=red`”; required `task_id`, `tag`, and `title` must remain visible.

Scripts should prefer stderr `__FIRE_EVENT__`; `run` detects these lines after successful command exit and fires events without LLM involvement.

```python
import json, sys

def fire(event: str, data: dict) -> None:
    payload = json.dumps({"event": event, "data": data}, ensure_ascii=False)
    print(f"__FIRE_EVENT__:{payload}", file=sys.stderr)
```

Use `fire` only when loaded Ability documentation explicitly requires it. For full filter syntax, scope inheritance, option merging, and integration points, see `lua/maxa/abilities/hooks/README.md`.
