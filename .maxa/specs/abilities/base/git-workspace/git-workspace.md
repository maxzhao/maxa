---
title: Git Workspace Workflow 行为规格
created: 2026-07-04
updated: 2026-09-25
type: source
doc_role: spec
authority: accepted
status: active
capability: git-workspace-mode
sources:
  - abilities/git-workspace/SKILL.md
  - abilities/git-workspace/references/config-schema.md
  - abilities/git-workspace/references/workspace-lifecycle.md
  - abilities/git-workspace/references/untracked-sync.md
  - abilities/git-workspace/references/taskadmin-binding.md
  - abilities/git-workspace/scripts/git_workspace.py
  - abilities/git-workspace/tests/test_git_workspace.py
  - user-review:2026-09-15
  - user-review:2026-09-21
confidence: medium
review:
  human: passed
  evidence: user-declared-current-change-review-2026-09-21
---

## Requirements

### Requirement: Workspace mode is optional and local

Without an explicit user request or `.maxa/workspaces.yml`, ordinary work SHALL NOT create configuration/worktrees or require checks. Mode scope is local single-user worktree file/index/branch isolation, not a multi-user, remote, container, credential, CI or security sandbox.

### Requirement: Configuration is explicit project state

- `.maxa/workspaces.yml` version `1` owns layout, branch/name templates, `create.base: current_head`, untracked sync policy and an optional explicit `workspaces` list; it SHALL NOT store runtime state or TaskAdmin bindings. Version-1 files without `workspaces` remain valid; creation SHALL NOT register or invent definitions.
- Each definition requires nonblank `name` and `responsibility`, absolute local `path`, and `type: main|child`. Consumers normalize paths, require exact equality and reject normalized duplicates rather than infer identity. Each checkout reads its own config; explicit identity resolution SHALL NOT locate a primary-worktree copy.
- Initialization proposes deterministic facts/defaults, requires user confirmation of project-specific paths/templates/include patterns before writing, and rejects empty/unresolved required fields without a partial file.

### Requirement: Creation uses current checkout HEAD

`create <workspace>` validates repository/config, resolves target/branch from templates, refuses existing targets or a branch checked out elsewhere, and creates from the invoking checkout `HEAD`. It SHALL NOT register or scan a Project Vault.

### Requirement: Child TaskAdmin tag on creation

With initialized TaskAdmin, `create <workspace>` SHALL:

1. Before Worktree modification, validate the workspace name as a tag; block if an existing tag is bound elsewhere or is unbound with tasks.
2. In the new checkout, create/reuse the same-named tag, bind its default `workspace` to that name through TaskAdmin, and switch to it before `create.after_commands`. Preserve compatible tasks and the invoking checkout's tag without copying its tasks; configuration's no-registration rule remains applicable.

Without initialized TaskAdmin, preserve prior creation behavior and report tag setup skipped. Tag-setup failure after creation retains the Worktree, reports incomplete setup and skips post-create commands.

### Requirement: Sync copies configured untracked paths only

Include patterns are source-checkout-relative and must stay inside the invoking source checkout. With `only_untracked`, skip tracked paths. Skip existing targets with warnings; by default never overwrite, delete, merge or back them up. Missing sources warn and continue. Skip symlinks unless handling is explicitly supported/tested. Reports expose only paths/counts, never contents.

### Requirement: Detection, status, checking, and cleanup are guarded

| Operation | Contract |
| --- | --- |
| Detection | Report Git root/directory/common directory and branch/primary/linked evidence. Under configuration's normalized exact-match rule, add `workspace_definition: {name, type, responsibility}` only for one valid current-root definition; absent/invalid/duplicate/unmatched definitions yield no explicit identity. |
| Status | Report branch, dirty state, untracked count and unique/unpushed commit state. |
| `check` | Fail on checkout mismatch with expected/current paths. |
| Cleanup | Refuse dirty, staged, untracked or unique/unpushed work; no first-version force deletion path. |

### Requirement: Child TaskAdmin tag on entry

Before managing tasks in an existing child checkout, the Agent SHALL confirm intended workspace identity/path, then create/reuse and switch to the same-named tag through TaskAdmin if needed. It SHALL NOT infer the main tag from `master`, silently rebind an incompatible tag or change task-level workspace precedence. Unreliable child identity requires asking for the intended workspace, not inferring it from branch/directory name.

### Requirement: Target tag during integration

The Agent SHALL record the target checkout's active TaskAdmin tag before child-branch integration and verify/restore it through TaskAdmin afterward, including fast-forward. Resolve tracked `state.yaml` conflicts by preserving the target version, not line-merging script-owned state. A main tag need not be `master` and SHOULD NOT be a child's dedicated tag. Overlapping tasks still require existing TaskAdmin task reconciliation.

### Requirement: TaskAdmin binding remains optional

`task-binding --tag <TAG> --id <INTEGER>` validates ASCII tag/integer ID before path construction, reads task workspace `_meta.yaml` then tag `_meta.yaml`, and applies task-over-tag precedence; reject traversal, dotted IDs and parent inheritance. Missing/wrong bound workspace blocks TaskAdmin implementation edits without automatic workspace creation/switching. This optional preflight is separate from child-tag creation/entry setup. [[specs/abilities/base/task-admin/core|TaskAdmin Core]] owns tag metadata, binding mutation and full task semantics; Git Workspace owns optional orchestration/checks.

### Requirement: Scripts use the skill uv runtime

```bash
uv run --project <skill_root> python <skill_root>/scripts/git_workspace.py ...
```

No MCP server or Native tool dependency is required.

## Validation And Review State

- Focused Git Workspace unittest suite: 17 tests passed on 2026-09-24; coverage: child tag creation/reuse/conflicts, unchanged source state, standalone mode and prior config/binding/cleanup behavior. Current behavior received no human review.
- Human specification review passed by explicit user declarations on 2026-09-15 and 2026-09-21.
- A current live user-workspace creation/cleanup acceptance pass was not run; the reviewed task-over-tag binding contract is active without claiming that live check.
