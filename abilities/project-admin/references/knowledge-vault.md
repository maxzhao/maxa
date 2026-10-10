# Project Root Vault Governance

Purpose: define project-local `.maxa/` Vault governance for ProjectAdmin init/sync/migrate operations.

## Vault root

- Project-local Vault root: `.maxa/`.
- Metadata: `.maxa/_meta.yaml`.
- Schema field: `schema_version`; runtime reads no former version-key alias.
- Missing `schema_version` means version `0`.
- Version `1` means root Vault layout with `AGENTS.md`, root routing index, required initialized directories, and retired `.maxa/knowledge/`.

## Metadata

Use `assets/project-knowledge-meta.yaml` for the baseline fields: `name`, `schema_version`, `created`, `syncthing_folder_id`, `abilities`. Set `created` at initialization and preserve it on updates. Preserve supported optional runtime settings; do not add removed descriptive fields during init/sync. Vault/Sync scripts derive the fixed `<PROJECT_ROOT>/.maxa` path from the selected project root, not metadata.

Version-field replacement is a hard cut: update affected project metadata and runtime together. Preserve the previous authoritative version when explicitly renaming it; no reader fallback or automatic cross-project rewrite is provided.

## Required initialized directories

ProjectAdmin `init` MUST create:

```text
inbox/
specs/
weave/
tasks/
drafts/
translate-cache/
attachments/
canvases/
```

For required maintained knowledge directories, also create `index.md` and `log.md`:

```text
inbox/index.md
inbox/log.md
specs/index.md
specs/log.md
weave/index.md
weave/log.md
attachments/index.md
attachments/log.md
canvases/index.md
canvases/log.md
```

`tasks/`, `drafts/`, and `translate-cache/` are required Vault-visible workspace zones but do not follow ordinary knowledge-note indexing unless their owning workflow defines it.

## Optional root categories

Do not create by default:

```text
ideas/
reports/
research/
rules/
```

Create only when actual project content requires them. Once created, each optional category must have `index.md` and `log.md`.

## Entry chain

```text
.maxa/AGENTS.md -> .maxa/index.md -> weave/index.md or content category indexes
```

Capture/review must be reachable through:

```text
.maxa/inbox/index.md
```

## Root routing, content and weave

- `.maxa/index.md`: whole-Vault router selecting content, weave or workspace zones.
- Content categories own articles/evidence/contracts; `weave/index.md` routes compact LLM-derived topics/concepts. Apply `references/weave.md` for budgets, retrieval and maintenance.
- `weave/log.md`: bounded maintenance record, not a routine retrieval input. Root `log.md` / `log/` are not part of the layout.
- Existing `.maxa/wiki/` requires explicitly authorized `references/wiki-to-weave.md` migration. Init/sync never rename content or create parallel old/new knowledge trees; report pending migration before dependent skeleton repair. Completed migration retains no old directory/compatibility router or dedicated archive. This content-layout change preserves `schema_version` and Vault identity.

## Progressive discovery

- Every maintained knowledge directory should have `index.md`.
- Parent indexes route only to direct child indexes or directly owned files.
- Parent indexes must not duplicate deep child index content.
- Every maintained root-level knowledge directory must have `index.md` and `log.md`.
- Indexes must contain Agent-useful summaries (purpose, when to read, status/ownership), not filename-only lists.

## Retired paths

- `.maxa/knowledge/` retired.
- Root `raw/` retired.
- `.maxa/knowledge/tasks/` TaskAdmin export output retired.

## Ignore governance

Separate contracts:

- Git ignore: repository persistence.
- Obsidian ignore: graph/search visibility.
- Syncthing ignore: cross-device publication.

Rules:

- `drafts/` and `translate-cache/` may be Git-ignored while remaining Obsidian/Syncthing visible.
- Project-local MCP runtime configuration lives at `.maxa/abilities/mcp.json`, covered by the root-anchored `abilities` Syncthing/Obsidian runtime exclusion. Retain `/mcp.json` in shared Syncthing rules as a legacy guard; this does not imply Git exclusion or automatic migration of other projects.
- `abilities/`, `fragments/`, `tmp/`, `upload/`, `history/`, `artifacts/`, `handoff`, and `e2e/` are ignored by Obsidian/Syncthing by default.
- Retired v0 path `knowledge/` is ignored by Syncthing with root-anchored `(?d)/knowledge` and `(?d)/knowledge/**` guards.
- Shared Syncthing rules live in syncable `.stignore-shared`; local `.stignore` contains exactly `#include .stignore-shared` because Syncthing does not synchronize `.stignore` itself.
- Bootstrap `.stignore` on every newly joined client before opening/writing the Vault; otherwise that client can publish device-local files before the shared rules take effect.
- `.stignore-shared` rules for ignored root directories must use root-anchored patterns for both the directory entry and contents, for example `(?d)/abilities` plus `(?d)/abilities/**`. Do not use only `abilities/`, because that may leave empty directories on other devices.
- Obsidian workspace/cache/trash and Syncthing runtime/version folders remain local/runtime state.

## Checkout Ownership And External Operations

ProjectAdmin owns this rule for every project Vault; other Abilities route here rather than invent workspace-specific identities or permissions.

- Only Git's verified primary non-bare checkout or a positively established independent non-Git project may register a Vault, execute project Obsidian commands, manage Syncthing registration, or request a manual scan. Branch names, `.maxa/workspaces.yml`, and runtime selectors do not grant permission.
- Linked Worktrees keep independent `.maxa/` files. Use file tools for local reads/writes/searches/checks; do not redirect to the primary checkout, borrow its graph evidence, create another Vault identity, or symlink/copy a whole Vault to bypass ownership.
- `status` reports `checkout_kind` (`primary|linked|standalone|unresolved`), `external_ops_allowed`, `primary_checkout_path`, and `ownership_error`. Linked/unresolved status does not contact services; external facts are null (uninspected), not failed registration checks.
- Direct `ensure|exec|scan` operations reject ineligible projects before local or external setup effects. Git discovery failure is `unresolved`, never permission to assume the current directory is primary/non-Git.
- Explicit `ensure` performs setup. `exec` never registers: it verifies the live physical target and then dispatches with an explicit Vault selector. Same-target setup is idempotent; conflicting/dangling aliases and Folder IDs fail without retargeting, including historical layout paths. Repair requires separately authorized work.
- In Agent `init/sync/migrate/upgrade` workflows, continue safe local structure/metadata/ignore/index/rule steps in linked Worktrees and mark external steps not applicable by policy. Unresolved ownership blocks required external work; report partial coverage rather than claiming external validation passed. No automated governance executor is introduced.
- New Worktrees acquire no registration. Git-tracked knowledge crosses checkouts through explicit Git integration; ignored drafts/cache remain local. Primary ordinary Syncthing watching remains automatic and no post-edit/create/merge forced scan is added.

## Syncthing ownership

Project Vault sync is owned by the platform where the project path lives:

- WSL/Linux-native project paths are managed by WSL Syncthing.
- Windows-mounted project paths such as `/mnt/c/Projects/<name>` / `C:\Projects\<name>` are managed by Windows Syncthing.
- Do not register the same project Vault folder in both WSL and Windows Syncthing.
- `project_knowledge_sync.py status | ensure | scan` follows this owner model. For Windows-mounted projects it uses Windows Syncthing only; it must not use WSL Syncthing as a fallback.
- Forced scan is not routine maintenance. Run `scan` only when the user explicitly asks for force scan, immediate rescan, or manual scan.
- For an authorized migration between owning platforms, back up both Syncthing configurations, register on the target side, validate `path_matches: true`, then remove the old-side registration without deleting project files. Do not manage the same Vault on both sides.

## Validation checklist

```bash
test -f .maxa/AGENTS.md
test -f .maxa/index.md
test -f .maxa/_meta.yaml
for d in inbox specs weave attachments canvases; do
  test -f ".maxa/$d/index.md"
  test -f ".maxa/$d/log.md"
done
test -d .maxa/tasks
test -d .maxa/drafts
test -d .maxa/translate-cache
test ! -e .maxa/knowledge
test ! -e .maxa/raw
```
