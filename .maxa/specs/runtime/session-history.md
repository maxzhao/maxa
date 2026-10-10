---
title: Maxa AI Session History 与 UI 行为规格
created: 2026-06-28
updated: 2026-10-09
type: source
doc_role: spec
authority: accepted
status: active
capability: maxa-ai-session-history-ui
sources:
  - lua/maxa/session/history/
  - lua/maxa/session/display_chat_history/
  - lua/maxa/session/default_session_cache.lua
  - lua/maxa/session/llm_error_recovery.lua
  - lua/maxa/session/session_status.lua
  - lua/maxa/session/session_stats.lua
  - lua/maxa/session/session_trace.lua
  - lua/maxa/lifecycle/session_trace_lifecycle.lua
confidence: high
review:
  human: passed
  evidence: user-declared-change-review-2026-10-07
---

### Scope

Owns saved Chat lifecycle, project storage/index/UI, transfer, opt-in trace storage/membership/natural turns, default-session cache, recovery and status/stats. [Session compression](../abilities/base/session/session-compression.md) owns compression mutations; [Session tools](../abilities/base/session/session-tools.md) owns tools. Title/storage/cache/recovery failures SHALL warn and preserve usable Chat state; unresolvable event Chats cause no mutation.

### History lifecycle and storage

#### Requirement: Session history initializes canonical UI and events

`maxa.session` SHALL initialize storage, title generator, history UI, `:MaxaHistory`, canonical `MaxaAI*` autocmds and Chat keymaps. Saved/session operations SHALL use only canonical `session_*`/`_session_*` metadata, neither generating nor translating legacy vendor/`cc_history_*` fields.

#### Requirement: Saved Chats have stable identities

| Trigger | Contract |
| --- | --- |
| `MaxaAIChatCreated` | SHALL generate a filesystem-safe `save_id` for an id-less Chat; preserve restored id/title. |
| Relevant canonical request-finish, tools-finish or Chat-submit event with `auto_save=true` | SHALL save the current Chat. |
| Submit | MAY asynchronously generate/refresh title, updating buffer, `chat.opts.title`, refresh count, history and `MaxaAIChatTitleChanged` payload `{bufnr,save_id,cwd,title,previous_title}` without a full Chat object. |
| Clear | MAY delete old saved history only when configured; SHALL reset title and assign new identity. |

#### Requirement: History storage is project-scoped

A `.maxa` root discoverable from cwd or usable real buffers MUST select `<project>/.maxa/history`; otherwise use `stdpath("data") .. "/maxa-ai/history"`. Under that root, storage maintains bounded `index.json` metadata, `chats/<save_id>.json` bodies, `caches/` artifacts and opt-in `traces/` artifacts.

Index fields remain save id, title, updated time, adapter/model, message count/token estimate, cwd/project root and protected-prefix count. Missing/unreadable index initializes/returns empty bounded state with a diagnostic. Writes sanitize invalid UTF-8/malformed tool arguments; expiration cleanup still requires configured `expiration_days>0`. Related canonical UI/events/trace paths use the runtime/Vault naming mapping without changing transfer, ancestry or authorization semantics.

### Cross-project transfer

#### Requirement: Transfer is explicit and target-first

Copy/move of a saved Chat requires an explicit target action/tool and a target containing `.maxa/`; missing history/chats/index MAY be initialized. Each transfer SHALL generate a new target `save_id`, preserve message/settings/adapter/context structures, update target-owned `save_id`/`updated_at`/`cwd`/`project_root`, and add `{mode,source_project_root,source_history_dir,source_save_id,source_cwd,transferred_at}` provenance.

Copy leaves source unchanged. Move SHALL delete source file/index only after target file AND index succeed. Partial target index failure SHALL remove the new file where possible and report the stage. No added confirmation/redaction: explicit transfer may copy private project context.

#### Requirement: Transfer UI preserves project isolation

`:MaxaHistory` defaults to current-project chats. Picker MAY offer copy/move with valid local MRU roots and SHALL always permit manual target root. The runtime-local known-project registry SHALL store only normalized roots/timestamps in Neovim data storage—not chat bodies or `.maxa/` knowledge; missing/corrupt registry falls back to manual input.

#### Requirement: Cross-project transfer does not rebind Ability authorization

Copy/move/restore into a different effective workspace SHALL retain source Ability roots/instructions/catalogs/hooks/authorization as transcript evidence only. History SHALL NOT rewrite provenance, select target-project roots or authorize same-named target Abilities. Target dispatch/loaded completion requires a new successful `load(target="<ability>")`.

#### Requirement: Trace storage is not transferred implicitly

Transfer preserves additive metadata, including serialized `_meta.session_trace`, but SHALL NOT claim raw `.maxa/history/traces/**` was copied or complete lineage migrated. Without an explicit trace-transfer contract, cross-project continuation may have incomplete/split trace evidence; UI/tool results SHALL preserve that limit.

### History UI and lightweight display history

#### Requirement: Saved Chat UI restores exact session state

Restore canonical messages before applying the Ability restore gate below; history SHALL NOT switch the process-global MCPHub UI workspace.

#### Requirement: Saved Chats persist committed Ability state without implicit activation

Successful root `load` SHALL persist one committed revision containing normalized exact-workspace provenance, effective roots/metadata, instructions, catalog objects, hook identities and the most recent successful complete catalog-bearing tool-call/result association. Publish that association before tools-finished autosave; compression/history preserve it without duplicate visible catalog/manifest. Never serialize raw MCP configuration/environment, live handles or connections.

#### Requirement: History restore rehydrates Ability state without activation

**Restore gate**: only the new-format committed revision above, with valid exact-workspace provenance and its protected complete catalog-bearing result pair, SHALL rehydrate readiness. Missing/incomplete association requires explicit fresh `load`. Mentions, tool history, catalog metadata without its complete result and process-global Server state grant no authorization. Restore SHALL NOT replay `load`/`call`/`multicall`, duplicate catalogs, start backends, connect Servers or activate sources.

| Restored exact-workspace access | Result |
| --- | --- |
| Valid complete Ability state, allowed MCP tool | MAY call; if disconnected, connect and await success without new load/revision/duplicate catalog. Connection failure prevents execution. |
| Resource | Connected-only; no implicit reconnect. |
| `disabled=true` | Saved records remain evidence; loading/dispatch prohibited. |

Reconnect evidence: real restart/resume preserves revision/catalog and direct tool execution reconnects successfully. Automated `passed`; human implementation review `not-run` (frontmatter review retains the prior stable baseline).

#### Requirement: Legacy capability state is quarantined without rewriting storage

Pre-cut `skill:*`/`mcp:*` contexts, SkillHook injections, retired package-root context files and old loader calls remain transcript evidence but SHALL be excluded from active model capability context/readiness. Legacy once state is not translated; ordinary user messages and task/spec context are not keyword-filtered. Reconcile the current 17-builtin registry/prompt in memory, leaving saved files/messages unchanged.

Literal `@name`, `@ability:target`, `#ability:target` and historical mention text remains unchanged; never rescan it to load, call, read or authorize anything.

`display_chat_history` remains lightweight manual save/restore with its own data directory/retention. It MAY serialize role/content/options/simple context, adapter/settings/timestamp/cycle; failure/too-few-message cases SHALL NOT write partial data.

### Agent identity and hierarchical history

- **Persistent agent ancestry**: Before creation-time display decisions, saved metadata/compact index MUST preserve type and history parent/root relationships. Unknown legacy records remain independent; only reliable identity/trace evidence may classify children. Missing/cyclic parents MUST NOT hide records or cause unbounded traversal.
- **Dialogue-time ordering**: Record actual nonempty user submission/agent reply time independently of storage updates. Tree roots MUST sort by the main record's own dialogue time descending, falling back to legacy save time; freeze that fallback on legacy restore before subsequent saves. Child activity, rename and save-only events MUST NOT promote a main root.
- **Main-only sidebar navigation**: Sidebar `}{`, toggle and directly affected close/restore fallbacks MUST select eligible main Chats only. Headless child creation/child float focus MUST NOT replace last-main selection. Main history opens right (including already visible main windows), matching corrected default-side intent; child history floats without hiding the sidebar. Explicit handoff follows Prepared handoff main selection below.
- **Tree-first history picker**: History opens as a hierarchy. Snacks MUST support `h/l` collapse/expand and parent/child navigation, `Ctrl+L` tree/flat switching and child-search ancestor paths. Flat mode retains mixed-session save-time ordering; other configured picker selection APIs remain usable.
- **Concrete history actions**: Preview, rename, duplicate, stats, transfer and deletion MUST act on the selected record; parent selection/deletion MUST NOT implicitly act on descendants. Identity copying/reidentification MUST avoid inherited self/root IDs and tolerate cross-project missing ancestors without falsely linking unrelated local records.

Source/evidence: `lua/maxa/session/agent_identity.lua`, Chat/history owners (actual sidebar/picker/child/restart evidence). Do not bulk-reconstruct old indexes lacking identity/trace fields: records remain independent legacy entries until explicit restoration/saving supplies reliable metadata.

### Main-session handoff history

[SubAgent runtime](../abilities/base/subagent/subagent-runtime.md#main-session-handoff) owns authorization, main-only eligibility, inputs, acknowledgement and safe tool-batch transition.

- **Independent main handoff identity**: The successor MUST have an independent resumable `save_id`, persistent `_meta.agent.kind="main"`, self-owned root and no child parent/depth or live delegated binding. Old-parent close/cancel and child terminal cleanup MUST NOT stop it; restore retains main identity without old wait subscriptions. Clearing a parent pointer or changing the window alone is not promotion.
- **Target-first handoff history preservation**: Before closing the caller, runtime MUST confirm recoverable saving of successor transcript/identity AND index; save old history after its real handoff result settles. Failed confirmation MUST retain the old Chat and report a blocker. Closing does not delete history; records retain separate IDs without overwriting one another. Scheduled autosave is not save confirmation.
- **Prepared handoff main selection**: Preparation MUST preserve old main selection/window. Only the SubAgent owner's successful safe boundary may replace that selection with the independent new main in normal sidebar/navigation and route subsequent input to it. Failure MUST preserve old main with no executing orphan/replacement selection. New main stays open after its first final reply.

Handoff evidence: actual fresh-Neovim handoff retained both saved records, self-rooted main identity, right main sidebar selection and post-reply continuation. Required-file failure retained old main. Injected failure races remain unexercised.

### Trace lineage

#### Requirement: Trace activation is opt-in and root-stable

Only `/trace_start` enables tracking. Root trace id SHALL equal the root Chat's regular `save_id` and remain immutable across later compression/session replacement of active save id. Tracked Chats SHALL persist `_meta.session_trace`: root id, stable span id, parent span id, role, source event, started time, active state. Restore infers membership from saved metadata without requiring an open parent Chat.

#### Requirement: Trace storage is append-only and project-local

Each root SHALL store `.maxa/history/traces/<root_trace_id>/` containing `manifest.json` (schema version `1`: root identity/title/status/times/source), durable append-only `events.jsonl`, derived/rebuildable `index.json` and `archives/<event_id>.json`. Events SHALL carry schema/event/root/span/session/kind/time/dedupe metadata; dedupe keys SHALL prevent logical duplicate appends after retries/backfill. Parse/index failures MAY rebuild from JSONL. Unrecoverable missing temporary/deleted scratch content SHALL remain an explicit gap, never fabricated.

#### Requirement: Natural turns are captured for every tracked session

Tracked root/fork/scratch/subagent/resumed/promoted sessions SHALL record final user prompts, assistant replies and error/stopped outcomes as `main_turn.user_prompt|agent_reply|agent_error`, with session/span/message evidence. Stop without visible assistant output uses empty content plus status/reason. Ordinary tools/results, system/context, hidden messages, compact summaries and fragment-inserted messages SHALL NOT become natural-turn records solely from append.

#### Requirement: Session lineage survives branch/resume boundaries

Persistent fork and recoverable SubAgent Chats SHALL save membership; temporary scratch/child sessions MAY write directly without ordinary history save. In-place resume preserves the restored span; new-Chat resume creates a child span linked to restored source. Nested children retain root id. Duplicate final SubAgent content SHALL be referenced, not repeated.

Action events MAY include `fork.created`, `scratch.created|saved|merged`, `fragment.inserted`, `subagent.started|completed|error`, `ask_llm.completed`, `multi_agent.completed`, `compression.archive_created|applied`.

### Default-session cache

#### Requirement: Warmup applies only to safe default Chats

Session setup SHALL initialize cache/error recovery; Native MCP adapter load SHALL NOT own these side effects.

| Mode/condition | Warmup contract |
| --- | --- |
| Auto | Requires HTTP adapter, non-restored default Chat, default prefix, rules/tool-only context and exactly the current first-party builtin schema set. Non-default tools/context, restored/prompt-library states or no prefix SHALL skip with reason. |
| `disable` | Skips. |
| `force` | Still requires usable prefix/HTTP adapter. |

Warmup snapshot SHALL copy default prefix, remove old warmup records, append hidden warmup user content, map adapter roles/tools and persist versioned hash metadata. Model tool calls returned by warmup SHALL never execute.

### Error recovery and status

#### Requirement: Recovery classifies through adapter seams

Responses protocol failures SHALL use adapter `handlers.response.parse_error(self,data)`; session recovery SHALL NOT decode wire SSE/JSON. Supported empty/error outcomes MAY classify token limit, network, rate limit or invalid signature. Empty assistant after tool results without captured HTTP error SHALL NOT be labeled network failure solely for emptiness.

Token-limit automatic recovery SHALL delegate to the shared Session handoff compaction owner before active executor termination, only under an explicit runtime recovery signal/contract—not Agent-inferred compression permission. Source history remains recoverable and successor identity/configuration follow the verified transfer. Ended/ineligible delegated errors do not overwrite historical sessions. Unsupported adapters retain normal error handling.

#### Requirement: Status and stats are bounded

| Surface | Contract |
| --- | --- |
| Live status | MAY include save id/title/adapter/model, token used/limit/percent/source, message JSON bytes/count and updated time. |
| Public Agent/hook status | SHALL reduce to save id, token object, JSON bytes and count. |
| Stats | SHALL aggregate role/metadata/tag/tool call/result counts, bytes/tokens, success/error, TTL/discarded/oversized/duration/orphan/pending facts without expanding full history. |

#### Requirement: Current-project maxa naming migration

- **Recoverable original-data archival**: During this current-project rename, original old-name saved Chat history and matching temporary data MUST be inventoried and archived outside the repository without deletion. Preserve coherent history/cache index-file relationships, original IDs and original bytes; do not rewrite nested Git packs, SQLite or capability hashes/provenance. Keep active knowledge/tasks and nonmatching user data. Local execution records own the archive destination and recovery evidence; archives are not active project history or wiki knowledge.

- **Fresh-session naming cutover**: Final old transcript saving and archival MUST occur at a controlled writer-stop boundary before the new runtime starts saving. New continuation MUST use a fresh Chat with only sanitized task/progress context, without copying the old transcript or fabricating restored Ability readiness. Required Abilities are freshly loaded. No old autosave may recreate the prior Vault or old-brand text after final verification. Ordinary restart/history behavior outside this explicit migration remains unchanged.

### Validation

#### Evidence retained

Recorded storage/transfer/trace automation and representative runtime checks are `passed`; human specification review is `passed`. Retained coverage:

- Final-owner history/cache/recovery/status/trace aggregate tests passed; history UI restart-resume and picker had prior live evidence.
- Transfer storage/tool tests passed; copy/move had post-restart synthetic-project smoke and the user previously reported normal UI function.
- Trace storage/lifecycle/backfill/action/archive/query suites and live recorded/synthesized query smokes passed.
- 2026-09-22: Ability revision/catalog association, atomic autosave ordering, direct/wrapped/dependency catalog retention, provenance-valid restore, legacy quarantine, cross-project transfer invalidation and literal mention preservation passed focused automation, fresh restart-resume and live Ability dispatch; human acceptance passed.
- Restore-without-activation, authorized disconnected failure, same-workspace connected reuse and administrator-policy preservation passed focused session/transport automation and fresh-runtime probes.

#### Unrun/limited evidence

These scopes remain `not-run`:

- Full project-history storage matrix: no dedicated broad integration suite.
- Trace persistent-fork manual close/reopen, full child Agent loop and multi-agent live execution: helper/unit evidence only.
- Raw trace-directory cross-project transfer: neither implemented nor validated.

### Source trace

- History: `lua/maxa/session/history/`.
- Cache/recovery/status: `lua/maxa/session/default_session_cache.lua`, `llm_error_recovery.lua`, `session_status.lua`, `session_stats.lua`.
- Trace: `lua/maxa/session/session_trace.lua`, `lua/maxa/lifecycle/session_trace_lifecycle.lua`.
- Ability state/restore: `lua/maxa/session/abilities.lua`, `lua/maxa/session/compaction_messages.lua`, `lua/maxa/session/history/ui.lua`, `lua/maxa/session/history/init.lua`.
