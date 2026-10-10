---
title: TaskAdmin 核心行为规格
created: 2026-06-28
updated: 2026-09-30
type: source
doc_role: spec
authority: accepted
status: active
capability: taskadmin-core
sources:
  - prompts/system.md
  - abilities/task-admin/SKILL.md
  - abilities/task-admin/SYSTEM.md
  - abilities/task-admin/references/frontmatter-spec.md
  - abilities/task-admin/references/task-creation-guide.md
  - abilities/task-admin/references/execution-protocol.md
  - abilities/task-admin/assets/plan-template.md
  - abilities/task-admin/assets/todo-template.md
  - abilities/task-admin/scripts/
  - abilities/spec-admin/SKILL.md
confidence: high
review:
  human: passed
  evidence: user-declared-current-change-review-2026-09-21
---

## Scope And Authority

TaskAdmin owns file-first plans, TODO/recovery, metadata, peer dependencies, tags, declarative workspaces, lifecycle evidence and SpecAdmin integration. [[specs/abilities/base/task-admin/browser-ui|TaskAdmin Browser UI]] owns UI; external consumers own environment interpretation/lifecycle.

## Requirements

### Requirement: TaskAdmin is explicitly routed

Only explicit TaskAdmin references, task ID/tag/TODO/current task/next task/task workspace/`resolve_task`, numbered TaskAdmin operations or work clearly from `.maxa/tasks/` activate routing; generic “task” or “fix it” alone do not.

### Requirement: A task is one single-level workspace

Layout under `.maxa/tasks/`: `state.yaml`, `<tag>/_meta.yaml`, and `<tag>/task_NNN/` containing `_meta.yaml`, `plan.md`, `todo.md` and optional linked documents. Core interprets only those three task files; optional documents are not registered types.

Identity: tag + positive integer ID from `task_NNN/` (minimum three digits, no maximum). IDs are tag-unique; duplicate titles allowed. No dotted IDs, parent tasks, subtasks or hierarchy inheritance. `resolve_task.py` returns `tag`, integer `id`, `task_dir`, `meta_file`, `plan_file`, `todo_file`, `exists`.

### Requirement: State and tag metadata are explicit

`state.yaml` owns `currentTag`/`lastSwitched`; tag `_meta.yaml` owns description, timestamps, optional version/default workspace. Tag names allow only ASCII letters, digits, `-`, `_`; all CLI/Lua consumers reject separators/traversal before path construction. `manage_tag.py` owns create/list/copy/switch/delete/rename/workspace mutation, keeps state references valid and copies complete peer workspaces. Empty-store initialization creates valid state and `master/_meta.yaml`; first task ID is `1`.

### Requirement: Ordinary task operations use the current tag

Create/update/delete/dependency mutation/renumber MUST use current tag and reject `--tag` (dependency `fix`: before mutation). Validate/graph/list/next/resolve MAY query another tag. Move MUST use current tag as source, reject `--from-tag`, require `--to-tag` and preserve current state. Explicit tag management retains named targets.

### Requirement: Existing write state is strict

Existing-store ordinary writes MUST reject missing/unreadable/malformed state, invalid `currentTag` or missing current-tag directory/metadata before mutation. First creation MAY initialize master only in an absent/empty store; explicit switch MAY repair state. Read-only fallback unchanged.

### Requirement: Execution and task Markdown edits require the current tag

Before execution/continuation or task Markdown edits, MUST confirm valid state and resolved tag equals current tag; otherwise block without automatic switching. Queries grant no execution permission; scripts do not intercept direct filesystem edits.

### Requirement: TaskAdmin has no external environment dependency

TaskAdmin MUST NOT name/load external workspace abilities or read their configuration; callers own environment constraints.

### Requirement: Task metadata has one script owner

Script-owned task `_meta.yaml`: name, optional description, status (`pending|in-progress|done|review|deferred|cancelled`), priority (`high|medium|low`), integer dependencies, timestamps, optional workspace. Dependencies reference existing same-tag peers; reject missing/self/duplicate/cyclic edges. Ordinary edits affect Markdown bodies only.

### Requirement: Creation publishes a complete task

Allocate maximum peer ID + 1. From prepared nonempty UTF-8 plan/TODO files, build a complete temporary sibling workspace, rename into place; report success only with all required files present. Failure removes the owned temporary workspace. Plan contains goal, scope, sources, facts, approach, decisions, affected paths, risks, acceptance and validation plan; TODO follows the recovery contract below.

### Requirement: TODO is read-before-write recovery state

Read TODO before whole-body replacement. Preserve ordered executable items, current state, changed files, validation, errors, blockers, next action, exact IDs/paths/commands/errors and remaining work—not narrative logs. The execution Agent—not `update_task.py` Markdown parsing—blocks `done` until required TODO, acceptance, validation and external convergence (including required SpecAdmin stable merge/lifecycle convergence) complete or an explicit user-authorized exception is recorded.

### Requirement: Peer dependency and structural operations remain valid

- `next_task.py`: pending/in-progress with done dependencies; priority then integer ID.
- Delete: block outgoing/incoming edges unless force acknowledges/removes them.
- Cross-tag move: block source incoming edges and outgoing IDs absent at destination; force removes/reports only invalid edges, preserving destination-valid ones.
- Renumber/swap rewrites peer dependencies. Move/renumber publication failure restores original directories and dependency metadata.

### Requirement: TaskAdmin is execution-engine agnostic

TaskAdmin has no dedicated handoff protocol and does not select/require/supervise/resume/retry SubAgents, forks, workflows or human executors. Independently selected executors share the plan/TODO/status contract.

### Requirement: Lifecycle events remain task-level

`TaskStarted`, `TaskPhaseChanged`, `TaskCompleted`, `TaskStatusChanged` require complete task ID/tag/title payloads plus required phase/status fields. Status changes affect only the selected task, without parent cascade.

### Requirement: Workspace metadata is optional and declarative

Effective binding: task `_meta.yaml` → tag `_meta.yaml` → none. TaskAdmin owns workspace declaration/mutation and exposes metadata; no path/existence/checkout validation, environment creation/switching or required Ability.

### Requirement: SpecAdmin depends on TaskAdmin in one direction

Persistent SpecAdmin operations create/reuse exactly one linked TaskAdmin task; TaskAdmin remains independently usable without reciprocal dependency. Ownership:

- SpecAdmin: intent, requirements/scenarios, stable behavior, coverage, lifecycle.
- Task plan: implementation design and canonical exact spec-path association. Temporary draft/proposal/delta artifacts cache `taskadmin_tag`/integer `taskadmin_id`; promoted formal specs retain no implementation-task association. Completed task records may reference formal owners without a reciprocal link.
- Task TODO: live implementation/validation evidence; completion follows its gate above.

Read-only spec analysis/review creates no task; new changes create neither `design.md` nor `tasks.md`.

### Requirement: Task files are already Vault-visible

TaskAdmin-owned `.maxa/tasks/` is already Vault-visible; no duplication of plans/TODO/supporting documents into ordinary knowledge notes or automatic promotion to wiki knowledge.

### Requirement: Legacy hierarchy is absent

Absent: old task/progress sidecars, child directories, dotted IDs, promotion/migration scripts, TaskAdmin handoff data and hierarchy-compatible aliases/readers. Recovery only through Git history.

## Validation And Review State

- 2026-09-30 current-tag/independent-metadata: owning-uv suite 28 cases, revised Ability reload, affected CLI help and static independence passed. Environment recovery and detailed results retain their original scope. Later same-day user-declared human review passed without rerunning/changing automated results.
- 2026-09-17 passed: disposable Python suite 14 (tag path rejection, ID 1000, move rollback); Task Browser headless suites 15; Git Workspace suite 10; generated prompt; strict Skill lint; data reset; fresh configured Neovim `TASK_BROWSER_RUNTIME_OK`.
- 2026-09-21: explicit user-declared final human review passed; no separate new interactive Browser run reported.
