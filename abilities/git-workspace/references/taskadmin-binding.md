# TaskAdmin Workspace Check

Purpose: validate the effective workspace name supplied by TaskAdmin before implementation edits. TaskAdmin owns binding fields, mutation, and precedence; this Ability must not redefine or modify them.

## Input

- Project root.
- Valid ASCII TaskAdmin tag and positive integer task ID，used by `task-binding` to obtain the effective workspace name from task then tag metadata。Invalid tag traversal/separators and dotted IDs fail before path construction。
- Existing `.maxa/workspaces.yml` workspace configuration.

If TaskAdmin reports no effective binding, no workspace check is required. For binding schema or precedence questions, follow `task-admin` rather than duplicating those rules here.

## Check Contract

After `load(target="git-workspace")`, resolve the project root, tag and integer task ID and pass these literal arguments to `run`:

```yaml
title: "Check TaskAdmin workspace binding"
scope: tool
command: "@git-workspace:/scripts/git_workspace.py"
args: ["--project-root", "<PROJECT_ROOT>", "task-binding", "--tag", "<TAG>", "--id", "<TASK_ID>", "--json"]
```

Interpret the result:

1. If no effective binding exists, return to TaskAdmin execution without a workspace constraint.
2. Resolve the expected path and branch from `.maxa/workspaces.yml`.
3. Verify the workspace exists in `git worktree list` or at the expected path.
4. Verify the current checkout path equals the expected workspace path.
5. If missing, block and tell the user to create the workspace first; do not auto-create it.
6. If the current checkout differs, block and report expected and current paths; do not auto-switch it.
7. Record workspace name, path, branch, and check status when TaskAdmin TODO is next updated.

## Ownership Limits

- Do not set, clear, or rewrite TaskAdmin tag/task bindings.
- Do not create, sync, switch, or clean up a workspace as a side effect of the check.
- Do not infer a different workspace when the configured binding is missing or invalid.
