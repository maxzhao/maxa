---
title: SuperMax Session History and Trace
created: 2026-08-02
updated: 2026-08-02
doc_role: target-module-spec
authority: draft
status: partial
baseline: ../modules/chat-lifecycle/spec.md
---

# Contract

Session history is a core runtime capability, not a CodeCompanion extension. Each session has stable project-scoped identity, parent/child lineage, provider/model metadata, messages, event trace, status snapshots and persistence state.

## Required operations

The target MUST define behavior for create/open, list/search, title generation, restore, trace start, fork, scratch, save, merge/transfer, compaction, rewind, redo, protected-prefix management and close. Current evidence: history core owns project history directory, save IDs, unsavable IDs, index/chat JSON paths, filtering and title extraction (`lua/util/mcphub/cc_history/history_core.lua:13-358`); session operations save messages, synchronize state and create sessions from messages (`history_session.lua:105-378`); trace owns manifests, event append/index rebuild, membership, natural-turn de-duplication and compression archives (`session_trace.lua:155-1127`).

Operations MUST specify whether they mutate the active session, create a child session, append an event, or only produce a view. History operations MUST be safe when a Chat buffer is absent.

## Recovery and idempotency

Recovery reconstructs normalized messages, pending tool pairing, context budget, AgentLoop state, retry state and trace membership. Duplicate event appends are detected by stable event identity/content hash. A stopped/error turn is recorded distinctly from a successful assistant turn. Persistence failures are visible and MUST NOT silently report successful recovery. The target preserves trace membership copy/parent lineage and compression archive traceability, but must replace direct CodeCompanion chat/history API calls with runtime session interfaces.

The existing `lua/util/mcphub/cc_history/` modules and `lua/codecompanion/_extensions/history/` are evidence for behavior to preserve, not target implementation dependencies.

The minimum versioned session envelope, legacy `refs` to `context_items` migration rule, atomic write/index rebuild behavior and required replacement fixtures are defined in `../../runtime-fixture-contract.md`. Buffer/window/cursor records are view metadata, never authoritative session identity. Target writes MUST include `schema_version`; unknown future versions fail closed without overwriting durable data.

## Storage contract

Project history root is `<project-root>/.maxa/history/`. The development mother repository's `.supermax/history/` is local Agent harness data and MUST NOT be read as or written as target runtime history:

```text
.maxa/history/
├── index.json
├── chats/<save_id>.json
├── traces/<trace_id>/...
└── archives/...
```

Target `schema_version` starts at `1`. Session files and index entries include the same `save_id`, project identity, timestamps, provider/protocol/model and message count. Session data additionally contains normalized messages/context, runtime recovery state, lineage and trace membership. The index is a derived lookup structure and is rebuildable from valid session files; it is not authority over session content.

Current evidence writes a session file and then its index independently (`history/storage.lua:313-355,541-580`) through non-atomic JSON writes (`history/utils.lua:271-282`). The target corrects this:

1. Encode and validate the complete session envelope.
2. Write to a same-filesystem temporary file, flush/close, then atomically rename to the session path.
3. Update the index through the same temporary-file/rename strategy.
4. If index update fails after the session commit, return `saved-index-stale`, retain the valid session, and schedule/offer deterministic index rebuild.
5. Never report `saved` before the session commit succeeds.

Concurrent saves for one session are serialized by session identity and generation. A stale generation cannot overwrite a newer durable session. Saves for independent sessions may proceed concurrently; index updates use a lock or compare-and-retry strategy so entries are not lost.

## Migration contract

- Missing `schema_version` is legacy input. Parse only known legacy fields, normalize `refs` to `context_items`, sanitize tool argument JSON/UTF-8, and validate before writing version `1`.
- Version `1` loads directly after validation.
- Versions greater than the runtime-supported version return `runtime-upgrade-required`; no rewrite occurs.
- Invalid/corrupt files are isolated and reported with path/reason. Index rebuild skips them but does not delete them.
- Migration creates a backup or preserves the original until the new atomic write commits.
- Unsavable scratch identity is runtime state, not a path-traversal trick in the target schema.

## Trace and compaction durability

Trace event append, membership update and compaction archive changes participate in the session generation. A compaction commit records the archived range and replacement messages before the active session points to the new generation. Recovery chooses the last internally consistent generation and never combines a new session file with stale trace membership silently.
