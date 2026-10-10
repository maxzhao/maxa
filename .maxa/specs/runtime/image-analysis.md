---
title: Image Analysis 运行时规格
created: 2026-09-07
updated: 2026-10-09
type: source
doc_role: spec
authority: stable
status: stable
capability: image-analysis
validation:
  specification: passed
  automated: passed
  live: partial
  human: passed
sources:
  - lua/maxa/interactions/chat/tools/builtin/tools/builtin_analyze.lua
  - lua/maxa/interactions/chat/tools/builtin/runtime/image_preparation.lua
  - lua/maxa/interactions/chat/tools/builtin/runtime/image_analysis_controller.lua
  - lua/maxa/mcphub/native_servers/subagent/utils.lua
confidence: high
---

# Image Analysis Runtime

## Purpose

Own `analyze`: ordered joint-image input, deterministic preparation, hidden-child execution/accounting, final-text output and disposal, isolated from parent pixels/history and reusable SubAgents.

## Ownership

Source filenames below resolve to the exact paths in `sources`.

| Owner | Responsibility |
| --- | --- |
| `builtin_analyze.lua` | Schema, caller/vision checks, ordered all-or-nothing preparation, child construction, result encoding. |
| `image_preparation.lua` | Content probe, validation/normalization, crop/resize, final metadata, temporary-file cleanup. |
| `image_analysis_controller.lua` | Dispatch accounting, tool continuation, final text/empty correction, timeout/cancel, terminal latch/disposal. |
| SubAgent `utils.lua` (`util.mcphub.subagent.utils`) / maintained `fork_context` helpers | Clean prefix, inherited context/registry, hidden Chat, analysis tool restrictions. |
| `run` / `multirun` / `wait` / `kill` builtins | Wrapper/batch async and session-local polling/cancel; not analyze-owned parameters/state. |

Caller contract: [[specs/abilities/base/genai/native-mcp|GenAI Native MCP 与媒体工作流规格]].

## Public Interface

### Requirement: `analyze` accepts one ordered joint-analysis request

The public object schema SHALL set `additionalProperties=false` and require `images` (nonempty ordered array), `analysis_prompt` (nonblank joint task), and `max_steps` (finite integer regular model-request budget, `1..9007199254740990`). Optional top-level `timeout` is positive seconds, default `300`.

Each `images[]` is a strict object requiring nonblank `path`; processing options are independent per item and SHALL NOT be accepted at top level:

| Field | Contract |
| --- | --- |
| `path` | Readable local regular image; resolve from caller project cwd, supporting `~`. |
| `detail` | `low|high|original|auto`, default `original`; model hint only. |
| `region` | Strict percentage object `{x,y,w,h}`: values in `0..100`, positive `w,h`. |
| `target_long_edge` | Optional integer `1..8000`; omission means no resize. |
| `resize_mode` | `upscale_only|downscale_only|always`, default `downscale_only`; inert without a target. |

One image uses a one-item array; repeated paths remain distinct ordered inputs. Validation/preparation SHALL be all-or-nothing: optional JSON null follows shared absent-value normalization; required null, unknown properties, invalid enums/ranges, missing caller/tool identity or unsupported vision fails before model dispatch. An invalid later item fails the invocation even after earlier preparation, with its 1-based index and bounded diagnostics. No child is created or image silently omitted; no registered child pixels or temporary processed files survive failure, including earlier allocations under **Every terminal path disposes the hidden child**.

## Deterministic Image Preparation

### Requirement: Decoded content determines image format

ImageMagick is the maintained probe/transform dependency. Every image SHALL be probed by decoded content, not filename/extension; final MIME SHALL derive from verified final bytes.

| Decoded content | Preparation |
| --- | --- |
| Single-image PNG, JPEG, WebP or non-animated GIF | MAY retain original bytes if neither crop nor actual resize occurs. |
| Other decodable single-frame raster | SHALL normalize to 8-bit sRGB PNG. |
| PDF, SVG, undecodable/unsupported content, animation, multiple frames/pages/scenes or nonpositive dimensions | SHALL fail; no frame/page selection or invented representation. |

### Requirement: Crop precedes proportional resize

`region` uses original-image percentages. Crop SHALL precede resize eligibility; compare the resulting current longest edge with `target_long_edge`:

| Condition/mode | Resize |
| --- | --- |
| Equal edges, any mode | No resampling. |
| Omitted target, even with a valid mode | None. |
| `upscale_only` | Only when current edge is smaller. |
| `downscale_only` | Only when current edge is larger. |
| `always` | Whenever current and target differ. |

Resize SHALL preserve aspect ratio. Processed output SHALL be re-probed for final format, MIME, single-image count and actual width/height; neither axis may exceed `8000`. Temporary extensions follow final format, not source filename.

### Requirement: Ordered preparation facts are observable

Each input's compact facts SHALL give source path, effective detail, dimensions (original→final when changed), actual crop's percentage region, actual resize and applicable normalization/format conversion. Omit duplicate unchanged formats/dimensions and false/no-op flags; never expose base64 or temporary-file content. Images, context IDs, child messages and returned facts SHALL retain input order. Internal preparation retains full format/MIME/region/resize/payload facts for dispatch/cleanup.

## Hidden Child Contract

### Requirement: Child creation preserves the clean parent prefix

After all images prepare, the runtime SHALL snapshot the parent prefix immediately before the calling assistant tool message, excluding that message and batched siblings. One hidden child SHALL inherit adapter/model/settings/cycle/relevant context, the effective tool registry, runtime state needed for legitimate analysis, and read-only conversation history.

Before first submit, registry and request/cancellation guards SHALL remove recursive analyze, multirun, multicall and SubAgent/workflow/multi-agent/handoff/equivalent delegation tools. Retain original command-mode run; reject every tool-mode run before extension/dispatch, blocking indirect delegation/analysis and budget bypass. Prompts cannot replace these guards or alter clean-prefix, configuration-inheritance and isolation guarantees. Experimental multicall safety/routing/evidence: [Chat Builtins](./chat-builtins.md).

### Requirement: A fixed boundary owns child behavior

After the inherited prefix, the runtime SHALL append, in order:

1. A fixed higher-authority analysis boundary.
2. Separate ordered child-only image messages with distinct IDs.
3. One lower-authority task message containing `analysis_prompt`, processing facts, regular `max_steps` and relevant image ordering.

The boundary SHALL treat inherited history as read-only context, not the task; require joint interpretation of ordered images/facts, distinguishing visible evidence, interpretation, uncertainty and unreadable details; prohibit recursive analysis/delegation, clarification and background work; disclose the regular budget plus one empty-response reserve; and require one nonempty final assistant text after relevant tools settle. Dynamic image/task content cannot override it.

### Requirement: Parent and child state remain isolated

No child window/tab SHALL open or flash. Parent focus, current Chat, messages, tool registry and persisted history SHALL remain unchanged. Images SHALL be child-local, never parent result attachments or TTL-managed pixels. The unsavable child SHALL NOT expose a transcript, `save_id`, resumable identity, history entry, fragment, trace payload or recovery entrypoint.

## Request Budget And Completion

### Requirement: `max_steps` counts regular adapter dispatches

A regular step is one child model request dispatched to the adapter: initial request, tool continuation or runtime-dispatched retry. Busy/no-op submissions, deterministic preparation, tool execution and provider-internal retries are outside this counter.

Regular dispatch SHALL stop at `regular_steps_used == max_steps`. The final regular response may finish its already-issued tool batch but SHALL NOT trigger regular request `max_steps + 1`.

### Requirement: Exactly one empty-response correction is reserved

For a current tool-free response without usable assistant text, the runtime SHALL append one hidden nonempty-final-text instruction and dispatch exactly one corrective request outside the regular budget, available even after the first response at `max_steps=1`. It counts in `steps_used`, with `steps_used <= max_steps + 1`. A second tool-free empty response fails with `FINAL_RESPONSE_REQUIRED`; ordinary continuation exhaustion after a tool batch fails with `STEP_LIMIT_EXCEEDED` without consuming this reserve.

### Requirement: Current tool-free assistant text is the only success signal

Only normalized nonblank assistant text from the current child callback with no tool calls may complete successfully. Text accompanying tools is intermediate; inherited messages, earlier request text, reasoning-only output, separately stored messages and historical child content are not completion evidence.

The first terminal latch wins among completion, error, timeout and cancellation. Stale callbacks SHALL neither dispatch work nor overwrite the terminal result.

## Result And Error Contract

### Requirement: Success returns ordered facts and complete raw text

Success SHALL return **Ordered preparation facts are observable** in input order, then `---` and the complete current nonempty final assistant text, without JSON encoding, truncation, summarization or preview-file substitution. Ordinary successful steps_used/max_steps echoes remain internal; budget-related errors retain them. Results SHALL preserve **Parent and child state remain isolated**, parent pixel/history/TTL behavior and preparation-fact restrictions; no generic follow-up tutorial.

Errors SHALL be bounded and identify the owning boundary and applicable image index. Stable leading categories: `INVALID_ARGUMENT`, `CALLER_REQUIRED`, `VISION_UNSUPPORTED`, `IMAGE_PREPARATION_FAILED`, `CHILD_CREATION_FAILED`, `STEP_LIMIT_EXCEEDED`, `FINAL_RESPONSE_REQUIRED`, `MODEL_REQUEST_FAILED`, `CANCELLED`, `TIMEOUT`.

## Async, Cancellation, And Cleanup

### Requirement: Existing wrappers own asynchronous invocation

Analyze has no public async flag. A parent MAY use titled `run(scope="tool", command="analyze", args=<encoded object>, opts='{"async":true}')`, poll with wait and cancel with kill; multirun follows Chat Builtins batch semantics. Target timeout/max_steps/image parameters belong in args, never wrapper opts. Async state is session-local and lost on Neovim restart.

For long-running analysis, callers SHOULD poll nonblocking with `wait(title="Inspect image analysis", async_id="<async_id>", mode="try")` while useful work remains, SHOULD NOT immediately launch async work and block indefinitely, and SHALL cancel abandoned runs.

### Requirement: Every terminal path disposes the hidden child

After active work settles, every terminal path—success, preparation failure after temporary allocation, model failure, step exhaustion, timeout or cancellation—SHALL release owned image bytes, child-only message/context references, temporary processed files, hidden buffer/unsavable state, request handles/callbacks/timers/cancellation hooks and inherited registry/state copies. Terminal callbacks SHALL be idempotent. Cancellation suppresses future continuation and cancels active owned requests/tools where supported, without rolling back already-started external side effects.

## Removed Public Behavior

Absent: the former public `load_image` attachment interface, parent-image payload/TTL workflow, alias, dual rollout and dedicated report/search-style terminal tools. Use `analyze(images={...}, analysis_prompt=..., max_steps=...)` under the input and sole final-text completion requirements above.

## Validation Evidence And Remaining Risk

Historical implementation evidence, subject to the review/provenance note:

| Scope / owner | Passed evidence | Limits retained |
| --- | --- | --- |
| LLM output projection | Existing analyze preparation/terminal checks (17/17), syntax, fresh actual single-image raw-text return using an existing repository screenshot; ordered processing facts, no parent attachment. | Steps/controller logic unchanged; broader live limitations below unchanged. Human review not-run for this projection change. |
| Unified wrapper execution | Focused hidden/tool-scope guard and cooperative async/cancel checks; fresh-Neovim real run→analyze returned nonempty text, max_steps=1/steps_used=1 and ordered metadata through the sole wrapper async_id. | Existing controller lifecycle/format coverage below was not rerun or expanded; human implementation review not-run. |

Focused validation passed for schema/ordered input, repeated paths, mixed per-image options, invalid later items, format preparation, crop-before-resize, ordered metadata, hidden no-window/no-history behavior, final text at step one/N, text-plus-tools, final regular tool batch, one empty correction, second-empty failure, timeout/error/cancellation races, cleanup, stale-callback suppression and controlled real-Chat integration.

Human specification review passed by user confirmation on 2026-09-15. The consolidated lifecycle's broader live matrix—multi-step operation, cancellation, history/trace absence and focus invariants—was not fully run. These remain runtime regression risks and SHALL NOT be relabeled passed.
