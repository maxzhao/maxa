---
title: TaskAdmin Browser UI 行为规格
created: 2026-06-28
updated: 2026-09-21
type: source
doc_role: spec
authority: accepted
status: active
capability: taskadmin-browser-ui
sources:
  - .maxa/specs/abilities/base/task-admin/core.md
  - lua/plugins/task_browser.lua
  - lua/util/task_browser/
  - .maxa/research/taskadmin-browser-architecture.md
confidence: high
review:
  human: passed
  evidence: user-declared-current-change-review-2026-09-21
---

## Requirements

### Requirement: Browser remains read-only

Browser provides read-only Neovim navigation/display, not metadata/lifecycle authority. Commands, pickers, keymaps and lualine MAY read `.maxa/tasks/<tag>/task_NNN/` metadata/core documents; TaskAdmin scripts own metadata/dependency/status mutation.

### Requirement: Scanner uses task workspaces

Discover only complete canonical `task_NNN/` directories (three-digit minimum, including IDs `>=1000`): parse bare `_meta.yaml` and require both `plan.md` and `todo.md`. Records have integer identity, no parent/subtask fields. Safely skip invalid tags/paths and noncanonical/incomplete directories.

### Requirement: Commands expose peer navigation

Public commands: `TaskBrowserList`, `TaskBrowserSwitchTag`, `TaskBrowserRefresh`, plus:

| Command | Task-buffer key | Behavior |
| --- | --- | --- |
| `TaskBrowserNextExecutable` | — | Delegate to TaskAdmin `next_task.py`. |
| `TaskBrowserNextTask` / `TaskBrowserPreviousTask` | `]n` / `[n` | Open adjacent peer `plan.md` by integer ID. |
| `TaskBrowserToggleTodo` | `]g` | Toggle plan/TODO. |

Missing tag/task/core document: notify and stop without guessing. No parent/first-child/subtask navigation or progress-sidecar toggle.

### Requirement: Context keymaps are buffer-local

Only recognized task `plan.md` / `todo.md` buffers receive the table's keys; ordinary Markdown and optional task documents remain unaffected.

### Requirement: Picker and lualine use peer-task state

Both omit subtask counts/inherited priority and reuse bounded short caches suitable for UI redraw. Picker displays ID/name/status/priority/tag without hierarchy labels; lualine MAY show active (`pending|in-progress|review`) and closed (`done|deferred|cancelled`) counts.

### Requirement: Browser follows the Skill uv runtime

TaskAdmin Python calls use the following, never direct system `python`/`python3`:

```text
uv run --project <task-admin-skill-root> python <script> ...
```

## Validation And Review State

- Latest focused headless tests (2026-09-17): `scanner_test.lua` 4, `navigation_test.lua` 4, `picker_test.lua` 4, `integration_test.lua` 3 — all 15 passed.
- Fresh configured Neovim reload/runtime command surface and empty-store smoke: passed with `TASK_BROWSER_RUNTIME_OK`.
- Final human change review: passed by explicit user declaration on 2026-09-21; no separate new interactive picker/navigation smoke was reported.
