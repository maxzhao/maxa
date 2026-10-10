# Task Workspace Metadata Contract

Purpose: define the script-owned YAML metadata used by single-level TaskAdmin task workspaces. Use TaskAdmin scripts for mutation; do not hand-edit metadata during normal operations.

## Directory Model

```text
.maxa/tasks/
├── state.yaml
└── <tag>/
    ├── _meta.yaml
    └── task_NNN/
        ├── _meta.yaml
        ├── plan.md
        ├── todo.md
        └── <optional task-owned documents>
```

Task IDs are positive integers derived from canonical `task_NNN/` names and are unique only inside a tag. Three digits are a minimum，so ID `1000` uses `task_1000/`；noncanonical zero padding is invalid。Dotted IDs and parent/child identity do not exist。

## Task `_meta.yaml`

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `name` | string | yes | Task title. |
| `description` | string | no | One-line summary. |
| `status` | enum | yes | Task lifecycle state. |
| `priority` | enum | yes | Task priority. |
| `dependencies` | integer[] | yes | Existing peer tasks in the same tag. |
| `created` | string | yes | ISO 8601 creation time. |
| `updated` | string | yes | Last metadata update time. |
| `workspace` | string | no | Optional Git workspace binding for this task. |

Status values:

- `pending`
- `in-progress`
- `done`
- `review`
- `deferred`
- `cancelled`

Priority values:

- `high`
- `medium`
- `low`

Dependency rules:

- integer IDs only;
- same tag only;
- no missing, self, duplicate or cyclic dependencies;
- manage through `manage_deps.py` / `analyze_deps.py`.

## Tag `_meta.yaml`

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `description` | string | no | Tag summary. |
| `created` | string | yes for new tags | Creation time. |
| `updated` | string | yes for new tags | Last metadata update time. |
| `version` | string | no | Tag metadata version. |
| `workspace` | string | no | Default Git workspace binding. |

Tag names contain only ASCII letters、digits、`-` and `_`；path separators/traversal are invalid。`manage_tag.py` owns create/list/copy/switch/delete/rename and workspace mutation。

## `state.yaml`

```yaml
currentTag: master
lastSwitched: 2026-09-17T00:00:00.000Z
```

The state file selects the only tag for ordinary task writes and the default tag for read-only queries. Create/update/delete/dependency mutation/renumber have no `--tag`; dependency `fix` rejects it. List/next/resolve and dependency validate/graph may query an explicit tag. Move uses the current tag as source and retains `--to-tag`; explicit tag management retains named targets.

Existing-store ordinary writes reject missing/unreadable/malformed state, invalid `currentTag` and a missing current tag directory or `_meta.yaml` before mutation. An absent or empty task store retains `master` initialization on first task creation. Explicit `manage_tag.py --action switch --name <TAG>` can repair state; read-only fallback behavior is unchanged.

## Core Markdown Ownership

- `plan.md`: stable implementation goal, scope, facts, approach, decisions, affected paths, risks, acceptance criteria and validation plan.
- `todo.md`: authoritative live checklist, current state, changed files, validation evidence, errors, blockers and next action.
- Optional documents: task-owned context linked from plan/TODO. Core scripts do not infer type or lifecycle from their filenames.

## Workspace Binding

Effective binding order is:

1. task `_meta.yaml`;
2. tag `_meta.yaml`;
3. no binding.

TaskAdmin owns declaration and mutation only. Workspace values are opaque metadata: TaskAdmin does not resolve paths, validate existence/current checkout, read external configuration or create/switch/sync an environment. External consumers may interpret the declarations independently. Task-level values retain precedence over tag values.

## Mutation Rules

- Use `create_task.py` for complete task publication.
- Use `update_task.py` for status, priority, name, description and task workspace.
- Use `manage_deps.py` for dependency edges.
- Use `manage_tag.py` for tag state/metadata.
- Edit `plan.md`, `todo.md` and optional Markdown only after reading the relevant semantic unit.
