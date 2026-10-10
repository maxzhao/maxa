---
title: Session 查询、探测、Transfer 与 Trace 工具规格
created: 2026-06-28
updated: 2026-10-09
type: source
doc_role: spec
authority: accepted
status: active
capability: session-tools
sources:
  - lua/maxa/mcphub/native_servers/session/init.lua
  - lua/maxa/session/history_core.lua
  - lua/maxa/session/history_session.lua
  - lua/maxa/session/loaded_items.lua
  - lua/maxa/session/tools/
  - lua/maxa/session/session_trace.lua
  - abilities/session/scripts/trace_visualize.py
  - abilities/session/tests/test_trace_visualize.py
  - .maxa/.stignore-shared
  - .maxa/.obsidian/app.json
  - specs/abilities/base/project-admin/project-vault.md
confidence: high
review:
  human: passed
  evidence: user-declared-change-review-2026-10-07
---

### Scope

Owns non-compression session tools, transfer, trace query/synthesis and visualization export. [Session compression](./session-compression.md) owns compression; [Session history](../../../runtime/session-history.md) owns storage/UI.

### Query and probe tools

**Read contract**: use pagination/search/summary for large history. Missing marker/current session/id returns an explicit error, never a guessed source.

| `save_id` contract | Tools |
| --- | --- |
| MAY omit if current Chat resolves; otherwise `No current session found` style error | `get_message`, `get_messages`, `search_messages`, `get_loaded_items`, `get_session_stats` |
| Required | `get_chat_summary`, `get_session_status` |

#### Requirement: `session` exposes bounded primitives

Native `session` SHALL expose `session__*` primitives for saved Chat listing, summary/messages/search, loaded items, stats/status, structural probes, trace query, explicit transfer and compression. Agents SHALL use these instead of direct history JSON reads/writes; trace/transfer additions SHALL preserve query defaults. Workspace-only `handoff_compact` owns prepare/plan/apply, exact source ID, interval/tier parameters and file/concise handoff-summary inputs under [Session compression](./session-compression.md); it is not an unrestricted saved-history mutation API.

#### Requirement: Composite Session loading

`load(target="session")` MUST commit same-name Skill guidance, references, trace exporter and existing Native MCP tools together through `merge:true`, without self dependency or `session-admin` alias. Active callers/source references MUST use `session`; tool names/schemas, query defaults, source policy and authorization stay unchanged. Other historical sessions are not automatically rewritten; a removed loaded revision must be retired before continuing through the new entry.

#### Requirement: Listing and summary avoid message expansion

| Tool | SHALL return |
| --- | --- |
| `session__list_chats(limit?,skip?)` | Current-project index metadata in descending `updated_at` order, default limit 10 and implementation cap; no bodies or cross-project scan. |
| `session__get_chat_summary(save_id)` | Bounded title/metadata/message/context facts, not full history. |

#### Requirement: Message reads are precise and paged

`session__get_messages(save_id?,skip?,take?,mode?)` SHALL default to `mode=summary`; `mode=full` requires explicit selection. Accept only `summary|full`; invalid pagination/query/index returns explicit parameter error. `session__get_message` returns one 1-based message; `session__search_messages` requires a nonempty query and returns snippets/summary facts matching content, tool names or arguments.

#### Requirement: Loaded items hide context bodies

`session__get_loaded_items` SHALL return loaded skill/context-file/MCP-server identifiers, not hidden context bodies.

#### Requirement: Stats/status are bounded

`session__get_session_stats` SHALL aggregate roles, metadata/tags, tool structure and context status; `session__get_session_status(save_id)` SHALL report token/serialized JSON-size pressure through the shared formatter. Neither substitutes for full messages.

#### Requirement: Probe locates structure, not content

`session__probe_messages` SHALL require probes, partition request or `include_context_status`, returning 1-based indices/partition/status facts for precise follow-up, not full messages. Compression-target guards MAY require a specific `save_id`.

### Cross-project transfer

#### Requirement: `session__transfer_chat` is explicit and metadata-only

Input SHALL require current-project `save_id`, `target_project_root` containing `.maxa/`, and `mode=copy|move`; validate before any target write/source delete. Missing/invalid target/mode/id SHALL fail explicitly. Success returns mode, source project/id, target project/new id/path and source-deletion fact, without `messages`. Copy preserves source; move deletes only after target file/index success. Default listing stays current-project only; old `cc_history__copy_chat`/`move_chat` identities SHALL NOT be exposed.

### Trace query

#### Requirement: `session__get_trace` reads recorded or synthesized lineage

Tool SHALL accept `root_trace_id` or `save_id` and bounded options including `mode=summary|full`, `include_archives`, `synthesize_if_missing`, `skip`, `take`.

| State | Result |
| --- | --- |
| Recorded | `source=recorded`; mode-appropriate manifest, paged events, archive metadata/content. |
| Missing, synthesis enabled | `source=synthesized`; recoverable user/assistant turns, detectable SubAgent calls/results, fragment metadata and compression provenance from saved history, with evidence indices and gaps. |
| Missing, synthesis disabled | Error. |

Summary SHALL NOT dump unlimited JSONL/archives. Synthesis SHALL distinguish inference from records and never claim absent temporary-child/deleted-scratch/compressed raw content. Malformed trace lines MAY yield warnings/partial model only with sufficient valid data. Ordinary message tools retain independent summary/full semantics.

### Trace visualization exporter

#### Requirement: V1 is a session-admin script, not an MCP/slash tool

Current package identity is `session`. `abilities/session/scripts/trace_visualize.py` SHALL use its owning uv project:

```bash
uv run --project abilities/session python abilities/session/scripts/trace_visualize.py --project-root <PROJECT_ROOT> (--root-trace-id <ID>|--save-id <ID>) [options]
```

After `load(target="session")`, Agents SHALL invoke `@session:/scripts/trace_visualize.py` with literal argv. Existing flags, output metadata, generator labels, containment and overwrite protections stay unchanged. V1 SHALL NOT add `session__trace_visualize` or `/trace_visualize`.

Exporter reads recorded/synthesized traces and defaults to `.maxa/history/traces/<root_trace_id>/visualization/`, producing `trace-overview.canvas` and `trace-summary.md` under the contracts below. It SHALL NOT mutate manifest/events/archive/chat sources or fabricate recorded files for synthesized output.

#### Requirement: Export is deterministic, bounded and safe

CLI SHALL support project root, root/save id, safe output dir, repeatable `--format canvas|markdown`, `--mode summary|full`, archive/synthesis flags, `--overwrite`, `--max-events`, `--excerpt-chars`, `--json`. Existing files default to conflict error; overwrite requires explicit choice. Absolute/traversal/out-of-bound output SHALL fail before writes.

JSON SHALL return root id, `recorded|synthesized` source, output dir/files, event/span/archive counts, warnings and validation status—not generated bodies. Canvas validation or multi-file export failure SHALL NOT publish misleading partial success; temporary/atomic publication is preferred.

#### Requirement: Canvas represents span/action lineage

`trace-overview.canvas` SHALL be valid JSON Canvas with unique stable IDs, supported `text|file|link|group` nodes, existing edge endpoints and deterministic integer layout. Use span/session groups, parent-child edges, bounded action nodes and aggregated natural turns, not unbounded per-turn nodes; include fork/scratch/merge/fragment/SubAgent/ask_llm/multi_agent/compression actions when present.

#### Requirement: Markdown is the review entrypoint

`trace-summary.md` SHALL identify generated artifact/root/source/generator, link Canvas/source locations, and provide TLDR, trace metadata, event-kind counts, span/session table, action timeline, archive table, gaps/warnings and validation/export command. Prompt/reply excerpts are explicitly labeled and bounded; no unlimited sensitive dump.

#### Requirement: Visualization is narrowly Vault-visible

Narrow include exceptions SHALL make generated `visualization/*.canvas|md` Obsidian-openable/Syncthing-syncable while raw `.maxa/history/**` stays ignored. Actual ignore semantics SHALL be validated; exceptions MUST NOT re-enable raw `events.jsonl`, manifest/index, archives, chat history or unrelated runtime files. Generated runtime trace data needs no per-export knowledge/spec index/log update. [Project Vault Governance](../project-admin/project-vault.md) owns visibility policy.

### Validation

#### Evidence retained

| Historical evidence | Result/scope |
| --- | --- |
| Composite loading | Focused catalog/loader, moved exporter/policy/hook checks and fresh-Neovim load/list_chats establish composition and unchanged dispatch. Compression not invoked; human/model-behavior review `not-run`. |
| Session query/probe/transfer owner tests and representative post-restart Native calls | Passed. |
| Trace storage/query tests and live recorded/synthesized `session__get_trace` | Before required restart, live Native schema lacked `get_trace`; call failed with `Tool 'get_trace' not found`. After full restart/reload, schema and recorded/synthesized calls passed, returning bounded results. |
| Visualization tests, help and recorded-trace export | 5 tests passed; help/export reported 26 events, 6 spans, 1 archive; Canvas/edges/Markdown validation passed. |
| User specification review | `passed`. |

#### Unrun/limited evidence

Some individual query tools have only indirect module coverage. Permanent evidence state:

| Surface | Status and limit |
| --- | --- |
| Recorded query/trace/export automated and runtime checks | `passed`. |
| Human Obsidian Canvas rendering | `not-run`; file parse/reference checks do not prove UI rendering. |
| Effective cross-device Syncthing behavior | `partial`; simulated/tested, not proven on every client. |
| Human specification review | `passed`. |

### Source trace

The `sources` paths identify the Native adapter, tool owners, history/trace helpers, exporter, and visibility policy/tests. Visibility governance remains with [Project Vault Governance](../project-admin/project-vault.md).
