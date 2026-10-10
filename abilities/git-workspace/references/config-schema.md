# Git Workspace Config Schema

Purpose: define `.maxa/workspaces.yml` for optional local Git worktree workspaces.

## Ownership

- Created by `git-workspace` initialization only after user confirmation.
- Maintained only when workspace layout, explicit identity/responsibility, or untracked-file sync policy changes.
- Not runtime state; create/list/sync/check/cleanup must not rewrite it or auto-register workspace definitions.
- Does not store TaskAdmin bindings.

## Schema

```yaml
version: 1

workspaces:
  - name: main
    path: /home/user/projects/example
    type: main
    responsibility: Shared integration and governance
  - name: feature-a
    path: /home/user/projects/example-workspaces/example-feature-a
    type: child
    responsibility: Implement feature A

layout:
  root: "../{repo_name}-workspaces"
  name_template: "{repo_name}-{workspace}"
  branch_template: "workspace/{workspace}"

create:
  base: current_head
  after_commands:
    - command: just prepare-local
      cwd: .
    - command: just db-local
      cwd: apps/web

sync:
  on_create: true
  source: current_checkout
  only_untracked: true
  existing_target: skip_warn
  missing_source: warn
  include_patterns: |
    .env.local
    .mcp.json
    .vscode/
  link_patterns: |
    .env
```

## Fields

| Field | Required | Allowed values | Meaning |
| --- | --- | --- | --- |
| `version` | yes | `1` | Schema version. |
| `workspaces` | no | list of workspace definitions | Explicit local identities used by `detect` and generated model context. Existing version-1 configs may omit it. |
| `workspaces[].name` | when listed | nonblank string | Stable model-visible workspace name. |
| `workspaces[].path` | when listed | absolute local path | Identity key. Paths are normalized before exact comparison; duplicate normalized paths are invalid. |
| `workspaces[].type` | when listed | `main`, `child` | Whether the definition is the main or a child workspace. |
| `workspaces[].responsibility` | when listed | nonblank string | Primary model-visible responsibility. |
| `layout.root` | yes | path template | Parent directory for workspaces. Relative paths resolve from the repository primary worktree so all linked workspaces share one configured root. |
| `layout.name_template` | yes | `{repo_name}`, `{workspace}` template | Workspace directory name. |
| `layout.branch_template` | yes | `{workspace}`, optional `{repo_name}` template | New branch name. |
| `create.base` | yes | `current_head` | Create from the checkout where create command runs. |
| `create.after_commands` | no | list of `{command, cwd}` | Shell commands run serially after copy/link sync. Each `cwd` is relative to the new workspace root. |
| `sync.on_create` | yes | boolean | Run sync after create. |
| `sync.source` | yes | `current_checkout` | Sync source is current checkout. |
| `sync.only_untracked` | yes | boolean | Copy only Git-untracked source paths. |
| `sync.existing_target` | yes | `skip_warn` | Skip existing targets and warn. |
| `sync.missing_source` | yes | `warn` | Warn when a pattern matches nothing. |
| `sync.include_patterns` | yes | multiline text | Include/copy patterns. |
| `sync.link_patterns` | no | multiline text | Files linked from the repository primary worktree after copy sync. |

## Initialization Questions

Ask the user to confirm before writing config:

1. Workspace root path.
2. Workspace directory naming template.
3. Branch naming template.
4. Creation base remains `current_head`.
5. Post-create commands, if any; confirm their order and failure behavior.
6. Include-copy patterns for untracked files/directories.
7. Primary-worktree link patterns for single-source local files, if any.
8. Existing target behavior remains `skip_warn`.
9. Optional explicit workspace definitions: local absolute path, `main|child` type, stable name and primary responsibility.

Workspace definitions are local single-user configuration. Every checkout reads its own `.maxa/workspaces.yml`; `create` does not register or infer entries. Consumers normalize configured paths and the current project root, then require exact equality.

Each `create.after_commands` item requires `command` and `cwd`. `cwd` resolves inside the new workspace; absolute paths, traversal outside the workspace, and missing directories fail. Commands run with `bash -lc` in declaration order. Output is suppressed to avoid leaking local setup data. The first non-zero exit stops the sequence and reports the command and exit code; the created workspace is retained for repair.

If required fields remain unclear, stop without creating `.maxa/workspaces.yml`.
