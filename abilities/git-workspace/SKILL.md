---
name: git-workspace
description: "Manage optional local single-user Git worktree workspaces for isolated development, untracked-file sync, and TaskAdmin workspace binding checks."
compatibility: Requires Maxa Ability runtime.
---
# Git Workspace

## Purpose

Use this Ability to initialize and operate Maxa Git workspace mode: optional local single-user Git worktree checkouts with configured untracked-file copying, primary-worktree file links, and post-create setup commands. Workspace mode is usable without TaskAdmin; when TaskAdmin is initialized, child creation sets up its same-named tag, while task-binding checks remain a separate integration path.

## Boundaries

- Local single-machine single-user workflow only.
- Not a remote sandbox, container, credential boundary, or multi-user coordination mechanism.
- No MCP server/tool dependency; use Ability scripts and Git commands.
- Do not create `.maxa/workspaces.yml` until required fields are confirmed by the user.
- Optional `workspaces` entries identify local checkouts by exact normalized absolute path and declare only `name`, `type: main|child`, and `responsibility`; creation never registers them automatically.
- Each checkout reads its own `.maxa/workspaces.yml`; do not locate a primary-worktree config copy when resolving explicit identity.
- Do not store TaskAdmin bindings in `.maxa/workspaces.yml`; read them from TaskAdmin tag metadata or task workspace `_meta.yaml`.

## Project Vault Boundary

Creating or synchronizing a Worktree does not register its `.maxa/` with Obsidian/Syncthing. ProjectAdmin owns external Vault eligibility; load `project-admin` if external setup/status is needed and follow its instructions. Linked Worktrees keep independent files and use explicit Git integration for tracked knowledge, not whole-Vault links/copies or another registered identity. Do not add Vault registration/scan to creation hooks. A user-configured `after_commands` call to a prohibited supported Vault command fails normally; never suppress that rejection or reinterpret it as setup to repair.

## Resource Routing

Load with `load(target="git-workspace")`. Read the relative package references below through their catalog addresses, for example `read(path="#git-workspace[/references/config-schema.md]")`; use `load(target="#git-workspace[/references/taskadmin-binding.md]")` when loading the check contract.

| Need | Read |
| --- | --- |
| Config fields, defaults, initialization questions | `references/config-schema.md` |
| Create/list/detect/status/check/cleanup flow and Git integration preflight | `references/workspace-lifecycle.md` |
| Include-copy, primary-worktree link, and sync behavior | `references/untracked-sync.md` |
| Validate an effective TaskAdmin binding | `references/taskadmin-binding.md` after TaskAdmin resolves the binding |
| Reconcile TaskAdmin tasks changed in separate Worktrees | Load `task-admin` and follow its cross-workspace reconciliation instructions before Git integration |

## Script

Use `run(title="Inspect workspace help", scope="tool", command="@git-workspace:/scripts/git_workspace.py", args=["--help"])` for help. The catalog executor retains `uv run --project {root} python {script}` with the owning Ability root; do not shell-run it for normal Agent execution.

Each YAML entry below supplies run fields, not an unconditional batch. Resolve project paths, workspace, tag and ID before invoking; array `args` are literal CLI strings with no shell expansion.

```yaml
# Detect current checkout/worktree state and any exact explicit workspace definition
- title: "Detect workspace state"
  scope: tool
  command: "@git-workspace:/scripts/git_workspace.py"
  args: ["--project-root", "<PROJECT_ROOT>", "detect", "--json"]

# Produce an initialization proposal; Agent must ask/confirm before writing config
- title: "Propose workspace configuration"
  scope: tool
  command: "@git-workspace:/scripts/git_workspace.py"
  args: ["--project-root", "<PROJECT_ROOT>", "init-config", "--print-template"]

# Write config after user-confirmed fields are available
- title: "Write confirmed workspace configuration"
  scope: tool
  command: "@git-workspace:/scripts/git_workspace.py"
  args: ["--project-root", "<PROJECT_ROOT>", "init-config", "--write", "--include-pattern", ".env", "--include-pattern", ".vscode/"]

# Create workspace from the current checkout HEAD and sync configured untracked files
- title: "Create workspace"
  scope: tool
  command: "@git-workspace:/scripts/git_workspace.py"
  args: ["--project-root", "<PROJECT_ROOT>", "create", "<workspace>", "--json"]

# List workspaces and Git worktrees
- title: "List workspaces"
  scope: tool
  command: "@git-workspace:/scripts/git_workspace.py"
  args: ["--project-root", "<PROJECT_ROOT>", "list", "--json"]

# Re-run sync from the current checkout to a workspace
- title: "Sync workspace files"
  scope: tool
  command: "@git-workspace:/scripts/git_workspace.py"
  args: ["--project-root", "<PROJECT_ROOT>", "sync", "<workspace>", "--json"]

# Check the current checkout is the expected workspace
- title: "Check workspace identity"
  scope: tool
  command: "@git-workspace:/scripts/git_workspace.py"
  args: ["--project-root", "<PROJECT_ROOT>", "check", "<workspace>", "--json"]

# Resolve TaskAdmin effective workspace binding
- title: "Resolve workspace task binding"
  scope: tool
  command: "@git-workspace:/scripts/git_workspace.py"
  args: ["--project-root", "<PROJECT_ROOT>", "task-binding", "--tag", "<TAG>", "--id", "<TASK_ID>", "--json"]
```

## Initialization Workflow

When `.maxa/workspaces.yml` is missing and the user asks to enable or create a workspace:

1. Run `detect --json` and `init-config --print-template`.
2. Inspect candidate untracked files without printing file contents.
3. Ask the user to confirm project-specific fields:
   - workspace root;
   - workspace and branch naming templates;
   - `current_head` creation base;
   - optional ordered post-create commands;
   - include-copy patterns;
   - optional primary-worktree link patterns;
   - existing-target behavior (`skip_warn`);
   - optional explicit local workspace paths, `main|child` types, names and responsibilities.
4. Only after all required fields are clear, run `init-config --write` with the confirmed values.
5. If any required field remains unclear, stop without creating `.maxa/workspaces.yml`.

## Git Integration Boundary

Before Agent-directed Git integration between main and child worktrees, read `references/workspace-lifecycle.md` and apply its Specification Integration Gate before changing either branch. This is a tracked-content integration preflight, separate from the script's untracked-file `sync` and workspace creation flows.

## TaskAdmin Integration Boundary

TaskAdmin owns tag state, binding fields, mutation, and precedence. For an initialized TaskAdmin store, `create` uses TaskAdmin's `manage_tag.py` in the **new checkout** to create/reuse, bind and switch its workspace-named child tag before post-create commands; without TaskAdmin, creation skips tag setup. A tag with tasks but no matching workspace binding, or one bound elsewhere, is not silently repurposed. Worktree creation does not register a workspace definition. See `references/workspace-lifecycle.md` for creation and entry rules.

On entering an existing child, first confirm its identity/path: use `detect` for a configured explicit child definition, or `check <NAME>` for an expected template-derived path. Load `task-admin`, list its tags in that checkout, and use `@task-admin:/scripts/manage_tag.py` to create the child-named tag with `--workspace <NAME>` if absent, set its workspace if empty and task-free, then switch; keep already-matching tags/tasks. Stop on conflicting bindings or an unbound tag with existing tasks. Never force a main checkout to `master` or to a child-dedicated tag; its active tag may be arbitrary.

Task execution uses a separate preflight: only after TaskAdmin reports an effective workspace name, this Ability resolves its configured path, verifies existence and compares the current checkout. Task-level binding still overrides tag binding; do not auto-create/switch a workspace or rewrite metadata as a side effect of this check. Call `load(target="#git-workspace[/references/taskadmin-binding.md]")` for the check contract.

TaskAdmin owns task identity and semantic reconciliation when separate Worktrees change or create overlapping tasks. Load `task-admin` and follow its instructions before Git integration. The Agent performs the comparison, renumbering, consolidation, dependency repair, and validation; do not redirect this work to the user. Before integration, record the **target checkout's current** TaskAdmin tag via `manage_tag.py --action list`; afterward, confirm/restore that tag via TaskAdmin even for a fast-forward merge. If tracked `state.yaml` conflicts, preserve the target's version during Git conflict resolution before confirming/switching through TaskAdmin; never line-merge script-owned state. Do not assume the target tag is `master` or replace it with the incoming child tag. This Ability continues to own Worktree safety and Git integration order.

## Failure Handling

- Git command failure: report stderr and stop.
- Invalid config: report the field and expected value.
- Existing target path during create: fail before modifying it.
- Existing copy or link target during sync: skip and warn; never overwrite by default.
- Missing primary-worktree link source: fail without creating a dangling link.
- Failed post-create command: stop the sequence, report command/exit code, and retain the workspace for repair.
- Dirty/untracked/unpushed cleanup target: refuse cleanup and report blockers.

