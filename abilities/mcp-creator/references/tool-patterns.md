# Common Tool Patterns

Tool results must be designed by tool type. Do not force every tool into one universal format. Full contract: `references/llm-facing-tool-contract.md`.

## 0. LLM-Facing Result Types

| Type | Tools | Return focus |
| --- | --- | --- |
| Query | list/search/get/stats/probe | source, scope, count, key results, pagination/truncation, id/path/range |
| State change | write/delete/move/compact/commit/fire | status, changed object, side effects, new state/id/path, validation/restart fact |
| Context injection | load/load/load | injected object, source, dedupe/reload, TTL/persist, reference method; do not repeat injected full text |
| Ephemeral image analysis | analyze | required ordered images/task/budget, one bounded combined report and ordered processing facts; no parent image attachment or TTL handling |
| File read | read/log reader | bounded content/range, line numbers, size limit, oversized stats, next read suggestion |
| Execution | shell/Windows/Lua/tool proxy | status, exit/error, cwd/env differences, bounded stdout/stderr, long input preview/hash |
| Media/binary | image/audio/binary | path/URL, MIME/type/format/size, preview/load guidance; no base64 body |
| Workflow guidance | guard/handoff | attempt/session/stage, required next tool, stop condition, format constraints |
| Subagent/orchestration | run_agent/fork/parallel/workflow | minimal continuation metadata plus complete raw final answer; no output truncation or task/config echo |

Design checks:

- Can the LLM judge success/failure and current state from result only?
- Does normal success avoid generic `next_action`, tutorials, and broad advice?
- Are tool composition and state interpretation documented in Ability/reference docs?
- Are large inputs not echoed and output-volume rules appropriate to this tool, preserving complete/exempt answers?
- Does the final LLM payload use the consumer-oriented representation from the shared contract, without an unnecessary universal envelope?
- Are later references such as path/id/save_id/attempt_id present?
- Are errors concise and actionable?

## 1. CRUD / File Data Management

Reference: `session`.

Use for config/data/session lists. Pattern: shared read/write/parse helper, one tool per business action, unified errors, stable response shapes.

## 2. External API / System Bridge

Reference: `winctl`.

Use for third-party services, webhooks, REST APIs, OS bridges. Pattern: helper module wraps command/API call, config, timeout, parsing, and concise diagnostics.

## 3. Neovim API Integration

Reference: `session`.

Use for editor/plugin/UI operations. Handle buffer/window/chat validity, plugin APIs, async callbacks, and runtime-only state.

## 4. Context Injection

Reference: `maxa.interactions.chat.tools.builtin.tools.builtin_load` and `load`.

Use for dynamic knowledge/doc/image loading. Pattern: `ability_utils` sanitizes context and the deferred transaction injector appends it after the tool result, dedupes by context id, uses `_meta.tag` for compression behavior, and returns concise load facts rather than repeated full content.

## 5. System Command Wrapper

Reference: `winctl`.

Use for CLI/system tools. Return status, exit code, cwd/env, bounded stdout/stderr, and preview/hash/stats for long command/output. Do not echo full commands, heredocs, scripts, large JSON, or secrets by default; the command already exists in tool parameters.

## 6. Managed Resource Start/Status/Stop

Use for browsers, background services, external processes, CDP endpoints, and test environments.

| Tool | Responsibility | Return focus |
| --- | --- | --- |
| `*_start` | start or reuse resource; perform necessary smoke check | status, endpoint/path/id, managed, pid, logPath, smoke.ok, connected |
| `*_status` | report facts | running/ready/connected, managed, endpoint/path/id, logPath |
| `*_stop` | clean up resources owned by this tool | stopped/not-running/external-not-stopped, managed, pid, logPath |

Rules:

- `*_start` may prepare and smoke-test internally, but successful output should be factual, not tutorial-like.
- `*_status` should not contain long next-step advice; document interpretation in references.
- `*_stop` cleans only resources managed by this tool; never kill reused external resources silently.
- Server shutdown should best-effort clean managed resources.
- Prefer a few stable tools over micro-tools for prepare/connect/verify/extract steps.
