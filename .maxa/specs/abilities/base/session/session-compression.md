---
title: Session Compression 行为规格
created: 2026-06-28
updated: 2026-10-14
type: source
doc_role: spec
authority: accepted
status: active
capability: session-compression
sources:
  - prompts/system.md
  - abilities/session/SYSTEM.md
  - abilities/session/SKILL.md
  - lua/maxa/session/
  - lua/maxa/session/slash_commands/compact_silent.lua
  - lua/maxa/session/slash_commands/collapse.lua
  - lua/maxa/session/handoff_compaction.lua
  - lua/maxa/session/tools/handoff_compact.lua
  - lua/maxa/session/compaction_messages.lua
  - lua/maxa/session/history_session.lua
  - lua/maxa/session/tools/
  - lua/maxa/mcphub/native_servers/session/init.lua
confidence: high
review:
  human: passed
  evidence: user-declared-change-review-2026-10-07
---

### Authority and scope

Stable compression owner; `prompts/system.md` Token Management Protocol, `session` always-on rules and current schemas take precedence. [Session tools](./session-tools.md) owns query/probe semantics. Logic: `lua/maxa/session/`; Native adapter: `lua/maxa/mcphub/native_servers/session/`; tool prefix: `session__`; metadata: canonical `session_*`/`_session_*` only.

Failures SHALL preserve original Chat/history where possible and report exact stage/residual risk. `No current session found`: use explicit save id or active-Chat invocation, never guess a session. Failed marker lookup: correct marker/role/occurrence, never guess a range.

### Authorization

#### Requirement: Agent must not self-authorize compression

Only an explicit current-conversation signal authorizes compression: system/runtime reports the token-risk threshold reached and recommends/requires it; system/runtime directs it now; or user requests it. Judge message role and explicit meaning, not bracketed/system-like formatting. One signal permits at most one operation; later operations need new signals.

Agent SHALL NOT self-authorize from its judgments/estimates of context length, token usage, message count, task stage/completion, elapsed work, tool-output volume, future work, SubAgent `context_status`, TTL expiry or silent reminders. Runtime-owned automatic recovery/threshold behavior MAY compress only through its accepted contract's explicit current-session signal or authorized user choice, never Agent inference.

#### Requirement: Ordinary authorization requests configured handoff

Current-session Agent compaction SHALL call `session__compact_self(instructions=...)` directly, without `mode` or first loading `session`, server docs or explanatory modules solely to compress. Explicit single-use authorization covers the shared configured handoff workflow and its one necessary type-preserving internal transfer, not later handoffs. Empty planner output/tool failure SHALL fail without another algorithm or operation absent separate authorization. `/collapse` is an explicit user slash command, not a self-compression mode.

#### Requirement: Exact range compression has a stronger gate

Current-session `session__compact_range` requires explicit user/system direction, an exact located range and `session` guidance, not proactive Agent planning. Actions: `summarize|delete`. Ranges SHALL be 1-based, ascending, non-overlapping and preserve system/protected messages. Repair invalid/overlapping/unordered indices only under still-applicable authorization; a second independent operation needs a new signal.

### Self compression

#### Requirement: `compact_self` requires instructions only

`compact_self` requires recoverable task state and preservation `instructions`, not `mode`. It requests the shared configuration-selected handoff workflow after the current response. Legacy extra mode fields do not select another route. The dedicated executor may read/write necessary materials, load required guidance and invoke source queries/handoff_compact; arbitrary run commands, delegation and legacy compaction tools are not permitted.

#### Requirement: Compression preserves current task continuity

Instructions SHALL preserve current user request/goal, constraints/rules, loaded task context, plan, changed files, errors, key decisions, validation state, next steps and pending LLM-first Artifact Protocol; safety warnings, approvals, exact identifiers/commands/paths/schema fields and unresolved blockers SHALL remain unambiguous. On resume, Agent SHALL check critical continuity and reload only missing context; avoid large reads/logs/replies while token risk remains high.

#### Requirement: Planning request preserves the parent prefix

Independent precise/history tools retain their existing prefix behavior. Shared command/self/automatic planning uses a dedicated compression executor and configured compact adapter; the successor retains source business adapter/model/settings. Planning may use truncated inherited data with original-message reads when needed; it SHALL NOT claim exact parent-input/cache-key/schema prefix equality or provider cache hits. A new successor contains foundational rules, necessary context, selected originals and handoff/summary, not the entire old input.

#### Requirement: Final persistence cleans control artifacts

Probe and index copying SHALL use the same saved source view with runtime-control/token-warning filtering, never index a different raw storage list. The successor SHALL retain source business configuration, rebuild the foundational protected prefix and restore necessary contexts/tools without compression-adapter pollution. Source history remains recoverable; transient executor selection/planning messages do not become successor task requests.

### Handoff compression

#### Requirement: Handoff compression preserves selected source history

New commands and self/active automatic recovery share: safely pause/save source → LLM prepares recoverable handoff → semantic segmentation calibrated by probe → user-role profile selection → same LLM summarizes useful omitted information → original records copied by index → verified transfer. Preparation includes request/goal, scope/permissions, rules, decisions, changed paths, errors/blockers, actual validation and next action; material may be files or concise text.

`/compact_rescue` displays one interval/brief-content/tier table and waits for a user message. `/compact_silent`, self and automatic paths insert a configuration-generated selection after segmentation and before omission review. `maxa.compaction.profile` defaults to `balanced`; invalid values fail without implicit fallback. Slash completion preserves the user's pre-command instructions.

| Segment tier | conservative | balanced | aggressive |
| --- | --- | --- | --- |
| conservative / 保守 | copy | omit | omit |
| balanced / 平衡 | copy | copy | omit |
| aggressive / 激进 | copy | copy | copy |
| delete / 删除 | omit | omit | omit |

One ordered, non-overlapping source partition suffices; no fixed segment count, separate three-plan registry, scoring or size target. All omitted tiers, including delete, are reviewed after selection: useful facts are summarized by that executor into handoff/summary files or concise text, otherwise omitted. No separate summary-model/legacy compact call is made. Updated file references SHALL be read at application, not stale preparation content. Delete means no original in the successor, not removal of old history or prohibition of useful summaries.

`handoff_compact` prepare/plan/apply is restricted to an active workspace and exact source save_id. Segment params contain indices/brief labels, never historical bodies. Application SHALL preserve selected records' roles/content/metadata/order, reject split tool pairs/Ability catalog records rather than silently drop/expand selected tiers, and avoid copying old system/rules over fresh foundation. Fresh preloads use normal authorization; copied schemas alone grant none. Failed/cancelled tool batches cannot apply.

Transfer reuses the internal main/same-parent-child handoff boundary; no dual submit, premature source close, budget reset or promotion. Cancellation during source pause stops runner/target and settles the original delegated call. Temporary/unsavable or dedicated controllers retain eligibility limits. Failure retains stopped source/history and reports stage; successful successor alone continues.

The old slash mini-loop/rescue algorithms and `compact_handoff` / `compact_handoff_silent` names are retired without aliases. `compact_range`, `compact_full`, `collapse_tail` and their shared helpers retain independent semantics, not automatic routing. Status-panel structural retention categories belong to explicit tools and SHALL NOT be presented as a prediction of handoff tier selection.

### Incremental slash collapse

#### Requirement: `/collapse` summarizes the incremental tail in a fork

On explicit `/collapse`, an idle persistent main Chat SHALL save source and a complete fork, then close source before summary work. In the fork, reverse-search the last `_meta.tag == "collapse_summary"`; start at its following message and freeze the current tail endpoint. Without that marker, start after the protected foundational system/rules prefix AND its immediately following complete tagged cache warmup segment (`default_session_cache_warmup`, `default_session_cache_warmup_response`, `default_session_cache_warmup_tool_result`). Keep that prefix's content, roles, metadata and order unchanged in place; never move warmup records after the summary or rewrite prefix indices. Empty tail is a no-op. Preserve earlier messages and necessary system/context/complete tool/catalog records; summarize remaining facts in chronological order, including actual tool results and constraints. Replace the tail with one assistant `collapse_summary` carrying range metadata and retained original records, save/render with editable input and no business auto-submit. Summary failure retains complete fork originals and old history. This command uses no profile selection or handoff planner; precise/history tools remain independent.

#### Requirement: `/collapse` displays buffer-only pending feedback

During asynchronous summary, the fork Chat SHALL visibly show `⏳ 正在摘要...` in its buffer and block editing/submission. Feedback SHALL NOT enter canonical messages, LLM input or saved history. Success/error/cancellation/close clear pending state and restore editable input when Chat remains open; a cancelled/closed operation SHALL ignore later summary completion. Existing collapse boundaries and retained prefix remain unchanged.

### Precise collapse and destructive tools

#### Requirement: Protected prefix is immutable

`compact_protected_prefix_count` identifies foundational initial messages. Overlapping collapse/ranges SHALL reject/report; callers repair the range rather than compress that prefix.

#### Requirement: `collapse_tail` follows probe and candidate scan

Direct precise collapse SHALL locate the boundary with probe/search, then run `session__scan_collapse_candidates`, then call `session__collapse_tail` with `save_id`, `collapse_start_index`, `summary_text` and strictly increasing `preserve_indices`. Scan returns structured facts, not full content.

#### Requirement: `compact_full` is historical-session only by default

`session__compact_full(save_id=...)` MAY compress explicitly targeted non-current saved sessions according to mode options, but SHALL NOT serve ordinary active-session compression. Current sessions use authorized `compact_self`/collapse/range or the runtime-owned rescue path.

### Token-threshold branch

#### Requirement: Only explicit `compact` choice authorizes threshold compression

In the 95% Telegram flow, only authorized `compact` from the ordinary initial or final SubAgent decision SHALL call shared handoff compaction once after safe stop. Compact installs no finish instruction/eight-round budget.

- Success commits/submits the successor only; the retired source is never resubmitted.
- Load/start/completion failure SHALL re-latch manually resumable stop, submit no provider request and report bounded local error.

`finish`, ordinary eight-request exhaustion, normal 300-second expiry and `interrupt` SHALL NOT compress. Exhausted ordinary finish interrupts directly without offering/inferring compression; primary/emergency finish instructions prohibit Agent-initiated compression and grant no authorization.

### Trace archives

#### Requirement: Tracked ranges archive turns before replacement

Before `compact_range`, `collapse_tail` or `/collapse` replaces a tracked range, runtime SHALL extract only user prompt, final assistant reply and assistant error/stopped records, write `.maxa/history/traces/<root_trace_id>/archives/<event_id>.json`, then append `compression.archive_created`. Successful mutation appends `compression.applied` with applicable action/mode/range/stats/old-new ids.

Archives SHALL exclude arbitrary tools/results, system/hidden/context and full raw ranges; their key SHALL dedupe the same span/range/content across retries. Root trace id stays immutable. Archives are queryable, not injected into normal compressed context by default.

### Validation

#### Incremental collapse and instructions-only self

Expected acceptance: the live compact_self catalog exposes required `instructions` only; configured completion routing remains unchanged. Actual registered `/collapse` SHALL close the saved source, preserve the fork prefix including complete tagged warmup content/metadata in their positions, save a tagged assistant summary and leave editable input without an automatic task request. A repeated operation SHALL start after the previous summary and retain the calling Chat's prefix and that summary verbatim; required Ability context/catalog and complete tool pairs remain ready.

Focused tool/recovery/helper checks and fresh-Neovim catalog/registered-command observations passed for initial and repeated collapse with a real compact-adapter summary and loaded Session context. A subsequent fresh-runtime warmup correction verified complete prefix/metadata equality on each calling Chat and saved result, first summary after warmup and repeated summary boundary; earlier foundation-only observation did not cover warmup retention. Human implementation review not-run. Storage/render failure races and provider-generated warmup tool-result variants were not induced; existing failure guards are not a claim of live fault coverage.

Actual fresh-runtime registered `/collapse` showed the buffer-only placeholder and locked input while pending, removed it on success and explicit Chat stop, and restored editable input with no placeholder in saved history. Existing helper checks passed; transport-error and close-race injection were not performed.

#### Evidence retained

Recorded automated compression/prefix/archive coverage: `passed`.

- Final-owner aggregate history/cache/compression/trace suites passed; restart-resume exposed current `session__*` surface and representative status call.
- Prefix tests verified inherited cache key/instructions/input/tool schemas and final cleanup; archive tests covered compact range/collapse tail dedupe/queryability.
- Focused automated threshold routing covered ordinary initial explicit compact and exhausted ordinary finish without compact.
- Human specification review: `passed`, including the 2026-09-22 ordinary threshold compact authorization boundary.

#### Handoff-flow evidence

Fresh-Neovim actual configured and interactive commands passed preparation, one tier table, selection-after-plan, LLM omission review, saved successor and old-history retention. Actual compact_self collapse/destructive returned through the same original parent tool with sibling identity; ordinary threshold UI compact selection, public child handoff compatibility and outer cancellation during preparation passed. Existing self/threshold/legacy-command/executor/soft-stop checks and representative pure interval/pair inputs passed. Human implementation review not-run. Real provider context-limit faults and injected storage/window failure races were not induced; earlier cache evidence applies only to legacy behavior, not new successor prefix equality.

The final silent/rescue command names were verified after a fresh Neovim reload: rescue showed the segment table and waited before a user balanced selection; silent completed with the configured profile without user selection. Pre-command preservation instructions reached the executor. Retained shared-truncation/range/executor and authorization-doc checks passed; legacy-only tests/prompts were removed with the retired implementation. Earlier legacy-command evidence is historical, not current availability.

#### Unrun/limited evidence

Provider-reported prompt-cache hits were not established (request-prefix compatibility only); full live threshold compact continuation/failure recovery matrix remains incomplete. These gaps remain `not-run` or `partial`.

### Source trace

Frontmatter sources map to authority (system prompt and Session Ability), planner/apply (`compact_silent.lua`), range/protection (`compaction_messages.lua`, `tools/`) and persistence (`history_session.lua`).
