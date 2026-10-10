# Cross-Workspace Task Reconciliation

Purpose: reconcile TaskAdmin changes created independently in Git branches or Worktrees while preserving task identity, intent, execution evidence, dependencies, and workspace bindings.

This is an Agent-owned integration workflow. The Agent must inspect both task sets, classify collisions, perform renumbering and semantic consolidation, repair references and dependencies, and validate the result. Do not delegate file comparison or conflict resolution to the user. Ask one targeted question only when contradictory authoritative requirements cannot be resolved from repository evidence and the choice changes the accepted outcome.

Load with `load(target="task-admin")`. Each YAML example below supplies fields to titled `run(scope="tool")`; resolve checkout paths, tags and IDs first and pass literal CLI string-array `args`. Use the cataloged `@task-admin:/scripts/` commands for all named scripts; their owning uv executor is unchanged.

## Identity And Scope

- A TaskAdmin identity is `<tag> + <integer ID>` and maps to one canonical `task_NNN/` directory.
- Task names are descriptive and need not be unique. Equal names are only a duplicate-work signal; different names do not prove distinct work.
- A task or tag `workspace` value is an execution binding, not an identity namespace. Different Worktrees do not make equal tag/ID pairs independent.
- A task that existed at the Git merge base retains the same identity when both branches modify it.
- If both branches created the same tag/ID after the merge base, they created an allocation collision. Normalize that collision before Git integration, even when the tasks describe equivalent work.
- TaskAdmin metadata and documents are semantically reconciled; they are not resolved by blindly choosing `ours` or `theirs`.

## Required Inputs

- Integration target checkout and branch/ref.
- Incoming checkout and branch/ref.
- Their Git merge base.
- TaskAdmin task inventories for every affected tag.
- `plan.md`, `todo.md`, task metadata, optional task-owned documents, and repository references for every colliding or potentially duplicate task.
- Current Git status for both checkouts.
- Original current tag in each checkout that will be mutated, recorded through `manage_tag.py --action list`.

Use explicit `manage_tag.py --action switch --name <TAG>` before ordinary writes or task Markdown edits in that checkout; reads may retain `--tag`. Restore each checkout's original current tag afterward when it still exists. A malformed state file must be resolved to one complete target version, never line-merged; confirm/restore the integration target's selected tag through TaskAdmin after integration, including fast-forward merges.

Treat existing uncommitted changes as user-owned. Do not reset, stash, overwrite, or discard them. If unrelated changes make branch mutation or integration unsafe, report the exact checkout and paths as the blocker; do not tell the user to perform the reconciliation manually.

## Reconciliation Workflow

### 1. Inventory Both Sides

Before merging or rebasing:

1. Identify the merge base and task-related changes on the target and incoming refs.
2. Run `list_tasks.py` against each checkout for every affected tag.
3. Resolve each affected ID with `resolve_task.py`; use returned paths rather than constructing task paths manually.
4. Read both versions of `plan.md` and `todo.md`, relevant metadata, and linked optional documents.
5. Record incoming and outgoing dependency edges and search for textual references to affected tag/ID pairs. A number without its tag/task context is not sufficient evidence for replacement.

Classify every overlap by goal, scope, acceptance criteria, authoritative references, affected ownership, and implementation evidence:

| Case | Classification | Required treatment |
| --- | --- | --- |
| Same tag/ID existed at merge base and changed on both branches | Shared task lineage | Keep the identity and semantically merge documents and metadata. |
| Same tag/ID was independently created on both branches | Allocation collision | Renumber the incoming task before Git integration. |
| Different identities describe the same durable outcome | Semantic duplicate | Integrate both identities, then consolidate into one canonical task. |
| Same name but materially different outcome, scope, or acceptance | Independent tasks | Keep both; clarify names/descriptions if needed. |

Do not infer equivalence from the name, workspace, status, or overlapping files alone.

### 2. Normalize New-ID Collisions Before Git Integration

For each independently created equal tag/ID pair:

1. Preserve the target branch task at its current ID unless repository evidence establishes an older canonical identity.
2. Select an unused positive integer from the union of IDs in both branches for that tag.
3. In the incoming checkout, run:

```yaml
title: "Renumber colliding TaskAdmin task"
scope: tool
command: "@task-admin:/scripts/renumber_task.py"
args: ["--project-root", "<INCOMING_WORKTREE>", "--id", "<COLLIDING_ID>", "--to", "<FREE_ID>"]
```

4. Confirm the script rewrote same-tag metadata dependency edges.
5. Update textual references in plan/TODO, optional task documents, specifications, or other tracked artifacts only where context proves they refer to the renumbered task. `renumber_task.py` does not rewrite prose references.
6. Re-list and resolve the renumbered task, then validate the incoming tag dependencies.

Apply the normalization as an ordinary incoming-branch change before merge/rebase. Do not create directories manually or hand-edit `_meta.yaml`.

### 3. Integrate Git Changes

Follow the caller's authorized Git integration and checkout-safety rules. Shared foundations precede dependent changes; rebase followers when appropriate and rerun relevant project checks after each integration. TaskAdmin does not load external environment capabilities or inspect their configuration.

For a shared task lineage:

- Merge `plan.md` into one coherent statement of current goal, scope, decisions, risks, acceptance criteria, and validation plan.
- Merge `todo.md` into one executable current state. Preserve proven completed work, exact validation evidence, unresolved checklist items, errors, blockers, changed files, and the next action. If one side says complete and the other has unresolved work, unresolved work wins unless repository evidence proves it obsolete.
- Preserve non-duplicate optional documents. If equal filenames have different purposes, rename one meaningfully and update links.
- Resolve script-owned YAML to one complete parseable version only as a temporary Git conflict resolution, then apply the intended final metadata with TaskAdmin scripts. Never line-merge or directly normalize `_meta.yaml` by hand.
- Remove all Git conflict markers before TaskAdmin validation.

### 4. Consolidate Semantic Duplicates

After both identities are present in the integration checkout:

1. Select the canonical identity using this order:
   1. identity present at the merge base;
   2. identity already named by an authoritative external specification or durable repository reference;
   3. target-branch identity, to minimize integration churn.
2. Merge the duplicate task's still-valid scope, decisions, acceptance criteria, TODO state, implementation evidence, validation evidence, blockers, and linked documents into the canonical task. Do not append two complete plans or TODOs side by side.
3. Reconcile metadata through scripts according to the metadata rules below.
4. Rebuild dependency edges semantically:
   - add each still-required outgoing prerequisite to the canonical task;
   - for each peer that depends on the duplicate, add the canonical dependency when it is valid, non-self, absent, and non-cyclic, then remove the duplicate dependency;
   - remove obsolete outgoing dependencies from the duplicate;
   - do not mechanically union edges or use force deletion to hide an invalid graph.
5. Update contextual textual references from the duplicate identity to the canonical identity.
6. Delete the duplicate with `delete_task.py` without `--force`. A dependency guard failure means reconciliation is incomplete and must be repaired before retrying.
7. Resolve and reread the canonical task after deletion.

Typical dependency operations are:

```yaml
- title: "Add canonical task dependency"
  scope: tool
  command: "@task-admin:/scripts/manage_deps.py"
  args: ["--project-root", "<INTEGRATION_WORKTREE>", "--action", "add", "--id", "<TASK_ID>", "--depends-on", "<CANONICAL_ID>"]
- title: "Remove duplicate task dependency"
  scope: tool
  command: "@task-admin:/scripts/manage_deps.py"
  args: ["--project-root", "<INTEGRATION_WORKTREE>", "--action", "remove", "--id", "<TASK_ID>", "--depends-on", "<DUPLICATE_ID>"]
- title: "Delete reconciled duplicate task"
  scope: tool
  command: "@task-admin:/scripts/delete_task.py"
  args: ["--project-root", "<INTEGRATION_WORKTREE>", "--id", "<DUPLICATE_ID>"]
```

If two tasks only share a name, keep both when their durable outcomes differ. Use `update_task.py` to clarify names or descriptions when ambiguity would hinder future resolution.

## Metadata Reconciliation Rules

Use `update_task.py`, `manage_deps.py`, `manage_tag.py`, `renumber_task.py`, and `delete_task.py` for their owned fields and structural mutations.

| Field | Reconciliation rule |
| --- | --- |
| `name`, `description` | Describe the final canonical outcome; do not preserve branch labels or duplicate titles merely as history. |
| `status` | Derive from the merged TODO and evidence. Use `done` only when all merged acceptance and validation requirements are satisfied. Keep unfinished work unfinished. |
| `priority` | Preserve an explicit authoritative priority; otherwise retain the higher urgency when consolidation expands or preserves outstanding scope. |
| `dependencies` | Keep only existing same-tag prerequisites required by the merged scope; no self, duplicate, missing, or cyclic edges. |
| `workspace` | Preserve, update, or clear the declaration through TaskAdmin scripts according to the accepted execution intent. External consumers own operational interpretation; never treat the source Worktree as an identity or infer a replacement declaration. |
| `created`, `updated` | Preserve canonical creation history and let TaskAdmin scripts maintain updates; do not hand-edit timestamps. |

A merged implementation does not by itself prove TaskAdmin completion. Status remains subject to the normal TODO, acceptance, and validation gates.

## Validation And Completion Evidence

For every affected tag, run:

```yaml
title: "Validate reconciled task dependencies"
scope: tool
command: "@task-admin:/scripts/analyze_deps.py"
args: ["--project-root", "<INTEGRATION_WORKTREE>", "--tag", "<TAG>", "--action", "validate"]
```

Then verify all of the following:

1. `list_tasks.py` reports one canonical identity for every consolidated outcome and distinct identities for independent outcomes.
2. `resolve_task.py` succeeds for every retained or renumbered ID and no incomplete `task_NNN/` directory remains.
3. Canonical plan/TODO bodies are coherent, recoverable, and contain no stale duplicate identity or obsolete workspace assumptions.
4. No task metadata has missing, self, duplicate, or cyclic dependencies.
5. No Git conflict markers or stale contextual references remain under affected task/specification paths.
6. `git diff --check` passes.
7. Relevant implementation validation is rerun for integrated code changes; task reconciliation validation does not replace project tests.

Record and report:

- target and incoming refs/workspaces;
- affected tags;
- source identity to final identity mapping;
- classifications (`shared`, `renumbered`, `consolidated`, or `independent`);
- metadata and dependency changes;
- final canonical task paths;
- dependency and project validation results;
- exact blockers or unresolved product decisions, if any.

## Failure Handling

- Script or Git failure: stop, preserve both task bodies and exact error output, then repair from evidence. Do not continue with partially understood identity mappings.
- Unsafe dirty checkout: do not mutate or discard user-owned changes; identify the blocking paths.
- No resolvable canonical outcome: keep tasks separate rather than destructively consolidating them. Ask one targeted question only when an authoritative choice is required to proceed.
- Dependency redirect would create a cycle or self-edge: stop that redirect, inspect task semantics, and choose a valid dependency structure; never force-delete around it.
- Post-merge malformed metadata: restore one complete valid version, then apply intended metadata through TaskAdmin scripts and repeat validation.
