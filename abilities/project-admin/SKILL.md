---
name: project-admin
description: "Manage Maxa projects and their project-local Obsidian knowledge Vaults: initialize, sync, migrate and upgrade `.maxa/`; ingest, query and curate content; build, update and check compact LLM knowledge weave; maintain graph links, feedback, TODOseq, Bases, Canvas and Obsidian plugins."
compatibility: Requires Maxa Ability runtime; Python scripts use the package uv project.
---
# Project Admin

Purpose: govern project-level `.maxa/` infrastructure and maintain its Obsidian-backed knowledge. This Ability owns both project governance and project-local Vault operations.

## Shared Boundaries

- `.maxa/` is the current repository's independent Vault and Maxa workspace root. Keep durable knowledge project-local; do not route it to a global Vault or synchronize Markdown notes between project Vaults.
- `references/knowledge-vault.md` owns layout, schema metadata, directory/index/log contracts, checkout eligibility, registration, ignore policy and Syncthing ownership. Read it before structure work or external Vault operations.
- `references/knowledge-governance.md` owns content note, query, ingest, curation, lint and feedback contracts. Content stays in its semantic owner; `references/weave.md` owns compact LLM-generated topic/concept navigation and user-triggered weaving. Ingest/query/check never implicitly weave. Preserve sources and separate fact, inference and open questions.
- Task execution belongs to `task-admin`; `tasks/` is Vault-visible TaskAdmin storage, not ordinary knowledge. Do not copy task plans/TODO/supporting documents or transient execution data into knowledge notes. Drafts use `.maxa/drafts/`.
- Keep project files, migration reports and sync configuration as instance data. Do not promote secrets, local preferences or one-time logs into shared rules.
- Patch target sections and preserve user-authored non-target content. Health/lint is diagnostic by default; movement, rename, archive, delete, merge, feedback processing and bulk repair require explicit authorization.

## Git Preflight

Init and sync MUST complete this gate before project writes; init completes it before routing an existing `.maxa/` layout to sync. Reuse a current result and explicit user decision for the same selected project root; routing does not require a second prompt.

1. Use read-only Git discovery to check whether the selected project is inside a repository; `.git` existence alone is insufficient. Existing repositories, including parent repositories and linked Worktrees, continue without nested initialization. Missing Git or unexpected discovery failures block this gate; do not classify them as non-Git.
2. For a verified non-Git project without an explicit decision, call `ask(mode="choice")`: initialize Git and continue / continue without Git / cancel. Explain that Git history/rollback, branch integration, Git Worktree workspaces and Git-tracked inventories are unavailable without Git. Wait for the decision before project writes.
3. Approval authorizes only `git init` at the selected project root; recheck before initialization and verify discovery afterward. Do not automatically stage, commit or configure remotes. New repositories still need an initial commit for `HEAD`-based workflows. Continuing without Git preserves local init/sync and standalone-project external eligibility. Cancellation stops without project writes.

## External Vault Operations

Apply `references/knowledge-vault.md` before deciding external workflow applicability. Only a verified Git primary checkout or positively established independent non-Git project is eligible. Linked Worktrees use their own files and file-side checks; do not redirect to the primary Vault, borrow its graph evidence, create another identity or bypass rejection with raw/default-Vault CLI commands. Unresolved ownership fails closed externally.

Use read-only `status` for eligibility. `external_ops_allowed: false` is not a registration defect. Explicit `ensure` owns project registration; `exec` verifies the existing physical target and never registers or retargets it. Conflicts require separately authorized repair. File-only health coverage is not live graph validation. Obsidian installation, CLI provisioning and headless service setup belong to the Maxa runtime's root `install.sh`, not this Ability.

Ordinary edits rely on the owning Syncthing filesystem watcher. Run `scan` only for an explicit force/immediate/manual-scan request. Platform selection and registration migration follow `references/knowledge-vault.md`.

## Scenario Router

Load with `load(target="project-admin")`. Read only the selected scenario and its prerequisites. Resolve package references through `#project-admin[/references/...]`; project notes remain ordinary file paths.

| Request | Read / action |
| --- | --- |
| Initialize a new `.maxa/` | `references/init-operation.md`: Git preflight and post-init `.maxa/` sync decision |
| Sync/repair project structure and entrypoints | `references/sync-operation.md`: shared Git preflight, then governance checks |
| Upgrade project governance/schema | `references/upgrade-operation.md`, then the selected version guide |
| Migrate legacy/partial/custom layouts | `references/migrate-playbook.md`; old generated content: `references/wiki-to-weave.md` |
| Weave/update/repair/rebuild knowledge topics or relations | `references/weave.md`; content/evidence prerequisites in `references/knowledge-governance.md` |
| Query/check weave or find related sources | `references/weave.md`; read-only unless repair/persistence requested |
| Migrate wiki to weave | `references/wiki-to-weave.md`; explicit semantic migration, no tree rename |
| Scaffold a source category/note | `references/source-layer-model.md` and the durable note contract |
| Create/audit/slim `.maxa/AGENTS.md` | `references/rules-authoring.md`; template: `assets/rules-template.md` |
| Project commands / Justfile guidance | `references/justfile-guide.md` |
| Retire old parser discovery | `references/parser-retirement.md` |
| Query, ingest, save, curate or lint knowledge | `references/knowledge-governance.md`; diagnostic script examples: `references/vault-operations.md` |
| Organize inbox captures | `references/knowledge-governance.md`, then `references/inbox-curation.md` |
| Repair Agent knowledge reachability | `references/agent-reachability.md` |
| Process/listen to feedback | Feedback Processing in `references/knowledge-governance.md` |
| CLI graph/property/rename/link operations | `references/knowledge-vault.md`, then `references/obsidian-cli.md` |
| Wikilinks, embeds, callouts or properties | `references/obsidian-markdown.md` |
| Bases `.base` / Canvas `.canvas` | `references/obsidian-bases.md` / `references/json-canvas.md` |
| TODOseq authoring/maintenance | `references/todoseq-task-authoring.md`; do not replace TaskAdmin execution |
| Develop/publish self-maintained plugins | `references/obsidian-plugin-development.md` |
| Distribute project plugin/config assets | `references/obsidian-plugin-sync.md`; knowledge notes are excluded |
| Inspect oversized Git-tracked code | `references/large-code-files.md` |

Assets for structure work: `assets/gitignore`, `assets/project-knowledge-meta.yaml`, `assets/project-knowledge-obsidian-app.json`, `assets/project-knowledge-stignore` and `assets/project-knowledge-stignore-shared`; apply their owning governance references before generation.

## Tools And Scripts

| Operation | Entry / rule |
| --- | --- |
| Content, generated nodes and routing indexes | File tools: `read`, `write`, `edit`; preserve semantic ownership, weave byte budgets and progressive discovery |
| Full-text search | Scoped `search` / `rg`; indexes and TLDRs before selected full notes, raw evidence last |
| Live graph/property/rename/link repair | Guarded `project_knowledge_vault.py exec -- ...`; verified eligibility and existing physical target, no raw CLI fallback |
| External registration/sync | Explicit guarded governance scripts below |

If CLI is unavailable or prohibited, local file work remains available. Report unavailable graph/property/rename-link operations explicitly; never substitute another Vault.

Use cataloged scripts through titled `run(scope="tool")`. Start with `args: ["--help"]` when usage is uncertain. Array arguments are literal strings: resolve project/note placeholders first, without shell expansion. Python runs through the owning `uv run --project {root} python {script}` executor.

| Script under `/scripts/` | Purpose / contract |
| --- | --- |
| `project_knowledge_vault.py` | `name`, `path`, `alias-path`, `status`, explicit `ensure`, verified `exec` |
| `project_knowledge_sync.py` | `folder-id`, `status`, explicit `ensure`, user-requested `scan`; single owning platform |
| `vault_health.sh` | Diagnostic health check; `--project-root`, optional `--quick`; linked Worktrees automatically file-only |
| `graph_neighbors.sh` | Verified outgoing/backlinks; `[--project-root PROJECT_ROOT] <note-name>` |
| `vault_stats.sh` | Scale, directories and recent changes for `<VAULT>` |
| `note_titles.py` | Paths, semantic titles and naming-rule issues |
| `vault_doc_sizes.py` | Complete-byte diagnostics: ordinary notes and smaller weave role budgets; evidence/workspace exemptions |
| `inbox_curation.py` | Inventory/report/mark-merged/validate; semantic decisions remain with the Agent |
| `watch_feedback.py` | Pending feedback listing/waiting; use the feedback lifecycle |
| `sync_dev_plugins_to_project_vault.py` | Publish runtime plugin assets to real current-project Vault directories |
| `sync_project_plugins.py` | Distribute allowlisted `.obsidian/` assets, excluding source Vault and Markdown knowledge |
| `list_large_code_files.py` | Git-tracked code inventory via `scc`; use the large-code-file reference |

`scripts/project_vault_ownership.py` and `scripts/project_vault_cli.sh` are internal helpers, not callable Agent entrypoints. Plugin distribution uses `scripts/obsidian_plugin_sync_allowlist.json`; secret-bearing `data.json` stays target-local unless explicitly allowlisted.

```yaml
# Read-only eligibility and registration inspection
- title: "Inspect project Vault status"
  scope: tool
  command: "@project-admin:/scripts/project_knowledge_vault.py"
  args: ["--project-root", "<PROJECT_ROOT>", "status"]
# Eligible, already registered project only
- title: "Inspect project note backlinks"
  scope: tool
  command: "@project-admin:/scripts/project_knowledge_vault.py"
  args: ["--project-root", "<PROJECT_ROOT>", "exec", "--", "backlinks", "file=index.md"]
# Script discovery without operational effects
- title: "Inspect Vault health help"
  scope: tool
  command: "@project-admin:/scripts/vault_health.sh"
  args: ["--help"]
```

## Execution And Completion

- Select `upgrade` before `sync`/`migrate` for requested version/layout upgrades. Use migration when no documented upgrade applies or the selected guide delegates legacy handling.
- Execute the selected workflow's numbered steps. File/keyword existence or script `status` proves only the corresponding check, not a paragraph-level content audit.
- For governance workflows, map steps to `completed / not applicable / blocked / not completed` with evidence. Report partial completion when required work remains unexecuted.
- Before writing project facts into `AGENTS.md`, inspect current source-of-truth manifests, commands, app/runtime/deploy/database configurations and indexes as relevant. Keep `AGENTS.md` English and L0; reconcile intended policy with actual configuration.
- Knowledge operations maintain provenance, nearest indexes and owning logs, then validate frontmatter/links/reachability. Query-only synthesis is saved only when requested; ask before persistence otherwise.
- Runtime-affecting plugin changes require build/syntax check, publication to the current project Vault and runtime-file verification unless the user explicitly requests source-only work. Follow the plugin development reference; dry-run is not closeout.
- Validate only the changed behavior and selected operation. Structure acceptance is in `references/knowledge-vault.md` and the operation guide; durable knowledge acceptance is in `references/knowledge-governance.md`. Report exact blocked checks and file-only/live-graph coverage separately.
