---
name: task-admin
description: "Manage and execute single-level file-first TaskAdmin task workspaces under `.maxa/tasks/`, including implementation plans, TODO state, metadata, dependencies, tags, workspace bindings, lifecycle events, and next-task selection."
compatibility: Requires Maxa Ability runtime.
---
# TaskAdmin Ability

Purpose: plan future work and execute single-level task workspaces under `.maxa/tasks/`. TaskAdmin owns implementation plans, TODO/recovery state, metadata, dependencies, tags and necessary completion evidence. Use it for requested managed-task operations, not merely because TaskAdmin is discussed or its guidance is maintained.

Load with `load(target="task-admin")`. Use cataloged scripts through titled `run(scope="tool")`; each YAML entry below supplies run fields. Resolve placeholders (especially project/document paths) before invoking: array `args` are literal CLI strings, not shell expressions, globs, or substitutions.

Python entrypoints retain the owning Ability uv executor: `uv run --project {root} python {script}`. Do not replace it with system Python or shell-run the script for normal Agent execution.

`--project-root` is required. Ordinary task writes use only the current tag in `.maxa/tasks/state.yaml`; switch explicitly before operating on another tag. Read-only list/next/resolve and dependency validate/graph accept optional `--tag`. Move uses the current tag as source and requires `--to-tag`; explicit tag management retains named targets.

TaskAdmin is independent of external environment capabilities/configuration. Workspace fields are declaration metadata only; callers own any external environment constraints. Preserve tag-local integer identity; task titles need not be unique.

Read package references/assets through catalog addresses, for example `read(path="#task-admin[/references/execution-protocol.md]")` or `load(target="#task-admin[/assets/plan-template.md]")`. Relative paths below identify package content, not filesystem load targets. Task documents returned by scripts remain ordinary project file paths.

## Mandatory Routing

| Scenario | Required action |
| --- | --- |
| Execute or continue a task | Call `read(path="#task-admin[/references/execution-protocol.md]")` before implementation. |
| Plan validation or judge completion | Read `references/execution-protocol.md`, especially `Validation Strategy`; it owns primary behavioral validation, regression protection and blocked-check handling. |
| Create/register a task or convert analysis into a task | Call `load(target="#task-admin[/references/task-creation-guide.md]")` first. |
| Need metadata/path/dependency/workspace schema | Call `load(target="#task-admin[/references/frontmatter-spec.md]")`. |
| Execute/continue or edit task Markdown | Require valid current-tag state and matching task tag before edits; follow the execution entry checks. |
| Reconcile TaskAdmin changes created in separate Git branches or Worktrees | Read `#task-admin[/references/workspace-reconciliation.md]` before integration. |
| Need plan/TODO body templates | Read `#task-admin[/assets/plan-template.md]` and `#task-admin[/assets/todo-template.md]`. |

## Creation Readiness

Create tasks for unperformed work, not to record completed work. Specification discussion, writing, revision and acceptance do not themselves require tasks; implementation tasks plan how to realize the specified behavior, not how to write the spec.

Ordinary tasks are implementation tasks. Analyze only enough to fix scope, ownership, approach and minimum acceptance; plan/TODO must be executable without open-ended exploration. Stop when those facts suffice. Create a bounded exploration task only when explicitly requested. `references/task-creation-guide.md` owns creation readiness.

## Workspace Model

```text
.maxa/tasks/
├── state.yaml
└── <tag>/
    ├── _meta.yaml
    └── task_001/
        ├── _meta.yaml
        ├── plan.md
        ├── todo.md
        └── <optional task-owned documents>
```

Invariants:

- one task level only;
- positive integer IDs derived from `task_NNN/`;
- IDs unique only within one tag;
- no dotted IDs, parent tasks or subtasks;
- `_meta.yaml` is script-owned;
- `plan.md` owns stable implementation intent;
- `todo.md` owns live execution/recovery state;
- optional task documents are linked context, not registered document types.

## Standard Task Operation Flow

Always resolve before operating on an ID:

```yaml
title: "Resolve TaskAdmin task"
scope: tool
command: "@task-admin:/scripts/resolve_task.py"
args: ["--project-root", "<PROJECT_ROOT>", "--id", "3"]
```

The result includes `tag`, integer `id`, `task_dir`, `meta_file`, `plan_file`, `todo_file`, and `exists`.

Before execution/continuation or task Markdown edits, verify valid current-tag state and that the returned task tag matches it. Stop on mismatch or invalid state without automatically switching. A cross-tag query is inspection only.

Then:

1. Read `plan.md`.
2. Read current `todo.md`.
3. Read only supporting documents required by those files.
4. Use `update_task.py`, `manage_deps.py` and `manage_tag.py` for metadata mutation.
5. Read TODO before writing its complete updated body.
6. Run relevant validation before completion.

Forbidden:

- hand-editing script-owned YAML during normal operations;
- dotted IDs or manually constructed task paths;
- marking done solely because metadata accepts the status.

JSON output from list/next/create/move/resolve scripts already contains exact paths; use them directly.

## Metadata And TODO Rules

- Status: `pending`, `in-progress`, `done`, `review`, `deferred`, `cancelled`.
- Priority: `high`, `medium`, `low`.
- Dependencies: existing peer integer tasks in the same tag; no self, duplicate, missing or cyclic edges.
- Effective workspace declaration: task value, then tag value, then none; no path/existence/checkout checks or environment changes.
- Existing-store ordinary writes reject invalid/missing state or a missing current tag directory/metadata instead of falling back to `master`; explicit tag switch can repair state. Empty-store creation retains default initialization.
- TODO completion is an Agent-level gate defined by `references/execution-protocol.md`; `update_task.py` does not parse Markdown checkboxes.

Task artifacts are Agent-facing. Keep plan/TODO proportional: goal/scope, necessary inputs, future approach/checklist, minimum acceptance and recovery state. Update completion/check evidence while executing an existing task, not as a retrospective work log. Templates are optional; omit empty sections, duplicate evidence and supplementary documents without a concrete need. Preserve exact IDs, paths, commands, errors, statuses and acceptance criteria.

After implementation and the minimum required checks/state updates, deliver promptly under the execution protocol's completion gate. Do not expand scope with optional tests, reviews, refactors or documentation.

## Script Quick Reference

Start with help when unsure. Select the cataloged script from the table and call its `@task-admin:/scripts/` address with `args: ["--help"]`, for example:

```yaml
title: "Inspect TaskAdmin resolver help"
scope: tool
command: "@task-admin:/scripts/resolve_task.py"
args: ["--help"]
```

| Need | Script |
| --- | --- |
| Resolve ID to task/core-document paths | `resolve_task.py` |
| Publish metadata + prepared plan/TODO | `create_task.py` |
| List/filter tasks | `list_tasks.py` |
| Select next executable task | `next_task.py` |
| Update task metadata/status/workspace | `update_task.py` |
| Add/remove dependencies | `manage_deps.py` |
| Validate/fix/graph dependencies | `analyze_deps.py` |
| Manage tags/default workspace/current tag | `manage_tag.py` |
| Delete one guarded task workspace | `delete_task.py` |
| Move one task between tags | `move_task.py` |
| Move/swap peer integer IDs | `renumber_task.py` |

Common calls (choose the needed operation, not an unconditional batch):

```yaml
# List / next / resolve
- title: "List TaskAdmin tasks"
  scope: tool
  command: "@task-admin:/scripts/list_tasks.py"
  args: ["--project-root", "<PROJECT_ROOT>"]
- title: "Select next TaskAdmin task"
  scope: tool
  command: "@task-admin:/scripts/next_task.py"
  args: ["--project-root", "<PROJECT_ROOT>"]
- title: "Resolve TaskAdmin task"
  scope: tool
  command: "@task-admin:/scripts/resolve_task.py"
  args: ["--project-root", "<PROJECT_ROOT>", "--id", "3"]

# Create from prepared UTF-8 documents
- title: "Publish TaskAdmin task"
  scope: tool
  command: "@task-admin:/scripts/create_task.py"
  args: ["--project-root", "<PROJECT_ROOT>", "--name", "Task name", "--plan-file", "<PLAN.md>", "--todo-file", "<TODO.md>"]

# Metadata / dependencies
- title: "Update TaskAdmin status"
  scope: tool
  command: "@task-admin:/scripts/update_task.py"
  args: ["--project-root", "<PROJECT_ROOT>", "--id", "3", "--status", "in-progress"]
- title: "Add TaskAdmin dependency"
  scope: tool
  command: "@task-admin:/scripts/manage_deps.py"
  args: ["--project-root", "<PROJECT_ROOT>", "--action", "add", "--id", "5", "--depends-on", "3"]

# Structural operations
- title: "Move TaskAdmin task"
  scope: tool
  command: "@task-admin:/scripts/move_task.py"
  args: ["--project-root", "<PROJECT_ROOT>", "--id", "3", "--to-tag", "backlog"]
- title: "Renumber TaskAdmin task"
  scope: tool
  command: "@task-admin:/scripts/renumber_task.py"
  args: ["--project-root", "<PROJECT_ROOT>", "--id", "3", "--to", "8"]
```

## Lifecycle Events

For TaskAdmin lifecycle events, Execution Agents fire only complete `TaskPhaseChanged` payloads according to `references/execution-protocol.md`; they must not fire `TaskStarted` or `TaskCompleted` directly. After a successful status update, `update_task.py` emits `TaskStatusChanged` first, then derives `TaskStarted` when the status changes to `in-progress` or `TaskCompleted` when it changes to `done`.

## Vault Visibility

`.maxa/tasks/` is TaskAdmin-owned storage inside the project Vault. Do not export duplicate task/TODO files into knowledge directories. Optional task documents remain inside their owning task workspace and do not become wiki knowledge automatically.

