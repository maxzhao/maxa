# maxa

> maxa project-level supplemental rules. Priority is lower than the main system prompt, Skill Gate, tool-safety rules, and loaded skill instructions.

> **对外品牌定位**: An all-in-one developer agent harness that turns Neovim into your
> agentic IDE. This file is the internal engineering rulebook; the external positioning
> above is what public-facing docs (README/description) must reflect. Internal details
> here (SuperMax/CodeCompanion baseline, `NVIM_APPNAME` isolation, `specs/` evidence) are
> engineering facts for agents and are intentionally not exposed in outward-facing copy.

## Project Scope

- Purpose: spec-driven engineering project whose target is a maxa replacement runtime built **inside** this LazyVim/Neovim mother repository. The runtime will eventually replace CodeCompanion and MCPHub; it is built greenfield here (the repository does not currently contain codecompanion/mcphub/hook sources). Current deliverable is the draft specification and the seven-phase implementation plan under `.supermax/specs/`; the runtime code is not yet implemented. `.supermax/` belongs only to this development mother repository; a completed runtime must use the target project's `.maxa/` directory and must not depend on this repository's `.supermax/`.
- Development boundary: this root is a real **git** repository (LazyVim starter harness with `init.lua`, `lua/config/*`, `lua/plugins/*`). It is a self-contained harness, not a Neovim plugin and not the user's active `~/.config/nvim`. The maxa runtime will be added under `lua/maxa/runtime/...` (managed by the SuperMax development environment) and is validated in isolation via `NVIM_APPNAME=nvim-maxa`; it MUST NOT touch `~/.config/nvim`.
- Normative source-of-truth upstream evidence lives under `specs/` (pinned to the CodeCompanion `v18.7.0` baseline commit `558518f8d78a44198cd428f6bf8bf48bfa38d76d`). `history/` is maxa runtime local history, not project source.

## Project Root: `~/maxa`

## Repository Map And Agent Routing

- `.supermax/specs/` — CodeCompanion reverse-spec and SuperMax target-spec draft. All spec content is `authority: draft`; nothing may be treated as accepted stable spec until reviewed or validated. Read `specs/index.md` first (reading order and module status), then `specs/baseline.md` (evidence priority), `specs/log.md` (change history), and `specs/final-audit.md` (cross-module audit and blockers).
  - Key target documents: `specs/module-disposition.md` (retained/redefined/removed classification), `specs/modules/target-scope/spec.md` (normative scope and removed items), `specs/implementation-sequence.md` (seven dependency-ordered phases and gates), `specs/validation-matrix.md` (the executable fixture acceptance matrix).
  - Validation contracts: `specs/protocol-fixture-contract.md` (four-protocol request/stream/tool/usage/error fixtures) and `specs/runtime-fixture-contract.md` (state, cancellation, tools, MCP/Skill, persistence, status/UI/configuration fixtures).
  - Audit/evidence: `specs/evidence-map.md`, `specs/coverage-audit.md`, `specs/final-audit.md`, `specs/current-runtime-source-inventory.md`, `specs/extraction-plan.md`, `specs/hook-replacement-map.md`.
  - Inner modules live under `specs/modules/<module>/{index.md,spec.md}`; module references to the root baseline use `../../baseline.md`; the root `baseline.md` is at `specs/baseline.md`, not under modules.
  - `specs/downstream/` — SuperMax adaptation evidence for current harness hooks/code. `specs/upstream-deltas/v18.7.0-to-19.22.0/` — latest-upstream comparison evidence (labeled, never baseline truth).
  - All references, tags, and frame-trees now use the `specs/` namespace; the legacy `ideas/` naming (`ideas/codecompanion-reverse-spec/...`) is fully retired here. Treat any re-introduced `ideas/` reverse-spec path as stale.
- `.supermax/history/` — development mother-repository SuperMax chat history and caches. Runtime/local data, not source; do not treat as target-project runtime state. The completed runtime stores target-project state under `<project-root>/.maxa/history/`.
- Root source tree today: LazyVim starter harness only (`init.lua`, `lua/config/*`, `lua/plugins/example.lua`). The maxa runtime layout (semantic boundaries from `implementation-sequence.md`) is not yet created:
  `lua/maxa/runtime/{config,protocol,conversation,session,orchestrator,tools,mcp,skills,events,host/nvim,compat}`.
- This root IS a git repository (single `初始化当前项目` commit). There is **no** `justfile` and **no** `justfile.md`; use the raw command when no matching recipe exists.
- `lazy-lock.json` is Git-ignored (generated locally). The CodeCompanion `v18.7.0` entry cited by the reverse spec is traced from the user's real configuration, not from this harness lock.

## Environment And Stack

| Item | Value |
| --- | --- |
| Platform | WSL/Linux-native (project path is Linux native) |
| Harness | LazyVim starter mother repository (git), `NVIM_APPNAME=nvim-maxa` isolated testing only |
| Target system | Neovim 0.11.5 + maxa runtime |
| Upstream baseline | CodeCompanion.nvim `v18.7.0` @ `558518f8d78a44198cd428f6bf8bf48bfa38d76d` |
| Protocol scope | OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, Gemini native |
| Toolchain | nvim 0.11.5 (linuxbrew), stylua 2.4.1 (mason); plenary.nvim `74b06c6` is pinned in the (ignored) `lazy-lock.json` but no test harness is built on it yet |
| Runtime source status | `lua/maxa/runtime/` not yet created; greenfield build, no codecompanion/mcphub here |

## Commands And Validation

- Before shell commands, follow the current session Justfile check rules. This project has **no** `justfile` and **no** `justfile.md`; use the raw command when no matching recipe exists.
- This root IS a git repository, so `git diff --check` is runnable for whitespace validation. No application build/test/lint entrypoints exist yet; the toolchain is verified available (see Environment And Stack).
- Spec-document changes are validated by:
  - full-file reread and evidence check against `specs/baseline.md` evidence-priority rules,
  - `git diff --check` for whitespace/conflict-marker errors,
  - keeping source/behavior claims traceable to the pinned baseline or explicitly labeled `latest-upstream`/`assumption`.
- No application build/test/lint entrypoints exist yet; do not claim a test/harness exists before it does. Future runtime validation must run in isolation via `nvim --headless` under `NVIM_APPNAME=nvim-maxa` and must never load `codecompanion.*`, `mcphub.*`, or `lua/util/hooks/*`.
- After modifying behavior-affecting artifacts, run the closest relevant existing validation; do not report unvalidated changes as complete.

## Execution Boundaries

- `.supermax/tasks/`: TaskAdmin internal storage. Load `task-admin` before task operations.
- `.supermax/drafts/`: temporary draft directory. It is not durable knowledge, task progress, or runtime source storage.
- `.supermax/`: project knowledge growth layer. Read through the entry chain below. Do not write task state or temporary logs into knowledge body text.
- `history/`: maxa runtime local data; do not edit or treat as source.

## Important Notes

- The `specs/` documents are written largely in Chinese with English frontmatter. Keep existing doc language for the content you edit; `AGENTS.md` itself stays English.
- Behavior requirements must trace to the pinned baseline commit, not floating upstream `main`. Never present latest-upstream or inferred behavior as confirmed baseline fact.
- The legacy `ideas/codecompanion-reverse-spec/...` naming was fully replaced by the `specs/` namespace (paths, references, tags) on 2026-08-03, along with removal of an accidental 149-level nested duplicate tree; see `specs/log.md`. Do not re-introduce `ideas/` reverse-spec paths.
- Development is greenfield and isolation-scoped: build the maxa runtime inside this harness only, run manual checks / future validation via `NVIM_APPNAME=nvim-maxa`, and never read/write `~/.config/nvim`. During development, Agents may read `.supermax/` as Agent/knowledge/spec evidence; runtime code MUST NOT use it as a target project's configuration or persistence root. The final project-local runtime root is `.maxa/` (including `.maxa/runtime.yaml`, `.maxa/mcp/servers.yaml`, `.maxa/system.md`, `.maxa/skills/`, and `.maxa/history/`). "Replacing CodeCompanion/MCPHub" is a future compatibility gate, not a current prerequisite.
- No module may move from `status: partial` until its `validation-matrix.md` fixture rows have executable replacement-runtime tests (or an explicitly accepted removal decision). Hook tests validate current compatibility only and never count as replacement passes.

## Project Knowledge Vault

> The project knowledge growth layer is located at `.supermax/`. It is an **independent Obsidian Vault** for project-specific, evolvable, and traceable knowledge. Required initialized root directories are `inbox/`, `specs/`, `wiki/`, `tasks/`, `drafts/`, `translate-cache/`, `attachments/`, and `canvases/`. Optional project-shaped categories such as `ideas/`, `reports/`, `research/`, and `rules/` should be created only when the project needs them. Paths inside the Vault are relative to the Vault root. The project knowledge retrieval chain is used only when required by the main system Skill Gate or loaded skills: start at root `index.md`, then enter `wiki/index.md`, `inbox/index.md`, `specs/index.md`, or existing category indexes as needed. Every maintained knowledge directory should have `index.md`; maintained root-level knowledge directories must have `log.md`; parent indexes route to direct child indexes and must not duplicate deep child index contents. Do not create `.supermax/knowledge/` or root `raw/`. Graph operations must explicitly target the project knowledge Vault; do not rely on the default active Vault. The default synchronization scheme is **Syncthing**. After modifying project knowledge Vault documents or `.obsidian/` plugin configuration, Agents no longer need to force a scan manually. Only when the user explicitly asks to force a knowledge scan, rescan immediately, or trigger a manual scan, run the `project-admin` AgentSkill script: `uv run --project <project-admin skill root> python <project-admin skill root>/scripts/project_knowledge_sync.py --project-root ~/maxa scan`. `project-admin` is not an MCP server; governance scripts must come from shared `project-admin/scripts/`, not from copied scripts under a project root.

---

## Project Knowledge And Source Entrypoints

> `AGENTS.md` is the default loaded L0 context anchor. It points to the knowledge-layer entrypoints. The project knowledge retrieval chain is used only when required by the main system Skill Gate or loaded skills, then starts from the Vault-local root `index.md` and continues to `wiki/index.md`, `inbox/index.md`, `specs/index.md`, or existing category indexes. Important knowledge must be discoverable step by step from `AGENTS.md`, embedded project skill descriptions, or rule entrypoints. Unreachable knowledge should be fixed by adding indexes, links, merging, or archiving; do not leave it as long-term hidden knowledge.

**Context levels**:
- L0 (loaded by default): `AGENTS.md`
- L1 (active reading entrypoint): `index.md`
- L1/L2: `wiki/index.md`, `specs/index.md`, and existing category indexes; capture / feedback review entrypoint: `inbox/index.md`
- L2: child indexes and selected notes under maintained categories
- Retired: `.supermax/knowledge/` and root `raw/`

**Notes**:
- `specs/index.md` is the current active spec/workspace entrypoint (CodeCompanion reverse-spec).
- `wiki/` is the synthesis layer; `inbox/index.md` is the capture/review entry.
- Legacy `.supermax/ideas`, `.supermax/research`, `.supermax/rules`, and `.supermax/specs` are migration-only and not default retrieval entrypoints.
- Graph operations continue through the explicit project knowledge Vault CLI wrapper.

---

## Update Rules

- Update this file when project scope, repository routing, source-of-truth files, command entrypoints, validation methods, knowledge entrypoints, or `.supermax/` governance boundaries change in a stable way.
- When Agents repeatedly make the same project-level mistake and the fix is stable, update this file or add an appropriate knowledge entrypoint.
- Before updating, read the existing content and inspect current source-of-truth files relevant to each new claim; patch only the target section and preserve user-written areas.
- Do not write task progress, temporary debugging state, one-off logs, complete research body text, complete note lists, or draft content into this file. Use TaskAdmin progress, handoff, `.supermax/`, or `.supermax/drafts/` instead.
- Keep this file as an L0 entrypoint. If content becomes long, move low-frequency details into `.supermax/` and keep only a stable summary plus entry paths here.
- Keep Agent-facing project rules dense: prefer stable constraints, entry paths, commands, validation, and ownership over narrative explanation. Preserve exact paths, recipe names, tool names, and validation commands.
- `.supermax/AGENTS.md` must be written in English unless a higher-priority project rule explicitly requires another language.
