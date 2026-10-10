---
title: Project Vault 布局、所有权与治理规格
created: 2026-06-28
updated: 2026-10-09
type: source
doc_role: spec
authority: accepted
status: active
capability: project-vault
sources:
  - .maxa/AGENTS.md
  - .maxa/index.md
  - .maxa/_meta.yaml
  - .maxa/.stignore-shared
  - .maxa/.obsidian/app.json
  - abilities/project-admin/SKILL.md
  - abilities/project-admin/references/source-layer-model.md
  - abilities/project-admin/references/knowledge-vault.md
  - abilities/project-admin/scripts/project_vault_ownership.py
  - abilities/project-admin/scripts/project_knowledge_vault.py
  - abilities/project-admin/scripts/project_knowledge_sync.py
  - abilities/project-admin/references/knowledge-governance.md
  - abilities/session/scripts/trace_visualize.py
  - abilities/session/tests/test_trace_visualize.py
  - user-review:2026-09-22
confidence: high
---

## Purpose And Ownership

`.maxa/` is the project-local Obsidian Vault and Maxa workspace root. This owner defines layout/routing, ProjectAdmin structure operations, Obsidian knowledge governance, checkout eligibility, external setup and project-only plugin/config distribution. Other stable specs SHALL reference, not redefine, these contracts.

## Requirements

### Requirement: `.maxa/` is the only active project Vault root

- Knowledge operations MUST resolve to `<PROJECT_ROOT>/.maxa` from the selected project root, without requiring or using metadata `vault_root`. Whole-Vault symlinks or resolved paths outside the project fail closed. Retired `<PROJECT_ROOT>/.maxa/knowledge` (`.maxa/knowledge/`) MUST NOT be created, active, an alias or a fallback. The previous brand-root directory is not a reader fallback.
- `.maxa/_meta.yaml` MUST contain `schema_version`: absent means legacy `0`; root layout remains version `1`. Runtime reads only this version key, compares it with the mother runtime's `.version` through the [shared runtime version reader](../../../runtime/maxa-ai.md#requirement-runtime-version-has-one-mother-project-source) and retains the existing lower/higher/invalid-version outcomes, without old-key fallback or automatic metadata rewrite. Child projects do not need a `.version` file.
- Root `raw/` remains retired; evidence belongs to semantic owners such as `research/`, `reports/`, `attachments/`, `canvases/`, or a separately governed root category.

### Requirement: Baseline project metadata retains meaningful identity and provenance

ProjectAdmin's baseline `_meta.yaml` SHALL contain only `name`, `schema_version`, `created`, `syncthing_folder_id` and `abilities`. `created` records the initial creation date/time and SHALL survive ordinary settings/governance updates unchanged. This instance cleanup SHALL preserve existing name, creation timestamp, Folder ID and Ability state values. Runtime-supported optional settings remain governed by [Project configuration](../../../runtime/plugin-entrypoints.md#requirement-project-configuration-reuses-existing-metadata); baseline simplification SHALL NOT disable them or impose a closed metadata whitelist. Governance generation SHALL NOT restore removed descriptive metadata or `vault_root`.

### Requirement: Initialized and optional roots have explicit ownership

Initialized projects SHALL provide `inbox/`, `specs/`, `weave/`, `tasks/`, `drafts/`, `translate-cache/`, `attachments/` and `canvases/`; optional `ideas/`, `reports/`, `research/`, `rules/` or another explicitly governed semantic category SHALL exist only for actual content. Maintained root knowledge categories SHALL have `index.md` and `log.md`; workspace zones retain separate ownership. Existing article-oriented layouts require explicit migration, not an init/sync rename or a parallel generated layer.

### Requirement: Entry and index routing is progressive

The Agent entry chain SHALL be:

```text
.maxa/AGENTS.md -> .maxa/index.md -> direct root-zone index -> direct child index or owned file
```

- `.maxa/AGENTS.md` is the low-context project contract and SHALL NOT contain note catalogs, task progress, drafts or one-off logs.
- `.maxa/index.md` owns whole-Vault routing; content indexes, `weave/index.md`, `specs/index.md` and `inbox/index.md` own next hops. Parent indexes SHALL link only direct child indexes or owned files, explain why/when to read them and avoid duplicate deep inventories. Weave is an optional query entry, not a completeness or authority gate.
- Discoverability or durable behavior changes require updates to the nearest index and owning root `log.md`.

### Requirement: Vault zones retain separate semantics

| Zone | Ownership and routing |
| --- | --- |
| `weave/`, content categories, `specs/`, `inbox/` | LLM-maintained derived topic/concept views; actual articles/evidence; SpecAdmin behavior contracts; pending captures/feedback, respectively. Weave is not article intake, copied full text or authoritative behavior. |
| `tasks/`, `drafts/`, `translate-cache/` | Vault-visible workspace, not ordinary knowledge. TaskAdmin owns `tasks/`: read directly, without duplicate knowledge/TODOseq exports. The other two may be Git-ignored while remaining Obsidian/Syncthing-visible. |
| `abilities/`, `fragments/`, `tmp/`, `upload/`, `artifacts/`, `handoff/`, `e2e/` | Runtime/support outside ordinary knowledge routing; owning configuration determines Git, Obsidian and Syncthing visibility. Ability placement/access is defined below. |

- **MCP configuration**: `.maxa/abilities/mcp.json` is project-local runtime configuration outside knowledge routing, covered by existing root-anchored `abilities` Syncthing/Obsidian runtime exclusions. Retain `/mcp.json` in shared Syncthing rules as a legacy guard; this does not imply Git exclusion or automatic migration of other projects.
- **Legacy zone**: Retired `.maxa/skills/` SHALL be reported as invalid, not accepted as an alias.
- **History sync**: Raw `.maxa/history/` is runtime-only and Syncthing-ignored by default. The sole controlled exception, `.maxa/history/traces/<root_trace_id>/visualization/**`, SHALL keep generated Markdown/Canvas available across Vault clients. In `.maxa/.stignore-shared`, `!/history`, `!/history/traces`, `!/history/traces/*`, `!/history/traces/*/visualization`, `!/history/traces/*/visualization/**` SHALL precede `(?d)/history` and `(?d)/history/**` without exposing raw chats, `manifest.json`, `events.jsonl`, `index.json`, `archives/` or unrelated history files.
- **History visibility and routing**: Current `.maxa/.obsidian/app.json` does not broadly filter `history`; generated visualization remains openable by known Vault paths. It is runtime review data, not knowledge, and needs no per-export specs/knowledge index or log update. Raw chats/events and other history remain outside knowledge indexes and ordinary Agent routing despite local filesystem/Obsidian access.
- Git ignore, Obsidian visibility and Syncthing ignore are independent contracts; one SHALL NOT be inferred from another.

### Requirement: Project-local Ability packages use `.maxa/abilities/`

- **Placement and creation**: Project-specific packages SHALL live only at `<project>/.maxa/abilities/<ability>/`. Only an existing authorized package warrants this optional runtime/support root: `ability-creator` creates `.maxa/abilities/<name>/` for a user-authorized project-owned Ability. ProjectAdmin init/sync SHALL NOT create the root speculatively; `ability-creator` SHALL NOT create a `.maxa/skills/` alias.
- **Visibility and access**: Exclude `.maxa/abilities/` from ordinary Obsidian graph/search, knowledge indexes and Syncthing knowledge distribution; it needs no knowledge `index.md`/`log.md`. Resources remain reachable through Ability tooling and authorized file operations.

### Requirement: Vault routing names Ability support zones accurately

Root indexes/rules, ProjectAdmin templates and ignore policies SHALL identify `abilities/` as runtime/support, not knowledge. Durable content follows semantic owners; `weave/` provides derived navigation and relationships.

### Requirement: Durable knowledge remains project-local and traceable

- Knowledge SHALL remain in the current repository's `.maxa/`, with no global/cross-project Vault. Durable notes SHALL follow project conventions for semantic title, provenance, links, nearest index and log. Queries SHALL progressively select full notes from indexes, reading raw/source evidence only when required.
- Lint/health is diagnostic by default. Rename, move, archive, delete, merge, bulk rewrite, feedback processing and source migration require explicit authorization.
- TaskAdmin plan/TODO/supporting documents, temporary output and secrets SHALL NOT be promoted to knowledge automatically.

### Requirement: Weave nodes are bounded source-backed retrieval views

Complete UTF-8 files, including metadata/links, SHALL meet: indexes <= 2048 bytes; topics SHOULD be <= 4096 and SHALL be <= 6144; concepts <= 3072. Logs are chronological records, not routine query inputs; keep an active log <= 6144 bytes and rotate older entries outside the retrieval route. Ordinary knowledge-note limit remains 30000 bytes; bytes are not a model-independent token count. Remove duplication/detail before semantic splitting; do not mechanically create one node per article/term. Minimal metadata SHALL identify semantic title, node type, update date, status and concrete source links; aliases are optional.

### Requirement: Weaving and retrieval preserve permission and evidence

Only a user-requested weave/update/repair/rebuild mutates generated nodes; query/check/ingest/capture does not implicitly weave. Human corrections go to content/feedback; detected manual generated edits are reconciled without blind overwrite. Each meaningful claim/relationship traces to observed sources, distinguishes support/example/limitation/conflict/history and respects current authoritative owner/status. Derived-to-source links create source backlinks; do not duplicate inverse lists. Topic-first and source-first bounded retrieval SHALL remain available; filter structural backlinks and expand only relevant neighbors. Source changes/deletions invalidate dependent conclusions until checked; generated summaries never grant runtime authority. Eligible live graph operations use guarded exact-target Obsidian dispatch; unavailable/ineligible graph checks remain explicitly file-only without alternate-Vault fallback.

### Requirement: Explicit content migration retires the old generated area

Before retirement, classify each old document by full semantic content, preserve useful unique articles in content owners, regenerate only useful navigation and reconcile affected links/metadata/indexes. Keep obsolete conclusions historical or superseded, not current instructions. Preserve Vault/task identity, schema version and task/chat/Git history. Completed cutover SHALL retain no old directory, compatibility navigation or dedicated old-area archive. Redundant landings, logs/templates may be removed only after necessary knowledge/provenance is preserved. Record source preservation and scoped live/file validation in execution evidence; do not require fixing unrelated pre-existing Vault issues.

### Requirement: Obsidian plugin/config distribution does not create shared knowledge

The current project's `.maxa/.obsidian/` supplies maintained runtime plugin/config distribution. Project-local scripts/recipes MAY retain names such as `sync_dev_plugins_to_project_vault.py`, `sync_project_plugins.py`, `sync-obsidian-plugins` and `distribute-obsidian-plugins`; these imply no global Vault.

Distribution SHALL copy only allowlisted `.obsidian/` runtime assets, exclude the source Vault and preserve target-local secret-bearing `data.json` unless explicitly allowlisted; it SHALL NOT sync Markdown knowledge. No command SHALL default or fall back to `~/obsidian-vault/`.

### Requirement: Checkout topology governs external operations

ProjectAdmin SHALL classify the explicitly selected project using verified Git topology and physical path identity:

| Kind | External eligibility and local boundary |
| --- | --- |
| `primary` or positively established non-Git `standalone` | Eligible for Obsidian registration/CLI and Syncthing registration/management/manual scan. |
| `linked` | Independent file reads/writes/searches and file-side checks remain available; external operations are ineligible. SHALL NOT redirect to primary, borrow its graph evidence, register another identity or link/copy the whole Vault to bypass policy. |
| `unresolved` | Fail closed externally; safe local file work may continue. |

Read-only `status` SHALL expose `checkout_kind`, `external_ops_allowed`, `primary_checkout_path`, `ownership_error`. For ineligible projects, it SHALL NOT contact external services: external facts are null/uninspected and `graph_ops_ready` is false.

### Requirement: External setup and use are separate

| Operation | Contract |
| --- | --- |
| `project_knowledge_vault.py ensure` | Explicit setup; same-physical-target registration is idempotent. Conflicting, dangling, obstructed or differently targeted registration SHALL fail without retargeting/repair. |
| `project_knowledge_vault.py exec -- ...` | SHALL verify the existing physical target and prepend the explicit Vault selector; SHALL NOT call `ensure` or create registration. |
| `project_knowledge_sync.py ensure\|scan` | SHALL check ownership before marker/ignore/config writes or platform calls. |

WSL/Linux-native projects use WSL Syncthing; Windows-mounted projects use Windows Syncthing. The same project SHALL NOT register on both sides. Manual scan requires an explicit force/immediate/manual-scan request; ordinary edits rely on the owning filesystem watcher.

### Requirement: ProjectAdmin operations preserve their boundaries

- `init`: minimal version-1 root skeleton.
- `sync`: repair current structure through the complete ordered workflow.
- `migrate`: report-driven review of non-versioned legacy/custom layouts.
- `upgrade`: documented schema upgrades in ascending order; update version only after validation.
- `scaffold`: content only in an existing or explicitly requested semantic category; update nearest index/log.
- Linked Worktree local governance may complete with external steps explicitly not applicable. Unresolved required external work is blocked, not falsely passed.

### Requirement: Current-project maxa naming migration

- **Vault naming preserves active state**: The approved physical root move MUST preserve knowledge, specs, TaskAdmin tag/integer IDs, baseline creation timestamp, Vault name, Syncthing Folder ID and Ability settings, including existing user edits. The entry chain becomes `.maxa/AGENTS.md` → `.maxa/index.md` → owned indexes/files. Project-local Ability/MCP placement becomes `.maxa/abilities/`, including `mcp.json`; visibility/ownership/ignore conditions remain otherwise unchanged. Apply [Maxa AI Runtime](../../../runtime/maxa-ai.md) naming rules to all retained root-path clauses and references without redesigning the layout or schema.

- **Scoped external registration migration**: Only verified current-project eligible registrations/aliases may be retargeted to the renamed physical Vault. Preserve existing identity and fail explicitly on conflicts; ordinary `ensure` is not implicit repair authority. Pause this folder's local syncing during the switch; other project/device registrations remain untouched. Normal watching may resume after the local target is verified; no forced scan is implied.

- **Local plugin publication only**: Rename/build affected first-party plugin runtime assets for this project's `.maxa/.obsidian/` only, preserving local secret-bearing `data.json`. Do not invoke recipes that discover/distribute to other projects or synchronize Markdown knowledge as plugin configuration. Existing third-party plugin identity remains unchanged.

## Validation And Review State

- **Knowledge weave passed (2026-10-10)**: Passed checks cover updated Ability/catalog, 2 byte-boundary and 6 guarded-wrapper checks, 44 preserved full content bodies, 63 parsed frontmatter/source lists, 18 within-budget generated files and actual source backlinks/node links/scoped search. New weave unresolved maps and ordinary old-area targets are empty; no compatibility directory/archive remains. Human implementation review not-run; historical source runtime/UI/API behavior was not revalidated. Vault identity/schema and unrelated pre-existing issues remain unchanged.

- **Mother version source passed (2026-10-09)**: Passed checks cover 16 focused version/schema/setup checks and fresh-Neovim observation: mother `.version`, API string `"1"`, project/runtime schema `1` and status `ok`. Human review remains not-run; unrelated legacy smoke fixture failure remains recorded.

- **Metadata simplification passed (2026-10-08)**: Passed checks cover 22 focused Vault/ownership/wrapper checks, 6 schema checks, 10 existing settings-persistence checks, exact baseline/provenance assertions and fresh-Neovim schema/metadata/Ability validation. Read-only Vault `name|path` and sync `folder-id` retain original targets. Human implementation review remains historically not-run. No external setup, forced scan or full Windows service integration.

- **Automated passed**: version-1 layout and ProjectAdmin ownership; ProjectAdmin/Git Workspace tests, Ability description lint, shell/help checks, `.maxa/abilities/` ignore/ownership checks, Windows physical-directory identity fixtures, read-only primary Obsidian/WSL Syncthing checks.
- **2026-09-16 MCP exclusion passed**: four focused `project_knowledge_sync.py` tests, Python compile checks and static checks of `.maxa/mcp.json` exclusion against current shared rules and reusable ProjectAdmin asset. No forced Syncthing scan ran.
- **Human specification review passed**: explicit user declaration on 2026-09-22, including the hard-cut `.maxa/abilities/` zone.
- **Trace-visibility passed**: ordered Syncthing includes/ignores keep generated `visualization/trace-summary.md` and `trace-overview.canvas` syncable while representative raw `events.jsonl` and Chat history stay ignored.
- **Not run**: full Windows Syncthing service integration; separate live Agent-behavior acceptance suite. No live registration repair, forced scan or downstream state repair is implied. Missing live/platform checks remain implementation risks, not permission for fallback, silent retargeting or dual registration.

## Source Trace

- Layout/entrypoints: `.maxa/AGENTS.md`, `.maxa/index.md`, `.maxa/_meta.yaml`.
- Visibility: `.maxa/.stignore-shared` (including `/mcp.json` exclusion), `.maxa/.obsidian/app.json` (Obsidian local ignore).
- Governance and knowledge workflows: `abilities/project-admin/`.
- Trace generation/ignore validation: `abilities/session/scripts/trace_visualize.py`, `abilities/session/tests/test_trace_visualize.py`; runtime contract: [[specs/abilities/base/session/session-tools|Session Trace Visualization]].
