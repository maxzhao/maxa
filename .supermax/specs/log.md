---
title: CodeCompanion Reverse Spec Change Log
created: 2026-08-01
updated: 2026-08-03
type: log
---

## 2026-08-03 — Implementation path moved to `lua/maxa/runtime`

- Supersedes the earlier decision to keep `lua/supermax/runtime/...` as the implementation path. Because `maxa` is the product name, the greenfield implementation path under the `~/maxa` mother repository is now `lua/maxa/runtime/{config,protocol,conversation,session,orchestrator,tools,mcp,skills,events,host/nvim,compat}`; there is no `lua/supermax/` source directory.
- Updated the path in `AGENTS.md` (Development boundary, runtime layout, Runtime source status), `plan.md` (objective and phase-0 import-guard directory), and `specs/implementation-sequence.md` (semantic layout tree). SuperMax remains the development environment; development-environment paths that refer to `~/.config/nvim` (`lua/util/hooks/*`, `lua/plugins/ai.lua`) and the `.supermax/` governance directory are unchanged.

## 2026-08-03 — Product/runtime naming aligned to maxa

- Confirmed naming semantics: `maxa` is the product name and the current project name (`~/maxa`); `SuperMax` is the development environment IDE whose mother repository is `~/.config/nvim`. The delivered runtime is the **maxa** runtime, rooted at `<target-project>/.maxa/`.
- Updated product-level "SuperMax runtime/replacement runtime" references to **maxa** runtime in `AGENTS.md`, `plan.md`, and root spec document `title: ` frontmatter:
  - `implementation-sequence.md` → `maxa Runtime Implementation Sequence`.
  - `current-runtime-source-inventory.md` → `Current maxa Runtime Source Inventory`.
  - `validation-matrix.md` → `maxa Target Runtime Validation Matrix`.
  - `hook-replacement-map.md` → `Hook Replacement Map for maxa Target Runtime`.
  - `runtime-fixture-contract.md` → `maxa Runtime Replacement Fixture Contract`.
  - `plan.md` phase-0 gate command → `:MaxaChat`.
- Preserved (development environment / structure identifiers): `.supermax/`, `lua/maxa/runtime/...`, `NVIM_APPNAME=nvim-maxa`, `supermax-configuration`/`supermax_schema_check.lua` module and source identifiers, and all downstream-adaptation `SuperMax coverage/adaptation/downstream` evidence wording. Module `index.md`/`spec.md` titles under `modules/**` remain structural identifiers and were not renamed.

## 2026-08-03 — Development/runtime directory boundary clarified

- The development mother repository's `.supermax/` is Agent/knowledge/specification infrastructure only.
- The delivered runtime uses each target project's `.maxa/` for configuration, prompts, Skills, MCP definitions and history, with isolated acceptance gates prohibiting fallback to development `.supermax/`.

## 2026-08-02 — SuperMax target-spec upgrade started

- User-confirmed target: LazyVim/Neovim mother-repository runtime that eventually replaces CodeCompanion.
- Added target-scope decision: retain Chat, Actions and Commands; remove ACP, inline assistant, workflow runtime, and standalone Neovim command-input Chat mode.
- Restricted normative protocols to OpenAI Chat Completions, OpenAI Responses, Anthropic Messages and Gemini native API.
- Confirmed automatic MCP/Skill tool execution without authorization/approval gates.
- Added draft target modules for state, orchestrator, providers, messages, streams, tools, history, events/status, async lifecycle, `.supermax` configuration, Chat UI, Actions/Commands and built-in MCP/Skill runtime.
- Added `hook-replacement-map.md`; all current hooks remain implementation-required until replacement behavior is validated.
- Removed ACP/inline source modules, downstream notes and upstream-delta files. Restored `actions-extensions` after clarifying that Actions/Commands remain supported.
- Corrected an out-of-scope `.supermax/specs/changes/codecompanion-supermax-target-spec/` write by deleting it; target work remains only in this ideas directory.

## Open gates

- Read/trace all relevant current runtime sources and tests before claiming complete target requirements.
- Materialize protocol fixture details as executable replacement tests.
- Reconcile current slash-command behavior with the retained Actions/Commands contract and removed standalone command-input Chat surface.
- Validate updated links/frontmatter and perform behavior coverage audit.

## 2026-08-02 — Target disposition and fixture pass

- Added `module-disposition.md` to classify retained/redefined, baseline-only, compatibility-only and removed behavior.
- Added `validation-matrix.md` covering four protocols, runtime state/orchestration, tools/MCP/Skill, history/status/configuration and replacement acceptance gates.
- Corrected pinned CodeCompanion Gemini evidence: its adapter uses Google's OpenAI-compatible Chat Completions endpoint; Gemini native remains a new target implementation.
- Added target-disposition boundaries to retained upstream modules and removed stale ACP, inline, approval/permission and standalone command-input Chat requirements from their normative paths.
- Rewrote the retained upstream tool-loop boundary to require target automatic execution with typed error/cancel behavior and no approval UI.
- Added MCP lifecycle evidence for native registration, reload, enable/disable, server-state events and guarded restart.
- Updated TODO, coverage audit and final audit; repaired `message-context/index.md` authority/status metadata.
- Current blocker: replacement implementation and fixtures do not exist. OpenAI Chat Completions, Gemini native, MCP lifecycle, cancellation/late callbacks and persistence remain acceptance gaps.

## 2026-08-02 — Detailed completion pass

- Added `protocol-fixture-contract.md` with common fixture envelope and required request/stream/tool/usage/error/cancel fixtures for all four protocols.
- Added `runtime-fixture-contract.md` with deterministic replacement harness plus state/orchestrator, async, tool, MCP, SkillHook, persistence, spine/UI and configuration fixtures.
- Added `current-runtime-source-inventory.md`; classified hooks, status, MCP roots, SkillHook, history and adjacent repository-wide CodeCompanion/MCPHub consumers.
- Originally defined `.supermax/runtime.yaml` and `.supermax/mcp/servers.yaml`; the 2026-08-03 boundary correction above supersedes those target paths with `.maxa/runtime.yaml` and `.maxa/mcp/servers.yaml`. Configuration precedence/snapshots/failure policy and secret-reference constraints remain.
- Defined prompt wrapper/placeholder/Skill SYSTEM slot grammar, deterministic ordering, duplicate/unbound-slot errors and composition source trace.
- Defined session storage schema version 1, atomic write/index rebuild, legacy migration, concurrency and trace/compaction durability.
- Expanded state, orchestrator, message/context, tool, MCP/SkillHook, event/spine, Chat UI, Actions/Commands and migration contracts.
- Classified legacy display history as superseded, `misc` as removed bucket, and translation/Telegram/status/restart/TaskBrowser/quota consumers by target owner.
- Initial official documentation retrieval failed; after network repair, Context7 retrieved official OpenAI API/OpenAPI, Anthropic SDK and Gemini API sources. Direct web-fetch still failed, but core protocol names/fields/events are now verified and cited.
- Expanded static contract assertions and `git diff --check` passed.
- Added `implementation-sequence.md` with semantic target layout, seven dependency-ordered implementation phases, serial/parallel constraints and cutover gates.

## 2026-08-02 — Official protocol evidence recovered

- Context7 resolved official OpenAI API reference/OpenAPI, Anthropic TypeScript SDK and Gemini API reference with high source reputation.
- Verified Chat Completions request/tool/stream/finish/usage fields.
- Verified Responses ordered SSE and terminal response status values.
- Verified Anthropic message/content-block/tool/input-JSON/usage/stop semantics.
- Verified Gemini native endpoints, request fields, Content/Part/function shapes, prompt blocking, candidates and detailed usage metadata.
- Updated provider and protocol fixture contracts; Gemini native is no longer provisional at specification-field level. Executable fixtures remain the acceptance gate.

## 2026-08-03 — Reverse-spec layout and reference cleanup

- Deleted accidental 149-level nested dup tree `specs/codecompanion-reverse-spec/` (148 byte-identical `baseline.md` copies; all SHA256 `6f49ee...`); authoritative `specs/baseline.md` retained.
- Corrected stale `ideas/codecompanion-reverse-spec/...` path references to their real locations under `specs/`:
  - `extraction-plan.md` sources: `baseline.md`, `evidence-map.md`; artifact-convention tree root → `specs/`.
  - `coverage-audit.md` sources: `evidence-map.md`, `final-audit.md`; scope target `ideas/...` → `specs/`.
  - `downstream/index.md` baseline: `./supermax/ideas/...` → `../baseline.md`.
  - `modules/http-transport/spec.md` sources baseline: absolute `~/.config/nvim/.supermax/ideas/...` → `../../baseline.md`.
  - `modules/bootstrap-configuration/spec.md` sample check path → `.supermax/specs/modules/bootstrap-configuration/...`.
  - `modules/tools-agent-loop/index.md` scope text → `specs/modules/tools-agent-loop/`; reading refs `../baseline.md`/`../extraction-plan.md` → `../../...`.
  - `modules/events-integration/index.md` reading ref `../baseline.md` → `../../baseline.md`.
  - `modules/target-scope/spec.md` baseline `../baseline.md` → `../../baseline.md`.
- Verified all remaining frontmatter/body `baseline.md` references resolve (`specs/baseline.md`, `specs/evidence-map.md`, `specs/final-audit.md`).
- Unified `tags:` entries from `ideas/codecompanion-reverse-spec` to `specs/codecompanion-reverse-spec` in `specs/index.md`, `modules/actions-extensions/spec.md`, `modules/actions-extensions/index.md`; updated the `updated:` date to 2026-08-03.
