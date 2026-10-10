---
title: Maxa Chat Builtins 稳定规格
created: 2026-06-28
updated: 2026-10-13
type: source
doc_role: spec
authority: stable
status: stable
capability: maxa-chat-builtins
validation:
  specification: passed
  automated: passed
  live: passed
  human: passed
sources:
  - prompts/system.md
  - lua/maxa/interactions/chat/tools/builtin/init.lua
  - lua/maxa/interactions/chat/tools/builtin/tools/
  - lua/maxa/interactions/chat/tools/builtin/runtime/
  - lua/maxa/session/abilities.lua
  - lua/maxa/mcphub/project_transport.lua
  - lua/maxa/session/builtin_registry.lua
confidence: high
---

# Maxa Chat Builtins

## Purpose And Ownership

Single detailed owner of first-party Chat tool identity, registration, invocation/dispatch, async/TTL results and file/command/context boundaries. Normative clauses define observable acceptance; their imperatives express SHALL obligations, while explicit MAY/SHOULD retain their strength. Dated evidence below retains its original scope.

| Source owner | Responsibility |
| --- | --- |
| `lua/maxa/interactions/chat/tools/builtin/init.lua` | Ordered inventory, public-name/private-module mapping, resolution, schema/config registration. |
| `lua/maxa/interactions/chat/tools/builtin/tools/` (`tools/builtin/tools/`) | Public schemas and tool-local behavior. |
| `lua/maxa/interactions/chat/tools/builtin/runtime/` (`tools/builtin/runtime/`) | Exact invocation context, nested dispatch, output normalization, async/cancel/TTL, injection, ask coordination, image-analysis integration. |
| `lua/maxa/session/abilities.lua` | Exact-Chat committed revisions, workspace provenance, complete catalog associations and authorization. |
| `lua/maxa/mcphub/project_transport.lua` | Explicit-cwd project-keyed MCP connections/transport. |
| `lua/maxa/session/builtin_registry.lua` | Current-inventory reconciliation on restore/resume without transcript rewriting. |
| `lua/maxa/interactions/chat/tools/validator.lua`, `lua/maxa/interactions/chat/tools/init.lua`, `lua/maxa/interactions/chat/tools/orchestrator.lua`, `lua/maxa/interactions/chat/init.lua` | Canonical call validation, history and execution. |
| `lua/maxa/lifecycle/tool_calls_completed_event.lua` | Tool lifecycle evidence. |
| `prompts/system.md` | Runtime rules. |

[Image Analysis](./image-analysis.md) alone owns decoding/crop/resize, hidden-child isolation, request accounting, final-text completion and cleanup. [MCPHub Runtime](./mcphub-runtime.md) owns native/external inventory and project transport.

## Registry And Invocation

### Requirement: Canonical first-party builtin inventory

Every normal Chat SHALL expose exactly 17 bare first-party names once each, in this order: analyze, ask, multirun, multicall, kill, delete, edit, run, fire, wait, keep, load, move, read, write, search, glob. Availability requires no MCP server, group marker, dynamic registration or MCPHub readiness. `load` alone owns first-party capability/context loading; reporting and fuzzy capability-search terminal tools are excluded.

### Requirement: Removed identities have no compatibility path

`call` and legacy multicall(calls/async) are retired without alias, parameter translation or old-history execution; current multicall declaration/runs is distinct. `cancel`, `invalid_call`, `load_skill`, `load_server`, `load_context`, `winrun` and `lua` remain unavailable; unknown direct/nested identities fail normally. Removed loaders/winrun have no schema, callback, nested target, prompt entry or alias. Removed identities are Git provenance only.

Restore, compression-created Chats and SubAgent resume SHALL install the current 17 schemas under existing registry policy without changing persisted files/messages or using an old-schema provider cache. Historical calls remain displayable and semantically parseable for load/read association, deduplication, TTL and statistics, never executable or translated into new calls.

### Requirement: Builtins use the Chat callback lifecycle

Each builtin SHALL provide a Chat function schema and `(tools, args, input, output_handler)` callback. Synchronous/asynchronous completion MAY be used, with at most one terminal success/error. Do not reconstruct a Native MCP request/response compatibility layer.

### Requirement: Invocation context is exact and Chat-owned

Context SHALL come from the invoking Chat and prepared call: available buffer, project cwd, persistent session/tool-call identities, tool name, arguments and callback. Missing required identity SHALL fail caller-sensitive operations; never substitute another Chat, current editor buffer, last-used Chat or global mutable caller. Concurrent Chats must not consume one another's injection, lifecycle, environment, event, image-analysis or cancellation state.

### Requirement: Shared raw argument validation

Before execution, one bounded validator MUST recursively check raw type/null/object/array distinctions, required, additionalProperties, enum/const, array/string/numeric bounds, uniqueItems, anyOf/oneOf/allOf/not and resolvable local refs. Pattern uses the supported common ECMA subset, not Lua patterns. Unsupported regex/assertion/ref MUST cause a schema error, not acceptance or remote fetch; annotations are not assertions.

Validation MUST NOT coerce/mutate arguments, defaults or canonical identity. Errors identify parameter path/keyword and preserve bounded rejection/replayability. Title inheritance uses copied execution parameters; multicall's explicit history transformation belongs only to its expansion owner.

### Requirement: Nullable fields are optional

Source-owned nullable properties, including nested ones, MUST be optional, not required. Accept null only where declared and retain handler defaults; non-null required fields remain mandatory. Do not weaken external MCP required/null contracts through local normalization.

### Requirement: Optional builtin preparation precedes interception

Definitions MAY expose synchronous `prepare(context) -> params, error`: side-effect-free parse/default/validate preserving raw args/exact caller. Run/member preparation shares title and args/opts parsing; trusted script argv is internal and business fields remain backend-owned. Tools without prepare retain behavior.

### Requirement: Validation and preparation sequence

Shared direct/member invocation, including multirun members and tool-mode builtin targets, MUST perform raw validation, exactly one prepare if present, returned-table installation on copied context, then prepared-parameter extension/handler dispatch. Exceptions, invalid hooks/results and explicit prepare errors stop execution. A batch prepared-member exemption covers that run member only, never its inner target; member-title and trusted-argv exemptions are internal. No-prepare tools still validate. Ready MCP inputSchema validates decoded args before transport, without changing authorization/business guards.

### Requirement: Invalid model calls are rejected without a fake tool

`invalid_call` SHALL NOT exist as a builtin, schema, callback, resolver/nested target, output-policy identity, compact executor special case or prompt entry. Before resolution/execution, Chat SHALL classify each adapter-produced canonical call without renaming/replacing its identity, arguments, order or provider-required metadata/signature, and without invoking rejected handlers:

| Classification | Required history/result |
| --- | --- |
| Valid | Execute under ordinary dispatch. |
| Rejected, legally replayable unchanged by current adapter | Retain canonical assistant call; append exactly one paired error containing `Status: rejected_before_execution`, reason, bounded parameter evidence, correction guidance and `The tool was not executed`. Anthropic Messages uses `tool_result.is_error=true`; adapters lacking a common error flag use the same fixed text in their existing wire. |
| Rejected, unreplayable | Omit from structured assistant history; append one `visible=false` user correction after all structured batch results. Multiple corrections keep relative order; omit empty call-only assistant messages. No placeholder name, synthetic replacement identity or forged result. |

Valid/replayably rejected calls SHALL complete in canonical order. Resolver failures become paired errors without skipping later valid/rejected calls. All feedback precedes the single existing `ToolsFinished`, `ToolCallsCompleted` and auto-submit boundary.

### Requirement: Invalid-call evidence is structurally useful and bounded

Decoded diagnostic snapshots SHALL preserve deterministic field names, container types, nesting and array order: each scalar text excerpt ≤250 Unicode characters, whole snapshot including truncation markers ≤1000. For undecodable args, parse reason, received character count, raw prefix and truncation marker together SHALL fit 1000; never guess missing structure or unknown intended/original length. Replace invalid UTF-8 with bounded valid diagnostic text.

Use the same snapshot for model correction and `ToolCallError.params`; rejected `ToolCallsCompleted` MUST NOT restore full large args. For incomplete JSON/missing tail fields, present token-limit truncation as the likely cause, not a proven cause for every validation failure.

## Execution And Authorization

### Requirement: Unified execution fields

Standalone run MUST require nonblank `title:string`/`command:string`; optional fields: `scope:string|null`, `args:string|string[]|null`, `cwd:string|null`, `timeout:number|null`, `opts:string|null`. Omitted/null/empty `scope` means shell; win means Windows; tool is reserved dispatch; other scopes use loaded Ability extensions. The table defines `opts` per scope.

| Scope/target | args | opts | cwd/timeout |
| --- | --- | --- | --- |
| shell | Absent/null: configured Shell string; array: literal string[] including []/empty values | Only boolean/null pty/async, default false | Exact Chat cwd; 300-second default |
| win | Absent/null: cmd.exe string; array: native string[] | Only boolean/null async/detach, not both true | Windows cwd and monitored/detached deadlines below |
| tool → builtin/MCP | Absent/null: {}; otherwise encoded JSON object string, never direct object/array/scalar | Only boolean/null async, default false, not forwarded | Non-null outer cwd/timeout rejected; absent/null retains internal exact Chat cwd; business fields in target args |
| tool → Ability script | Absent/null: no args; literal string[] or encoded object containing only `args:string[]` | Same tool options | Same outer rejection; original Chat cwd/executor/deadline |
| Ability extension | Original array/object-string parsing | Extension-owned object-string options | Original prepared contract |

No public tool/params/top-level async/json_patches/replacement-injection fields. Wrapper json_patches MUST fail even when null, before execution; native business fields and Artifact construction/patch/commit remain unchanged.

### Requirement: Tool-scope boundary

Tool mode MUST bypass extensions, never fall back to Shell, implicitly load an Ability or grant authorization. Title/forbidden-target/hidden-child guards precede authorized dispatch; caller parameters cannot forge title/async exemptions. Non-tool scopes remain extension-first; authorized disconnected MCP execution reconnects under the next rule.

### Requirement: `run` and `multirun` execute Ability targets

`run(scope="tool").command` and equivalent members SHALL accept only canonical bare builtins, exposed `@ability:/path` scripts or `@ability:tool` MCP tools; other namespaces including `<server>__<tool>` fail. Ability execution requires ready committed exact-Chat/workspace revision, protected complete catalog association, membership and current policy, never another Chat's authorization.

Resolution/preflight is side-effect-free. After parameter validation, an authorized disconnected MCP tool SHALL connect and await success; failure executes nothing. Reconnection commits no revision, injects no catalog/context, registers no hooks and fires no `AbilityLoaded`. After waiting, recheck authorization/policy/parameters and reject cancelled/closed Chat calls.

Scripts use the literal args forms above and preserve owning uv project/executor, exact cwd, isolated process group, timeout/output/cancel and structured event forwarding. Current-Neovim operations remain explicit `lua`. MCP retains live schema/handler semantics, explicit-cwd transport, exact caller, wrapped metadata, normalized output/images/resources and bounded errors. Transport may be shared; authorization may not. Wrapper JSON-file injection is absent.

### Requirement: Forbidden execution targets

Tool-mode run and multirun members MUST reject run/multirun/multicall structural direct or indirect targets, not same-named command programs or Shell text. Normal internal batch member invocation is allowed; other guards remain. Multicall rejects nested declarations and interactive targets before member effects.

### Requirement: Batch member titles

Ordinary run fields apply to members. Supplied title MUST be nonblank; omitted/null is allowed and normally SHOULD be omitted. Outer title is mandatory; trusted preparation fills omitted/null member title from it on copied execution parameters. No label, uniqueness constraint or generated title; results retain input order. Display uses original args, separately from this execution inheritance.

### Requirement: Nested builtin display-title inheritance

All first-party builtin `title` fields MUST be display-only. Direct calls retain declared title requirements. For tool-mode dispatch to a builtin declaring title in both properties and required, omitted/null target title MUST inherit effective run title before target validation/prepare: explicit target > explicit member > outer title. Empty/blank/wrong-type explicit titles stay unchanged and fail normally. No-title/optional-title schemas receive no injected title. Preserve raw args/persisted calls; never inherit into MCP schema/parameters/defaults or script argv.

### Requirement: `run` is cwd-, timeout-, and output-bound

Apply **Unified execution fields**. Source schema MUST require title/command; strict normalization makes source-optional wire fields required/nullable without open-object exceptions.

Command/extension cwd defaults to exact Chat cwd, resolves relative paths there, rejects blank values and never prefixes Windows absolute paths with Linux roots. Timeout MUST be finite or absent/null; Shell/monitored Windows defaults to 300 seconds, nonpositive disables deadlines, detach bounds launch only.

Preparation MUST decode string args/opts as JSON objects; reject malformed/empty/scalar/array/null encodings and direct objects while preserving nested distinctions. Literal string[] including []/empty values is allowed only for supporting scopes. Unknown scopes without an extension match MUST error, not execute Shell; matching/execution errors never fall back and business validation remains backend-owned.

The Shell backend MUST interpret `command` through the configured Shell for absent/null args, or execute `[command,...args]` literally without expansion for arrays, preserving empty values; reject object args and non-directory/inaccessible cwd. Unknown Shell opts fail even if null. Top-level `pty`/`async` remain schema-excluded but Shell-handler-compatible: non-null opts take precedence, null means omission; other scopes do not inherit them. Trusted internal scripts retain command-less argv/executor/cwd and bypass interception; Windows must not redirect them.

Run MUST execute non-interactively through backend-owned isolated job/process control, inherit target-side environment and retain Shell PTY/shared async/cancel. Output rules:

| Outcome | Required projection |
| --- | --- |
| Foreground success, empty stderr | Raw stdout; if both streams empty, concise explicit success. |
| Nonempty stderr | Keep it distinguishable. |
| Nonzero exit/timeout | Preserve available streams, status, exit/timeout info and necessary cwd diagnostics; omit repeated full command and routine empty-stream fields. |
| Windows detach | Launch acknowledgement, never application completion. |
| Overflow | **Oversized output is bounded**; native target results are not command-formatted. |

Exact persistent Chat identity MUST set child project-root/save-id environment values; incomplete identity clears both to prevent leakage. Never interpolate identity into commands or echo it automatically. Follow Justfile/command safety; descriptions state built-in Shell/Windows conventions without concrete extension dependencies.

### Requirement: `lua` preserves explicit execution mode

Every new `lua` call SHALL require concise nonblank display-only `title` and `code`. Direct/nested validation rejects missing/blank title before execution. Code runs in current Neovim through `nvim_exec2`; title changes neither execution nor output bounds/errors/content. Pending/completed/restored display is `lua "<title>"`; historical untitled calls remain bare `lua`, not executable or rewritten. Short output/no-output success marker remain unchanged; overflow follows the shared bound.

### Windows execution

The named clauses below govern the Windows backend; shared run identity/output rules still apply.

- **Windows execution selection**: Unless extension-first dispatch owns `scope="win"`, use the bridge. Absent/null `args` sends full `command` to Windows `COMSPEC` (system cmd.exe if absent), not WSL Shell/implicit PowerShell; array args executes `[command,...args]` natively without another Shell. Reject object args, unavailable bridge or unsupported parameters; no Linux fallback.
- **Windows literal argv boundaries**: Foreground/async/detach MUST preserve array order/values with standard Windows command-line serialization, including `[]`, empty args, spaces, quotes, trailing backslashes, Unicode, metacharacters and target args named like bridge options. Consume the bridge's own `--`; never reparse following argv, join/re-split it or interpret missing executables as PowerShell. OS-unrepresentable args error; target-interpreter code parsing is outside the transport guarantee. `.cmd/.bat` requires an explicit Shell/interpreter, not implicit literal-mode Shell entry. Do not auto-convert WSL path values in `command`/`args`.
- **Windows working directory**: Omitted/null `cwd` MUST use exact Chat project cwd; resolve relatives there, recognize drive paths with either slash and UNC, convert WSL cwd for Windows and reject invalid/inaccessible directories. Native argv supports accessible UNC; cmd-string MUST reject UNC before execution, suggest native argv/drive directory and never fall back to `C:\Windows`.
- **Windows scope options**: Only boolean/null `async`/`detach`, omitted/null false. Unknown keys including `pty`/`start_process` error even if null; reject wrong types and simultaneous `async=true`/`detach=true` before execution. No PTY, new top-level fields or other-scope option changes.
- **Windows monitored execution**: Default/async MUST monitor actual children, capture available stdout/stderr and inherit the Windows service environment with run's exact caller set-or-clear identity contract. `timeout` defaults 300 seconds; nonpositive disables, positive starts at actual launch. Timeout/cancel terminates the owned Windows process tree. Direct/multirun command members use shared cancellation; async reuses session registry and `wait`/`kill` latch, not another lifecycle. Distinguish timeout/cancel/failure and send final exit only after output drains.
- **Windows detached native launch**: `detach=true` MUST use the same argv/cmd-string path and return actual launch status/remote process identity, not `async_id` or completion claims. No output capture, unconsumed queue or waiting for application completion. GUI launches natively through the service in the existing interactive desktop session: no GUI argv reconstruction, `Start-Process -ArgumentList` or `start_process`. The app survives the ended call independently; launch/acknowledgement timeout never terminates it after acknowledgement.

## Batch Execution

### Requirement: `multirun` preserves bounded batch execution

Require nonblank title and 1–16 ordinary run objects with command required; **Batch member titles** governs title. Label, even null, is invalid; historical labels remain readable without restoring the interface.

### Requirement: Batch scheduling modes

| Mode | Required scheduling |
| --- | --- |
| Omitted/null or parallel | Independent members; concurrency default 4, range 1–8. |
| sequence | Wait for actual preceding completion, ignore valid max_concurrency, collect failures and continue. Fixed order adds no result references, dynamic args, DAG or retries. |

Authorization is rechecked at execution. Load's catalog/context commits after the outer batch result; sequence MUST NOT use a pending same-batch load as authorization. Load separately first.

Both modes MUST return input-ordered `{ok,results}`, members `{tool,ok,duration_ms,result|error}`, without labels. Tool scope names the actual target; command/extensions name run. Preserve native results. Payload ok reflects all members, distinct from transport/async completion. Structural errors, async conflicts and forbidden targets reject before dispatch; execution errors are member results. Cancellation stops unstarted work; late callbacks cannot overwrite terminal state.

### Requirement: Single batch async lifecycle

Outer async is boolean/null. Consume member opts.async in batch strategy, not forwarding or submitting independently; target args.async does not select batch async. Both sync/async use actual-completion scheduling; Windows detach/native submission remains acknowledgement, not external background completion.

| Outer async | Any effective member opts.async=true | Result |
| --- | --- | --- |
| absent/null | no | Synchronous results |
| absent/null | yes | One batch async_id |
| true | either | One batch async_id |
| false | no | Synchronous results |
| false | yes | Pre-dispatch error; no members execute |

## Experimental multicall

- **Native batch declaration**: A completed model response MAY contain one multicall with runs, or multicall first/unique followed by 1–16 registered builtin calls with runs omitted. Single-call invocation requires runs. Mixed runs/siblings, empty/misplaced/duplicate declarations MUST reject before effects. Without declaration, ordinary batching remains; multirun is unchanged.
- **Declaration parameters**: Nonblank title required; optional runs uses exactly multirun's 1–16 scope/command/args/opts/cwd/timeout/title schema, command required, title optional/null. Mode parallel|sequence defaults parallel; max_concurrency integer1..8 defaults4, parallel-only. Sequence-only on_error stop|continue defaults stop; explicit parallel on_error fails. No batch async or legacy calls. Native siblings keep required fields; runs keep execution-title inheritance and original-argument display.
- **Atomic preflight**: Before effects, validate declaration/all members for schema, preparation, availability and exact authorization. Reject interactive targets including ask, nested multicall/multirun and non-model/nested declaration invocation. Runs keep run scope/target boundaries, not new authorization. Hidden image children cannot acquire multicall or wrapper/budget bypass. Missing original replay identity follows existing corrections; generated member IDs require a valid declaration.
- **Bounded scheduling and paired results**: Parallel schedules independent members within active-invocation bounds without cancelling unrelated failures; sequence waits for preceding invocation return in member order. Each native/expanded call MUST receive one separate full correlated result, including failure/not-executed/cancelled. Continue model only after declaration/members settle; no fictional success or nested result aggregation.
- **Runs expansion history**: Full preflight success stages distinct provider-compatible runtime-authored IDs before outputs. Synchronous tool-scope first-party targets become actual builtin calls with decoded/inherited args; command/Windows/extension/Ability/script/wrapper-async remain run. At closure, commit original declaration with runs omitted, then ordered expanded calls paired with real results, preserving declaration ID/provider metadata and expansion provenance before continuation. Failure retains original request/error with no expansion; native siblings are unchanged. Signed history without validated adapter expansion support rejects before effects; never fabricate/copy signatures. Restore/replay is readable without re-execution, never described as model-generated native calls.
- **Sequence error strategy**: Continue preserves actual failure and proceeds. Stop preserves first failure, never invokes later handlers and pairs each skipped call with NOT_EXECUTED_SEQUENCE_STOP naming earlier failed index/name and policy; count them not-executed, not executed failures. Preflight rejection is policy-independent.
- **Independent member async**: Multicall owns no async_id. Member submission/result/ID/wait/kill are independent; submission completes invocation/frees slot. Later background failure cannot stop an already closed sequence. Counts are invocation outcomes, not business/background success.
- **Batch closure result**: Only status/effective mode, applicable on_error, member/succeeded/failed/not-executed counts and first-failed index for stopped sequence. Full bodies/errors stay in separate results; parallel history order implies no completion order.
- **Multirun-identical Tool Display**: Reuse multirun's exact layout/style/interactions under **Tool-owned display interface**, **Tool Display window lifecycle**, **Title-owned execution display**: outer title/fold, ordered independent target views/roles/nested folds/right decoration, status/progress/icons/duration/bytes/TTL, running-open/all-terminal-collapse/final/restored behavior. Display original run args, never inherited batch titles for untitled members; show actual IDs/outcomes and NOT_EXECUTED_SEQUENCE_STOP as unexecuted. Preserve settled IDs/independent async; only expansion owner transforms history.
- **Cancellation closure**: Settle pairs once, suppress queued handlers and request active-handle cancellation. Started cancelled members count failed, not unexecuted. Submitted independent tasks stay ID-owned without implicit kill/rollback; late callbacks neither replace results nor dispatch skipped work.
- **Experimental compatibility boundary**: This is not retired calls/async multicall. Legacy history remains read-only without execution/translation; retired lua/call remain unavailable. Ordinary batching/multirun behavior and receipts remain unchanged.

## Async, Results And Lifecycle

### Requirement: Async tasks are session-local and terminally latched

Supported tools/wrappers MAY return `async_id`; state SHALL NOT survive Neovim restart. Both `wait`/`kill` require it plus concise nonblank string `title`, display-only: do not select/rename/mutate registry tasks or returned data, or alter wait lookup/waiting/timeout/consumption/result behavior for the same ID/options. Direct/nested validation rejects missing/blank titles, before cancellation for kill.

| Tool | Operation and display |
| --- | --- |
| `wait` | Nonblocking `try`, bounded `wait`, optional terminal consumption, not-found/expired handling. Pending/completed/restored summary `wait "<title>"`. |
| `kill` | Mark running outer task terminally `cancelled`, invoke canceller and cooperative inner handles. Already-terminal returns facts without recancelling; late success/error is ignored. Non-cancellable inner work may finish in background while outer stays cancelled. Direct/wrapped/pending/completed/restored summary `kill "<title>"`. |

Persisted pre-change untitled calls render bare `wait`/`kill` without history rewriting, never making new untitled calls executable.

- **Async result projection**: Succeeded wait MUST return stored result verbatim, no status/result wrapper/header; consume only cleans registry. Other states return minimal async_id/status, applicable wait_timed_out and raw cause; waiting timeout is not task timeout. Run async shell/tool/Windows receipts retain ID/state/current-Neovim lifetime, not title/tool/timestamp/tutorial echoes; startup failure is explicit. Kill returns ID/state/cancellation fact, distinguishing cooperative request, already-terminal/not-found and canceller failure, never claiming all inner work exited. Internal registry/diagnostics and multirun JSON/member/submission formats remain unchanged.

### Requirement: Wrapped SubAgents stop cooperatively

Async tool-mode run/multirun around a cancellable SubAgent SHALL expose invocation-local cancellation context. Cancel suppresses scheduling and requests safe-boundary child stop without corrupting pairs; non-cooperative work may continue, late results cannot replace cancellation and no external rollback is implied. Cancelled child results are unavailable/partial, never verification evidence. Detailed run/fork/resume/workflow/streaming: [SubAgent Runtime](../abilities/base/subagent/subagent-runtime.md).

### Requirement: Oversized output is bounded

Non-exempt oversized text/errors SHALL become complete line-readable temporary files with bounded preview/path/size-state facts, no input echoes/tutorials. Command/tool run, members and lua retain identity/success/failure/timeout diagnostics; Lua logs must not silently overwrite within one second. MCP images become temporary files with path/format metadata, not base64. Preserve target exemptions and async/cancel/error lifecycle; wrapping never imposes command stdout/stderr format on native results.

- **Concise local state and diagnostics**: Unchanged/coalesced loads return readiness without digest/tutorial, while complete changed catalogs stay protected. Edit locating failure keeps path/no-write/unmatched-block reasons, not duplicate headings. Fire reports event-fired, not hook completion. Shared oversized errors retain full path/byte size/preview/error channel, not duplicate longest-line stats/tutorials. Internal execution/state is unchanged.

### Requirement: TTL-managed results carry explicit lifecycle metadata

Identify exact tool-call ID and expiry. `keep` actions: `discard` removes now; `defer` retains positive additional response rounds; `keep` lasts current Chat; `persist` protects across compression. Invalid actions, missing IDs, missing `ttl` for defer or inaccessible exact Chat state SHALL fail.

Read's header owns TTL metadata placement. A latest expired same-effective-request predecessor adds one concise header reminder, no new user message/automatic extension. Compare direct read, synchronous tool-mode run→read and historical call→read, not async wrappers. Other requests, kept/discarded/nonexpired predecessors and other tools remain unchanged. Defer updates and keep/persist clears only proven runtime metadata, preserving all source bytes even matching markers; remove historical footers only at the known appended suffix. Expiry/counting/default TTL are unchanged.

## Capability And Context Loading

### Requirement: `load` has one concise target contract

Require nonblank `target`; optional boolean `force_reload`, default `false`. Select deterministically:

| Target | Result |
| --- | --- |
| Valid Ability identifier | Root load/refresh under the transaction below. |
| `#<ability>[<target>]` | Shared file-first/absence-only selection: inject one root-confined eligible package Markdown file or authorized textual resource. |
| Otherwise | One existing allowed Markdown path: project `.maxa/**/*.md`, `.maxa/abilities/**/*.md`, root `justfile.md` or global Ability Markdown. |

Malformed/old colon-form `#` fails as reference, not ordinary path. No `format`. Root returns compact complete catalog with sanitized instructions/guidance separately injected. File/reference/path requires exact Chat injection and returns concise loaded/deduplicated facts, preserving Markdown eligibility, sanitization, deduplication, file events and force_reload behavior. Reference IDs retain selected file/resource outcome and wrapped association. Existing ineligible/unreadable package files fail without resource fallback. Resource injection implies neither rendering nor execution.

### Requirement: Context, Ability and MCP loading is ordered and deduplicated

Root loading SHALL validate dependencies/sources, prepare sanitized instructions/catalogs/hooks/optional guidance, activate any MCP source with project-keyed provenance authorization and atomically commit one exact-Chat revision before observers/autosave. Preserve dependency-first and assistant/tool-result/context order; failure/cancel before commit leaves no partial root authorization/hooks.

The catalog-bearing `load` result is the sole visible complete tool/resource catalog, surviving direct/wrapped/dependency calls, compaction and restore. Bounds, TTL and later ready/unchanged loads MUST NOT truncate, expire or replace it; an unrepresentable complete catalog fails before commit. Later ordinary load reconnects if needed and returns ready/unchanged; `force_reload=true` emits a complete revision only if changed.

Global connection, another Chat, mentions, management operations and hidden metadata without complete result grant no actions/resources. Activation never exposes raw config/env in Chat/history/output. Resource templates/prompts are excluded; resource-only sources are valid if concrete identifiers meet the exact-identifier contract.

### Requirement: `@` and `#` completion displays executable Ability targets

Exact-Chat catalog SHALL list bare `@<builtin>`, available Ability names for explicit load, ready scripts/tools as exact `@ability:target` and complete `#ability[target]` content references using the load formatter. Disclosure/ready-resource policy is unchanged; no source-type markers, mandatory quotes or generated aliases. Disabled/unauthorized resources and old colon-form candidates stay absent.

Blink/omnifunc/manual completion SHALL share this literal catalog and support partial brackets. Whitespace, internal brackets, query/fragment, `#`, `@`, `/` cannot truncate/reinterpret references or redirect to slash/tool completion. Selection inserts the complete reference; following punctuation/body cannot consume the next active token. Completion is side-effect-free literal insertion; mentions never load/call/read/render.

### Requirement: `fire` requires complete defined AbilityHook events

Accept event name without `AbilityHook` prefix and object/decodable JSON-string data. Reject undefined/invalid names, malformed data or known incomplete payloads; derive exact Chat buffer, inject `bufnr` and dispatch. Pending/completed/restored display `fire <event>` neither invents/renames/validates nor dispatches through display. Result semantics follow **Concise local state and diagnostics**.

## File And Search Tools

### Requirement: `read` supports ranges, lifecycle policy and Ability references

Accept filesystem paths or unified `#<ability>[<target>]`; optional `start_line` (1-based), `end_line` (positive inclusive or -1), `cursor`, `result_policy=auto|temporary|keep|persist`. Ability grammar/confinement belongs to the package owner. File-first fallback to exact authorized resource occurs only on genuine file absence; reject old colon-form `#`.

| Input/state | Required handling |
| --- | --- |
| Missing end_line or -1 | Target EOF. |
| Explicit temporary + positive end_line | Reject; start_line MAY locate content. Other policies retain positive end_line. |
| Cursor | Resume same unchanged source/requested bound, even within an overlong line; reject conflicting location args, malformed tokens or changed source, never skip/duplicate text. |
| `force=true` / `force=false` | True fails without reading; false MAY remain compatibility-accepted. |
| Auto policy and `/tmp` | MAY TTL-manage; lifecycle remains unchanged. |
| Package file | Shared target-only current-package resolution independent of ready/disclosure, without loading/activation. |
| Resource | Exact-Chat authorization; join textual parts with one newline before processing; blob/image/audio/non-text fails without conversion/write. |

Success SHALL start `next_cursor: <opaque token|none>`, then metadata-ending standalone `---`, then unaltered source. Non-TTL shape: `next_cursor: ...\n---\n<body>`; TTL adds `tool_call_id`, `ttl`, applicable `ttl_notice` before separator, never as source footer. Reserve header space within 20,000 final bytes. Return safe contiguous chunks, `none` at requested EOF/end-line, no overflow file; retain CRLF/newlines/overlong lines without splitting UTF-8 or appending runtime metadata. Invalid parameters fail before file-access effects where possible.

Before first use, schema/description/runtime prompt SHALL explain unified addressing, header, continuation and temporary restriction, never requiring callers to select implementation source type. Historical two-line-prefix consumers must strip it.

### Requirement: `search` and `glob` provide scoped cross-platform file queries

- **Scope**: Optional `scope: string|null`; omission/`null`/`""`/`"."` means Chat project root. `@xxx` resolves one installed Ability `xxx` root without activation. Other relatives resolve from project root; absolute WSL/Windows targets MAY be outside it. Missing/ambiguous/inaccessible roots fail, never redirect. Search accepts file-only or directory; glob requires directory and errors on files.
- **Backend**: WSL-native targets use WSL `rg`; Windows-host targets use Windows `rg` via argv `runwingui`, not user-query Shell interpolation. Missing/failed backend errors without switching filesystem.
- **Search query inputs**: Search `text`/`regex` are mutually exclusive optional nonempty string or nonempty array of nonempty strings, OR semantics. Null, empty/mixed arrays, empty strings and simultaneous fields fail. Schema/prepare permit neither for position consumers; filesystem/symbol consumers reject omission before search/LSP work. Unknown fields including `patterns`/`literal` fail before extension/handler with no aliases/coercion/compatibility. Shared validation/prepare preserves canonical args, no side effects, direct/wrapped equivalence and backend eligibility.
- **Content search**: Filesystem requires exactly one query. `text` is original fixed-string matching, no regex/Lua interpretation. `case=sensitive|insensitive|smart` defaults `sensitive`; `output=matches|files` defaults `matches`; null means omitted. Files returns each matching file once; matches returns path, 1-based line and text.
- **File discovery**: `glob.patterns` accepts string/string-array/null; omitted/null/empty-array lists all discoverable files. Nonempty patterns OR over paths; return files only, not directories/content.
- **Filtering**: `search.include`, `search.exclude`, `glob.exclude` accept string/string-array/null path globs, null omitted, array OR, exclusions win. Positive globs do not bypass ignores. `hidden`/`no_ignore` independently default false and accept null as omission; disabling ignores neither includes hidden files nor weakens caller safety/authorization. Explicit-file search applies filters to that file, not its parent.
- **Results**: `max_results` omitted/null means unlimited; positive limits matched lines/files and indicates truncation when more exist. Empty search succeeds with zero. Paths are cross-platform directory-relative; file scope uses its parent as base. Independent Chat size bounds stream complete oversized results to a line-readable temp file, returning path/statistics for ranged read—not discard or count-truncation mislabelling.
- **Unified search regex semantics**: Every supporting filesystem/Neovim consumer MUST use ripgrep default Rust regex, independent of local configuration, never Lua/Vim/implicit PCRE2. Neovim uses runtime-host rg on supplied candidates, not scanning files, Shell interpolation or another index. Invalid regex/missing/failed backend errors even with zero candidates; no escaping rewrite, inference or text/backend fallback. Filter before dedup/count limits; retained-candidate/output safety truncation must not imply complete coverage.
- **Neovim candidate filtering lifecycle**: Startup, applicable LSP and async regex filtering share the existing combined 10-second deadline/cooperative cancellation. Cancel/timeout/source-change/process/request error stops owned pending work with at most one terminal result; late callbacks cannot replace it. Check freshness before success and release owned hidden buffers before completion starts a wrapped successor; preserve user buffers/unsaved content/windows.

### Requirement: `search` and `glob` display only one-line call identity

Display active text/regex for search or patterns for glob: first string, `(+N)` for remaining entries, caller scope (default `.`). Queryless position calls retain scope, no fake query. Empty/null/omitted glob patterns show `all`; `search.output="files"` adds `files`, default/null matches adds nothing. Bound/clean to one line; invalid historical args safely fall back without execution compatibility. Do not display hidden/no_ignore/other filters, result body or dedicated fold. Direct/wrapped reuse one formatter; status/duration/bytes/TTL and generic batch display/results are unchanged.

### Requirement: `write`, `edit`, `move`, and `delete` preserve file effects

| Tool | Required effects and result |
| --- | --- |
| `write` | Require path/content, create parents, reload affected unmodified buffers where applicable, emit create/modify effects. Concise action/path success, no Markdown report heading. |
| `edit` | Complete delimiter blocks via exact/owned fuzzy matching. Malformed/empty/mixed-delimiter/ambiguous edits fail without partial guessing. Success action/path/block-count without report heading; retain fuzzy warnings and actionable failures. |
| `move` | Require source/destination, update affected buffers, emit old delete/new create. |
| `delete` | Nonempty paths, deletion effects for successful items. Full success: concise count plus path for a single item, not large input echo. Partial failure: identify successful and failed indices/paths to avoid retrying completed deletions. |

Delete display derives from requested `paths`, never result-parsed counts: one inline path/no fold; ≥2 paths show `delete (N items)` and at most first 10 formatted paths in order plus `… and N more items`. Direct/restored/wrapped are equivalent; existing status icon stays authoritative.

## Ability-owned builtin extensions

[Ability Package](./package-and-authoring.md#builtin-extension-package-permissions) owns package permissions/fixed-file ownership. Extensions add no builtin name/schema and differ from external-process scripts and AbilityHook injection.

- **Chat-local extension activation**: Only loaded ready Skill-backed identities in exact Chat/workspace participate, never discovery/installation or another Chat's load. Later/restored invocations MUST read current installed declarations/fixed Lua, without extension revisions, hash locks, forced reload or persisted closures.
- **Dynamic first-match dispatch**: Extension returns synchronous side-effect-free `match(context) -> boolean` and `run(context, response)`. Evaluate successful load order: false continues, first true runs, none uses unchanged builtin. Scripts own interpretation; no required namespace selector/configured matching. Refresh neither duplicates identity nor changes first-load order.
- **Shared extension lifecycle**: Direct/tool-mode `run`/`multirun` share target dispatch, exact caller/guards/bounds/at-most-one completion. Reserved tool scope and trusted scripts bypass run interception; non-tool stays extension-first. Async handlers return nil and complete via response interface. Invalid/missing scripts, non-boolean match, exceptions or explicit errors fail with Ability/builtin provenance, no default fallback; recursive re-entry fails.
- **Neovim Lua symbol backend**: After `load(target="neovim")`, recognize `@neovim:symbols` for project or `@neovim:symbols:<selector>`. Suffix-bearing basename selects file (relative to Chat cwd or absolute); otherwise configured language. Map filetype dots to underscores using actual configuration, retain existing underscores; unknown/ambiguous language errors.

  Both symbol modes MUST start/reuse enabled installed LSP and await initialization without user-opened files/visible windows. Hidden buffers MAY come from existing files; release owned buffers, never user-loaded ones. Query only applicable initialized providers supporting the method, skip auxiliary non-supporters and attribute only queried providers. Missing config/support/startup/request/position fails without filesystem fallback; resolve missing positions when supported, never fabricate.

  | Symbol mode | Protocol/matching |
  | --- | --- |
  | Project/language | `workspace/symbol`, confined to project/language. Text entries are native OR queries with server-defined, not necessarily exact matching. Regex sends empty query per provider, filters returned names and always discloses candidate-only unknown completeness, including zero; unsupported empty query errors without fallback. |
  | File, including explicit outside-project file | `textDocument/documentSymbol`, including nested symbols; selected-file names matched by case-sensitive literal-substring OR text, or regex. |

  Require query; use shared regex/filter lifecycle; deduplicate and support `output=matches|files`/positive `max_results`, bounded results, normalized paths, 1-based line/UTF-8 byte columns, symbol identity/source. Unsupported non-default filesystem options error; omitted/null/default `case=sensitive`, `hidden=false`, `no_ignore=false` and omitted/null/empty-array include/exclude are neutral. Never install/configure servers, open/index every file, add an index or promise exhaustive symbols/ripgrep file-content coverage.

### Read-only Neovim LSP semantic consumers

The `neovim` Ability extends search/read with the following operations; symbols and default filesystem behavior remain separate.

- **Read-only semantic addresses**: Recognize only listed addresses. Position suffix `:<line>:<column>` is parsed from the right with explicit file and positive 1-based line/UTF-8 byte column; source line must exist, column ≤byte-length+one (EOL), not inside multibyte character. Relative files use Chat cwd, absolutes stay absolute. Missing/malformed/out-of-range position or inaccessible/non-code file errors before query; never infer identity from window/cursor/name guess. Existing `@neovim:symbols` contract is unchanged.

| Field | Address | Protocol/meaning |
| --- | --- | --- |
| `search.scope` | `@neovim:definition:<file>:<line>:<column>` | `textDocument/definition` |
| `search.scope` | `@neovim:declaration:<file>:<line>:<column>` | `textDocument/declaration` |
| `search.scope` | `@neovim:implementation:<file>:<line>:<column>` | `textDocument/implementation` |
| `search.scope` | `@neovim:type-definition:<file>:<line>:<column>` | `textDocument/typeDefinition` |
| `search.scope` | `@neovim:references:<file>:<line>:<column>` | `textDocument/references`, `includeDeclaration=false` |
| `search.scope` | `@neovim:references-with-declaration:<file>:<line>:<column>` | `textDocument/references`, `includeDeclaration=true` |
| `search.scope` | `@neovim:incoming-calls:<file>:<line>:<column>` | `textDocument/prepareCallHierarchy` then `callHierarchy/incomingCalls` |
| `search.scope` | `@neovim:outgoing-calls:<file>:<line>:<column>` | `textDocument/prepareCallHierarchy` then `callHierarchy/outgoingCalls` |
| `read.path` | `@neovim:hover:<file>:<line>:<column>` | `textDocument/hover` |
| `read.path` | `@neovim:diagnostics:<file>` | One file's diagnostic report/status |
| `read.path` | `@neovim:diagnostics` | Known project LSP cache/status, not project check |

- **Read-only source snapshot**: Use loaded user-buffer text when present, else disk, disclose `source=buffer|disk`. Prepare hidden buffers as needed, start/reuse enabled installed configs, synchronize source and convert byte position to negotiated provider encoding. No visible windows, writes/saves, discarded edits or deleted user buffers. Source change during an outstanding position query MUST yield stale-source error, not current-labelled result.
- **Semantic capability filtering**: Protocol queries use applicable initialized supporting clients, retain provider identity and skip auxiliary non-supporters. No supporting provider is an explicit capability error; supported empty location/hover/relation is zero/no information. Diagnostic freshness has separate rules; push/cache must not fail solely for missing pull methods. Startup/request/normalization errors remain explicit, never filesystem fallback/fabricated success. Preserve exact Chat/workspace, direct/tool-run/multirun equivalence, bounds and shared 10-second/cooperative/at-most-once filter lifecycle. Known-cache reads start no servers/forced scanning.
- **Semantic location queries**: Normalize `Location`/`LocationLink`, choose `targetSelectionRange` if present else `targetRange`; honor reference include-declaration selection. Return operation, source file/position/mode, responding providers and destination ranges in 1-based UTF-8 byte coordinates. Local-project paths are relative; outside-project local files (including dependencies) MAY be absolute. Unsupported URI/unavailable coordinates are explicit, never guesses. Deduplicate equal ranges retaining providers; empty/support behavior follows capability filtering.
- **Position-query search parameters**: For definition/declaration/implementation/type-definition/references/incoming/outgoing, omitted text/regex means no filter. Text OR-matches case-sensitive literal substrings of canonical rendered row; regex filters that row under shared semantics/lifecycle. `text="*"` means actual star, not disable-filter. `output=matches` returns locations/relations; `output=files` unique destinations (incoming caller files, outgoing callee files). `max_results` caps deduplicated filtered results and marks truncation. Omitted/null/schema-default nonapplicable options are neutral; unsupported nondefaults error. Preserve provider/source/position and one-hop identities; Ability guidance MUST teach this separate from symbol matching.
- **Hover content**: Query explicit position; return each provider's normalized Markdown/plaintext type/signature/documentation and source metadata without floating UI/execution. Equal content MAY group providers; differing content MUST stay separately attributed, not arbitrarily pick one. Supported-empty says no hover; unsupported errors.
- **Semantic read result protocol**: Hover/diagnostics reuse read's `next_cursor: <token|none>`/separator, 20,000-byte bounds, range/result_policy validation, UTF-8 continuation and TTL/persist. Line ranges address rendered report, not source position. Cursor continues the same materialized report without rerunning/joining LSP; address/policy mismatch or expired/missing snapshot errors and requires fresh initial read. Retention is bounded current-Chat/session-local, no durable cache/registry; filesystem/Ability reads unchanged.
- **File diagnostic query**: Prepare/synchronize source and prefer supported `textDocument/diagnostic`. Push-only returns latest observed reports with version/report evidence, never treats empty cache as completed check. Each provider MUST disclose `freshness=current|stale|unknown`:

  | State | Evidence/conclusion |
  | --- | --- |
  | current | Associated with queried source version/content. Full pull or unchanged pull linked to matching prior report/source MAY establish it; unassociated unchanged or unversioned push/cache cannot be assumed current. Only `freshness=current` plus zero items means no diagnostics in that provider, never global absence. |
  | stale | Known report from earlier source. |
  | unknown | Missing report/insufficient version evidence. A 10-second missing-fresh-report deadline MAY return unknown, never clean-file assertion. |

  Known stale/unknown diagnostics MAY return with state disclosed.
- **Diagnostic report rows**: File/range, `error|warning|information|hint` severity, message, provider, optional supplied server code/source, provider status/count even when empty. Equal records MAY group providers; severity/message/range differences stay distinct. Freshness controls conclusions.
- **Known project diagnostics**: `read(path="@neovim:diagnostics")` reads current known LSP cache only within Chat cwd, labels `coverage=known-cache`, observed providers/files/freshness. No all-project check, enumerate/open-all, provider installation or exhaustive claim. Empty cache means zero-known/unknown coverage, not project clean; identify stale/unknown entries, exclude other workspaces/non-LSP namespaces.
- **One-level call relations**: Prepare explicit position, retain/attribute every hierarchy item and query exactly one requested hop on its originating provider with intact provider-relative follow-up data. No guess-one, recursive graph or UI choice. Both directions identify caller/callee and call-site ranges in caller file (incoming callee→caller; outgoing caller→callee). Deduplicate equivalent relations/ranges with attribution; successful empty preparation/relation gives zero, unsupported preparation/direction errors.

## Human Interaction

### Requirement: `ask` is the canonical Human Assist interface

Always available without Skill/MCP load. Only `mode`, `message`, `choices`, `photo`, `parse_mode`, `silent`, `timeout`:

| Mode | Required input | Reply/default timeout |
| --- | --- | --- |
| `notify` | `message` or `photo` | No reply wait; optional parse_mode/silent. |
| `input` | Nonblank message | Chat text or one Telegram photo/text; 120 seconds. |
| `choice` | Nonblank message; 1–20 nonempty rows, ≤100 unique `{label,value}` buttons | Arbitrary Chat/Telegram text always accepted; 60 seconds. |

Optional `parse_mode` is `Markdown|HTML`; timeout integer `0..86400`, `0` no deadline. Before interaction reject silent outside notify, choices outside choice, unknown fields, invalid lengths/duplicate values. No `allow_free_text`. Derive destination/credentials internally; button result uses stable `value`, never label.

### Requirement: Chat and Telegram use first-response-wins

For `input|choice`, exact Chat/Telegram share request ID and terminal latch. First accepted Chat text, Telegram button/text or input-mode photo wins; late/duplicate responses cannot change result or satisfy another request. Chats stay isolated; at most one active ask per Chat.

If Chat wins during Bridge creation, cancel caller-generated request ID immediately so Bridge's cancellation reservation closes cancel-before-create. Telegram send/poll failure leaves usable Chat input active. Notify succeeds if either Chat display or Telegram delivery succeeds; both failing is error.

### Requirement: Chat submission and cancellation preserve tool protocol

While waiting, ordinary send SHALL consume only raw ask-owned editable range before normal submit hooks, Telegram binding block, `ChatSubmitted` or provider dispatch. Preserve outer spaces/blank lines/Markdown blockquotes, exclude Builder header/spacing; whitespace-only stays pending.

Stop/close MUST cancel owning batch before ask's error completion. Queued calls get cancellation results without handlers/effects; no auto-submit or normal ToolCallsCompleted work. At most one terminal result per path.

### Requirement: Ask results and display are plain and canonical

No JSON envelope: free text unchanged; button `用户选择了"<value>"`; downloaded input photo optional text then `附件有:` and local path bullets; notify `通知已发送`, or Chat-only `通知已显示在 Chat；Telegram 投递失败`.

Invalid args, shared timeout, explicit cancel, destroyed exact Chat without another completed channel or total-channel failure are tool errors. Display request as assistant Markdown, successful input/choice as user style; persist only canonical assistant call/matching result. Channel state/line/extmarks stay buffer-local. Restore/fork/compact rebuild request/result order, including sequential same-batch asks, without forging model-visible roles.

### Requirement: Ask projects local links only at user-facing boundaries

Apply [local Markdown link projection](./chat-commands.md#requirement-local-markdown-link-projection-preserves-canonical-content) to ask request display (including existing root relay), its Telegram `message` copy, and the existing eligible immediately preceding visible LLM response. Resolve against the owning Chat's project; root relay retains source-project identity and reuses the transformed predecessor copy. Preserve canonical ask parameters/results, `photo`, choices/values, `parse_mode`, first-response/cancellation and predecessor-selection rules. HTML content remains unchanged. Service failure does not block delivery or usable local input. Do not duplicate predecessor text in the invoking Chat; the temporary root entrance follows `Root ask predecessor context`.

Actual post-restart ask/predecessor Chat spans retained local canonical paths while showing HTTPS links; the user confirmed the topic link opened its image. Child/root relay link projection was not independently observed live.

### Requirement: Ask relays only its immediately preceding visible LLM response

Before builtin ask's Telegram delivery, send the invoking Chat's immediately preceding visible nonblank LLM response as a separate plain-text notification in its exact session topic. The current ask's own textless tool-call record is not a predecessor; same-model-response visible text qualifies only when ask is the first call. A preceding user message, other tool call/result, invisible non-call context or textless LLM response MUST NOT trigger backward search for older replies. Send response content only, never reasoning, hidden context, tool parameters or parent/other-Chat history. Do not duplicate it in the invoking Chat or change ask inputs/results; the temporary root entrance follows `Root ask predecessor context`. Runtime-internal asks do not relay model text.

Complete that send attempt before sending the original ask. Response-send failure retains ask delivery and local reply; cancellation stops further delivery. Existing first-response arbitration and exact-topic policy remain. Ordinary content produces response then ask; long response follows [complete sequential notifications](../services/telegram-bridge.md#requirement-plain-telegram-notifications-are-complete-and-sequential), producing all response segments before ask. Do not inherit ask's `parse_mode` for response text.

On 2026-10-12 user-observed live asks after full Neovim restart confirmed tool-predecessor ask-only delivery, immediate visible LLM response then independent ask, and successful choice completion. User confirmed complete two-segment plain notification with continuous numbering, Chinese, emoji and end marker. New relay failure/cancellation and separate user-predecessor interactions were not independently exercised; existing focused ask/listener checks retain their scope.

### Child ask root relay

- **Root ask predecessor context**: An eligible child `input|choice` root entrance MUST show child title, the complete eligible predecessor from the invoking child Chat, a Markdown horizontal rule, then the existing request/options and reply area. Reuse the source-project projected predecessor; do not rescan history, summarize, truncate or inherit request `parse_mode`. No eligible predecessor retains the existing layout. Context remains temporary with the entrance: remove it on completion, cancellation or eligibility loss and restore root state. Do not add canonical root messages, alter parameters/results or duplicate context in the invoking Chat or Telegram. Existing FIFO, blocking-wait eligibility and first-response arbitration remain unchanged.
- **Shared child ask root entrance**: A child `ask(mode="input"|"choice")` with exact live execution-root Chat MUST keep child/Telegram entrances and add one temporary root entrance to the same request. First valid answer completes original child once, removes all entrances and rejects late answers. No duplicate Telegram, parameter/result changes or forged root message; notify stays one-way.
- **Eligible root ask FIFO**: Root exposes at most one relay, selecting eligible pending requests by original sequence regardless of visibility. Ineligible async cannot block eligible requests. Root-local input owns its range; relay waits for availability. Remove externally completed/cancelled requests.
- **Blocking wait ask eligibility**: Async asks gain root input only while owning task has active `wait(mode="wait")` subscription; try is immediate/presentation-isolated. Return/timeout/cancel removes subscription/ineligible entrance, not original ask/task; later blocking wait MAY reattach. Ownership follows nested execution ancestry/batch single async identity, never window/other task.
- **Reversible root ask input**: Teardown MUST restore draft, header/Builder/role state, editability and affected cursor/view without rerunning parent tools or adding canonical root ask calls/results. Delivery stays child-owned; explicit cancel cannot settle unrelated parent work. Source termination/root or source close/late callbacks clean relay safely. Root stop still cancels its current Agent turn via existing protocol.

On 2026-10-13 tool-driven actual child choice after full Neovim restart showed the complete two-line predecessor (Chinese, Markdown and emoji), separator, request/options and reply area in the root entrance. Parent option selection reached the child; the transient entrance was removed without canonical root predecessor copies. Human implementation review and independent root HTTPS-link/cancellation/eligibility-loss observations were not run.

## Tool Presentation

### Requirement: `run` summary uses required title

Apply **Title-owned execution display**: execution identity precedes nonblank title; valid title-less tool calls delegate target display, while non-tool members/history keep command/scope/argv fallback.

### Requirement: Title-owned execution display

Standalone run and members, including completed/restored, MUST share original-argument display. Only explicit member title displays; omitted/null remains untitled, no batch-title inheritance. Execution inheritance/args/byte accounting stay unchanged.

| Input | Required summary |
| --- | --- |
| Nonblank explicit title | `<execution identity> "<title>"`: exact command target for tool, exact scope otherwise, shell for absent/null/empty scope. Distinguish Shell/Windows/builtin/Ability action/script/extension; no run prefix, command body or parameters. Retain whitespace/control cleanup and 100-character title bound. |
| Untitled scope=tool | Decode target args, use existing target formatter through retained dispatch; no run·tool:target or wrapper-specific summary. |
| Untitled non-tool | Ordinary command/scope/argv. |
| Multirun | Outer title; labels/indices are not tool names/generated member titles. |

Status/duration/TTL/native results/canonical history/safe historical fallback stay unchanged; no execution/schema/prepare changes.

### Tool-owned display interface

The pure view contract and host lifecycle apply to direct/wrapped/batch/restored presentations; execution/business owners remain separate.

- **Optional tool-owned display method**: Local tools MAY implement pure `display(args, result)` over original args and `result` of `nil` or `{ok:boolean,text:string}`. `ToolView`: string/`false`/omitted `summary`, optional boolean `progress`, ordered `markdown|message|fold` `blocks`. Tools extract/organize result text and tolerate pending absence; no new callable/schema field/value-selection DSL/second registry.
- **Minimal structured tool view**: `markdown` contains only tool-authored `content:string`; message has `role=assistant|user` and `content:string`, role visual-only; `fold` has `title:string`, `content:string` and optional `collapsed:boolean`, default collapsed. No required component IDs/positions/per-block result selectors; host distinguishes ask request/response canonical provenance.
- **Builtin display semantic ownership**: Owners generate search/glob/read/write/edit/move/delete/analyze/fire/load/wait/kill/keep/run/multirun summaries and delete/multirun folds; ask owner/helper generates request/response roles/choices, coordinator owns channels/input. Native tools use MCPHub's local extension contract. Renderer cannot duplicate tool-name/JSON-field semantics; keep/TTL/Artifact business ownership remains, old-interface-specific display absent.
- **Display delegation uses original arguments**: Wrapper delegates original decoded target args to actual display/show/detail, retaining typed blocks/roles/independent folds/settings, not flat strings. Title rules above govern identity; `summary=false` suppresses ordinary summary/progress, not errors. Multirun composes members in input order; original args/results/bytes and execution inheritance stay unchanged. Only existing wrapper/member composition, no arbitrary public component tree/business selector.
- **Display is not execution**: Only supplied args/results; no schema validation/prepare/run, Ability load/activation, MCP connect, buffer write or Chat mutation. Unknown/missing methods, exceptions and invalid views safely fall back without blocking restore; host visibly reports real errors even with summary=false. No public `source/format/path` expressions/tool-supplied coordinates.
- **Shared display presentation and restoration**: Live/restore share entrypoint. Renderer exclusively owns spinner/status/async/wrapped icons/highlight/duration/bytes/TTL/UI writes/canonical metadata/fold-window lifecycle. Persist only serializable final content/necessary logical provenance, not running hints/child detail/handles/callbacks/timers/positions. Restore never executes or reopens inputs/channels; model content/roles never change. Expiry/discard removes derived body; replacement/trimming invalidates provenance/folds. Old display API/Artifact/history-specific paths MAY be deleted, with safe plain-name fallback.
- **Call-scoped presentation handle**: Actual context provides ui:show(view) replacing call presentation, ui:detail(text_or_nil) updating its sole child detail, ui:input(options,on_submit) returning idempotently closable handle. Members capture independent existing call-ID/context/region/state; never arbitrate by latest member, overwrite siblings or other canonical messages. Terminal handles cannot write. Deny parent-Chat batch input without changing child Chat capability.
- **Reusable input ownership**: Input uses `mode=input|choice`/current ask choices and passes submissions to tool/coordinator, not automatically adding user messages, requesting provider or completing tools. At most one active Chat input handle; competition errors. Host owns draft/Builder/keymap conflicts/close cleanup, tool owns empty/business validation. Ask keeps its raw text/choice/photo/arbitration/degradation/cancel contract. Active input/tool/wait stop MUST latch batch cancellation before callbacks, retain one cancel result per call and suppress queued/provider continuation; never rely on closing Chat/deleting incomplete calls.
- **Latest tool summary observation**: On start/spinner/success/error producing actual one-line summary, owner notifies call ID/start order/rendered text. Subscription is cancellable, observer errors cannot interrupt tools. Use renderer output, not reverse-buffer reads/polling; consumers MAY filter ended/older calls.
- **Every batch member presents independently**: Show all member regions and queued/running/success/failure/cancel states simultaneously in input order with complete target custom view or safe default. Update self only; terminal member never clears running siblings.
- **Running and terminal batch folds**: Outer fold opens at startup and stays expanded on refresh, preserving member folds/roles/nested ranges. Auto-collapse once only when all terminal, including failed/cancelled/unexecuted-cancelled. Final expansion/restore shows same ordered custom content, never re-executes.
- **Batch preflight rejects interaction**: Before any handler/process, side-effect-free resolve/authorize all targets. Local `interactive=true` (all ask modes included) is forbidden in parallel/sequence sync/async multirun; reject entire batch with member/target identity before sibling effects. Never activate/connect/run during preflight. Input handles also deny batch-parent input to catch undeclared targets; flag is not Agent parameter/public MCP schema.
- **Active blocking wait presentation continuation**: `wait(mode=wait)` mounts source async invocation/member views/right decoration only during active wait. Return/completion/timeout/cancel/Chat close removes live rows/blocks/detail/subscriptions and rejects late updates. No persisted/replayed execution snapshot; terminal result follows next rule. Wait keeps its status/icon/canonical result/error. Source interprets content; wait cannot parse business JSON, execute/authorize again, alter cancellation/consume/try/timeout=0 or mutate original submission. Submission decoration follows its own exception below.
- **Nonblocking wait presentation isolation**: `wait(mode=try)` returns immediately without live subscription/mount. Succeeded source MAY provide only completed pure result; running/unavailable/error keeps wait diagnostic fallback, no snapshot/live state/detail.
- **Wait-owned terminal result fold**: Completed wait retains own identity and initially collapsed result group. Succeeded source with completed view MUST delegate only final pure ToolView as run does: authored summary/blocks/roles/nested folds/right decoration/logical child link; no raw-payload substitution or invented body for summary-only target. Persist only final presentation/rendering identity, not execution args/snapshot/live state/detail/observers/subscriptions. Missing presentation or task-state/error diagnostics uses exact nonempty returned text fallback fold; empty stays summary-only. Direct/wrapped/member/terminal `try`/`consume=true`/restore preserve canonical output/lifecycle; wait does no business JSON parsing, re-execution or authorization.
- **Right-side tool decoration**: Optional `right:string` and active `ui:right(text_or_nil)` render right-aligned virtual text without changing authored summary/detail/canonical content. Unknown/absent preserves display. Wrappers/members/folds/restored final views retain decoration; narrow windows MAY truncate/hide, never cover authored text. Persist serializable final text only, no observers/handles/positions.
- **Async submission decoration exception**: Task-private async may update only original submission/member right decoration and serializable metadata until source termination; not submission text/result/status/duration, reopening completed handles/live detail or dependence on active wait. Owning Chat close detaches; completed wait stays transient, try isolated.

### Tool Display window lifecycle

- **Recover tool folds after background completion**: With folding enabled, retain summary/edit-tracking range without real Chat window; on later display create fold at existing collapsed default with normal open/close, no timed polling/hidden-duration limit.
- **Apply folds in real Chat windows**: Target actual owning-buffer windows across tabs/ordinary floats, never autocmd temporary windows as visible/active association or authoritative target; no background focus theft.
- **Idempotent native-event recovery**: Reconcile window association/recover missing folds from native events without synthesizing events. Repeats cannot nest duplicates or reclose already user-open folds in the same window.
- **Invalidate replaced fold content**: Track buffer edits; removed/replaced definitions cannot apply to unrelated text. Full render/restore rebuilds through shared fold owner, without persisted-format changes.
- **Fold text preserves authored title**: Exact owning title, no prepended checkmark/status icon/spacer or inline virtual status icon. Existing authored status text/semantic highlighting stays.

## Image Analysis Scheduling Boundary

`analyze` SHALL accept its linked image-analysis contract, complete only on current hidden-child tool-free nonempty final text and return ordered facts with actual accounting. No direct async flag; long work MAY use titled `run(scope="tool", command="analyze", args=<encoded object>, opts='{"async":true}')`, wait/kill, with target timeout/max_steps in args. This owner schedules, not formats/crop/resize/prompt/budget/errors/cleanup.

## MCP Boundary

MCP tool/group/resource/prompt/slash entries are never dynamically copied into the Chat registry. First-party inventory remains Chat-owned/MCPHub-independent. Ability load precedes authorized run/multirun or resource read; pending same-batch load is not authorization.

## Validation Evidence And Risk

The following dated records retain their original validation scope; wording changes do not rerun or upgrade these checks.

### Dispatch, schema and commands

Authorized reconnect: focused dispatch/transport and real restart-resume tool execution passed, human implementation review not-run.

Shared raw validation/non-strict/label cleanup: recursive schema checks and canonical rejection passed; direct/member/inner prepare single-execution checks passed; Responses preserved source optionality with strict=false and DeepSeek retained its field boundary. Fresh-Neovim calls omitted optional/null fields and labels successfully; invalid decoded builtin/MCP types were rejected before target execution. Actual visible Chat batch members used ordinary run summaries with and without titles. Human implementation review not-run; validator intentionally supports the documented standard subset and rejects unsupported constraints rather than claiming full JSON Schema coverage.

Unified run/multirun: focused inventory/strict-schema/preparation/dispatch/sequence/parallel/async/cancel/history/TTL checks passed. Fresh-Neovim script/MCP/Shell/native argv/Windows calls, inferred async sequence waiting actual completion, wait/kill and one real analyze child passed. The restored visible Chat showed new title summaries and unchanged retired historical calls. Human implementation review was not run; prior human baseline is not approval of this change.

Scoped run preparation: focused preparation/schema/caller/script/supervisor checks and fresh-Neovim actual direct/wrapped calls, strict conversion and visible Chat summary observation passed. Human implementation review was not run; detailed evidence remains in execution records.

Windows execution: focused tests and fresh-Neovim public direct/wrapped Windows argv/cwd/async/timeout/cancellation/detach calls passed. GUI window/file opening was confirmed by the user after desktop automation was blocked by missing `win32gui`; only this GUI path has new human evidence, not a whole-code human review. Unrelated existing prompt assertion and registry baseline drift remain recorded in execution records, not expanded into this change.

Multicall: focused contract checks, fresh real single-call runs/flat paired provider replay, native sequence stop/continue, independent async/wait, atomic rejection/cancellation and actual multirun-equivalent running/terminal/restored display passed. Detailed evidence, prior failed attempts and unrelated stale-test limitations remain recorded. Human implementation review not-run.

### Loading, search and LSP

Independent file references: Focused checks and fresh-Neovim actual unloaded file read/injection passed without ready-state activation; unloaded action/resource access still failed as required. Detailed evidence and the unrelated legacy prompt assertion failure remain recorded; human implementation review was not run.

Unified content: fresh-process actual Blink menus, resource/package selection and explicit reads passed, including punctuation-preserved replacement ranges. Human implementation review not-run; no UI test code was authored.

Builtin extensions, on-demand symbol consumer and provider filtering: initial framework checks, affected consumer checks, real cold LSP calls, and mixed-provider `foundation.js` query passed. Human implementation review was not run; existing document-level human validation is historical baseline evidence, not approval of this extension.

Read-only LSP: Focused consumer/dispatch/read/Ability checks and fresh-Neovim actual definition/reference/hover/diagnostic/incoming/outgoing/default-file calls passed. Actual unversioned push/cache reports remained `unknown`, not clean; unsupported declaration errored explicitly. Source hashes, loaded user-buffer state and visible windows were unchanged. Detailed evidence and the completion-before-cleanup regression fix remain recorded; human implementation review was not run.

Text/regex search: Three focused checks, full Neovim restart-resume, actual text/file/workspace/file-symbol/position regex calls and visible Chat summaries passed. Workspace empty-query returned zero candidates with `completeness=unknown`; this is not project-wide absence. Human implementation review was not run; prior document-level human validation remains historical. Detailed evidence remains in execution records.

`read` cursor bounds, overlong UTF-8 lines, CRLF reconstruction, positive `end_line` continuation, `temporary` rejection, stale cursor, direct/wrapped fresh-runtime calls, TTL and registered schema passed focused checks; detailed evidence remains in execution records. The two-line response prefix replaces legacy raw-body/line-number-only results; callers parsing `read` output must strip it.

### Results, display and interaction

Builtin results: focused async checks and fresh actual receipt/raw wait/wait-timeout/kill states passed. Detailed commands and scope limits remain recorded; human review not-run. Focused and actual concise local-state/diagnostic result checks also passed; internal execution/state remains unchanged.

Root ask relay: existing focused checks, fresh-runtime synchronous/async/FIFO/nested/source-entrance interactions and cancellation evidence. Actual Telegram replies and unsent-draft interaction were not separately exercised; human implementation review not-run.

Execution-target display: existing display check passed (19 cases), full Neovim restart and actual visible Chat explicit-title target mapping, untitled batch command/read/search parameter details and restored earlier batch observation passed. User's latest clarification separates execution-title inheritance from display; prior inherited-display evidence is historical and superseded. Human implementation review not-run; no UI test code added.

Titleless target display: syntax/scoped diff passed, full Neovim restart and actual visible Chat read/search member summaries and explicit-title preservation passed. Human implementation review not-run.

Wait result presentation: focused checks and fresh actual customized SubAgent blocking/try/consume/fold/history observations. User confirmed the revised completed result display on 2026-10-07; earlier raw-text-only evidence is superseded for this behavior.

Tool-owned display: existing display 19/19 and directly affected image-preparation 22/22 checks, Lua syntax/scoped diff, full Neovim restart-resume, actual direct/wrapped/batch summary observation and live/restored delete fold expansion/closing passed. One saved read-only child audited baseline and resumed for diff review; main session implemented and verified. No new UI test code; human implementation review not-run.

Unified presentation: tool-owned views, actual ask/input/cancel, Native/async-wait answer folds, hidden-child updates, TTL/Artifact invalidation and saved canonical provenance passed focused checks and fresh Chat observation. Overall human implementation review remains not-run; user confirmation is limited to ask visual/input and Ctrl+C cancellation. Older display evidence above is historical, not the current display interface. Detailed results and validation boundaries remain recorded.

Complete presentation projection: independent sync/async-wait members, natural running-open/terminal-closed nested folds, preflight/input denial, saved canonical provenance and title-only fold presentation passed focused checks and fresh actual Chat/history observation. Earlier failed fold observations and exact commands remain recorded; overall human implementation review not-run.

SubAgent context indicator: existing focused checks, fresh-Neovim actual sync/async/member/right-alignment, narrow-window, wait teardown and restored-history observations. Human review not-run.

### Earlier validation boundaries

On 2026-09-30 the user explicitly confirmed human review passed for all current changes, including search/glob inventory/display/parameter variants, `kill` identity/title, bounded `read`, concise results and background folds. These observations cover the effective requirements. The older statements below retain their original validation time and scope; no automated checks or UI interactions were rerun for this lifecycle-only promotion.

Background tool fold recovery passed actual restarted Neovim interactions for delayed hidden completion, cross-tab application without focus theft, normal fold open/close, repeated-event preservation of open folds, native buffer/split association and restored history. The existing focused display check passed; detailed evidence remains in execution records. Human review was not run.

Concise builtin results passed focused headless execution/overflow/file-effect checks, existing Lua/delete focused tests, and restarted Chat direct `run`/`winrun` plus wrapped `call` checks; detailed evidence remains in execution records.

Earlier focused suites passed for the historical 17-tool inventory/schema ordering、restored-registry cleanup、direct/nested/parallel builtin and Ability calls、literal-argv scripts、Ability file/resource reads、JSON injection、output bounds、exact caller context、ask lifecycle、TTL、async/cancellation、final-text image analysis、bounded invalid-call handling and adapter serialization。Ability hard-cut validation additionally passed provenance authorization/catalog separation、resource-only load、disabled/ambiguous rejection、cross-project restore/transfer、atomic revision/result persistence、project-keyed reconnect、literal completion and bridge/legacy-loader absence。Tool Display checks passed required `lua.title`、`fire <event>` and direct/wrapped/restored bounded delete folds；fresh-runtime live smoke passed。

The 19-tool inventory, restored registry and adapter schema-order focused checks passed. Fresh Chat calls exercised `search`/`glob` on WSL and Windows-host paths, Ability root, file-only search, output count truncation, full-result temporary file with ranged `read`, hidden-file filtering, and normal versus disabled ignore-file behavior; detailed commands/results remain in execution records. Human implementation review for this addition was not run.

For one-line `search`/`glob` Tool Display, the existing focused display suite passed and the actual restored Neovim Chat showed direct multi-pattern/file-only `search`, wrapped `search`, empty-pattern `glob`, multi-pattern `glob`, and default `.` scope as single summaries without visible result bodies; evidence remains in execution records. Human implementation review was not run.

Live ask checks passed Chat+Telegram notify, Telegram-button choice, and exact Chat text input. Telegram-unavailable → Chat fallback passed focused automation but was not run as a destructive live transport test. Human specification review for the prior consolidated contract passed on 2026-09-15; the invalid-call tool removal contract was explicitly agreed and implementation-authorized by the user on 2026-09-16.
