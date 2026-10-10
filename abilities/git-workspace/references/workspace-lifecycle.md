# Workspace Lifecycle

## Commands

After `load(target="git-workspace")`, use the cataloged script through titled `run(scope="tool")`. Example run fields for detection:

```yaml
title: "Detect workspace state"
scope: tool
command: "@git-workspace:/scripts/git_workspace.py"
args: ["--project-root", "<PROJECT_ROOT>", "detect", "--json"]
```

Resolve `<PROJECT_ROOT>` first. Select a command below and pass each CLI token as a separate literal `args` item; no shell substitution. The owning uv executor is retained.

Commands:

- `detect`: current Git checkout/worktree details plus an explicit workspace definition when the current root exactly matches one configured absolute path.
- `init-config`: generate or write `.maxa/workspaces.yml` after confirmation.
- `list`: list Git worktrees and configured workspace mapping.
- `create <workspace>`: create branch/worktree from current HEAD, then sync if enabled.
- `sync <workspace-or-path>`: copy configured untracked files from current checkout to target.
- `status <workspace-or-path>`: report branch, dirty state, untracked count, unpushed state.
- `check <workspace>`: verify current checkout path matches expected workspace path.
- `cleanup <workspace-or-path>`: remove workspace only when safety checks pass.

## Detection Flow

1. Resolve the current Git checkout root and standard Git worktree details.
2. Read only the current checkout's `.maxa/workspaces.yml`; do not locate a primary-worktree config copy.
3. Normalize the current root and all optional `workspaces[].path` values.
4. When exactly one valid definition matches, add `workspace_definition: {name, type, responsibility}` to JSON output.
5. Missing, invalid, duplicate or unmatched definitions add no explicit identity fields; config-dependent operational commands keep their normal explicit validation errors.
6. Preserve the existing configured-layout evidence for compatibility; never use it to infer responsibility.

## Create Flow

Keep external project Vault setup out of this flow. Inherited `.maxa/_meta.yaml` is project identity, not permission to register a linked Worktree. Follow the Project Vault Boundary in `SKILL.md`; local file governance remains available and external registration/scan is not applicable.

1. Validate current directory is inside a Git repository.
2. Load `.maxa/workspaces.yml`.
3. Resolve target path and branch from templates.
4. Refuse if target path exists.
5. Refuse if target branch is checked out in another worktree.
6. If the invoking checkout has an initialized TaskAdmin store, validate `<workspace>` as a tag and reject a conflicting existing tag (different workspace binding or unbound with existing tasks) before adding a Worktree. Leave projects without TaskAdmin unchanged.
7. Run `git worktree add -b <branch> <target-path> HEAD`.
8. Run copy sync and primary-worktree link creation when `sync.on_create: true`.
9. In the **new checkout**, create/reuse the workspace-named TaskAdmin tag, bind its default workspace via `manage_tag.py` and switch to it. Never copy tasks from the invoking tag or switch its `currentTag`. When TaskAdmin is absent, report tag setup as skipped. If setup fails after worktree creation, retain the Worktree and report incomplete setup for repair; do not continue post-create commands.
10. Run `create.after_commands` serially, each from its configured workspace-relative `cwd`.
11. Report path, branch, base commit, tag setup/skipping, copied/linked paths, completed commands, skipped paths, and warnings.

## Specification Integration Gate

Purpose: block Agent-directed Git integration of unready specification changes between main and child worktrees. Apply before merges, including fast-forward merges, and rebases used to synchronize these worktrees; the script's untracked-file `sync` and creation flows are unchanged.

1. Confirm source/target checkout paths, the incoming Git revision and the main-to-child or child-to-main direction. Use valid explicit `workspaces[].type` definitions or user-confirmed identities; do not infer roles from branch/directory names. Ask one targeted question if direction is unresolved.
2. If either checkout or the incoming revision contains `.maxa/specs/`, load `spec-admin` and inspect the source specification tree and the revision being integrated. Projects without this specification tree skip this gate. Include archived/retained records and hidden or ignored entries; do not check only active changes or changed files.
3. Require the applicable source-side condition:

| Direction | Required condition |
| --- | --- |
| Main to child | All source change behavior has been promoted into formal stable specs. `.maxa/specs/changes/` must be absent or have **no entries**, in both the source checkout and incoming revision: no proposals, delta specs, archive records/directories, indexes, placeholders or other files. `accepted` or `archive_state: retained` records still block this direction. Verify relevant promotion evidence in stable owners and spec/task history; merely deleting changes does not prove promotion. |
| Child to main | Every change proposal and delta spec under the source `.maxa/specs/changes/`, including archived/retained records, must explicitly have `status: accepted` in both the source checkout and incoming revision. `draft`, `rejected`, `superseded`, missing/unknown status, or unreadable lifecycle metadata blocks integration. An absent or empty changes directory has no change status to check. Interpret acceptance through SpecAdmin; do not infer it from task completion or an archive label. |

4. Treat the gate as read-only. On failure, stop before Git integration and report direction, source revision, blocking paths, actual state and required condition. Do not delete/move records, rewrite statuses or promote specs merely to pass the gate; any remediation requires separately authorized SpecAdmin lifecycle work.
5. After this gate passes, continue the applicable TaskAdmin reconciliation and target-tag preservation below, then perform authorized Git integration and relevant validation. Passing this gate does not bypass existing Worktree safety checks.

## Existing Child Entry And Integration

Before managing tasks in an existing child checkout, confirm the intended identity with `detect` and compare the checkout path against a configured explicit child definition or the expected path from `check`. When neither establishes a reliable name, ask for the intended child workspace instead of inferring identity from a directory/branch label. Load `task-admin` and call `@task-admin:/scripts/manage_tag.py` with `args: ["--project-root", "<CHILD_ROOT>", "--action", "list"]`. If the same-named tag is absent, call `create --name <NAME> --workspace <NAME>`; if it is empty and unbound, call `set-workspace --name <NAME> --workspace <NAME>`; finally call `switch --name <NAME>`. Pass each flag/value as separate literal `args` items with the same `--project-root`. Do not silently rebind an existing tag with tasks or a conflicting binding. Task-level workspace overrides remain subject to the existing preflight.

Before integrating a child branch, capture the **target checkout's** active tag (`manage_tag.py --action list`); after Git integration, confirm that tag still exists and switch back if needed (`manage_tag.py --action switch --name <CAPTURED_TAG>`), including after fast-forward merges. If Git reports a tracked `state.yaml` conflict, select the target's version as Git conflict resolution before the TaskAdmin switch; never line-merge script-owned state. Resolve any task metadata/plan/TODO conflicts under TaskAdmin reconciliation before declaring integration complete. A main checkout keeps its existing tag, whether or not it is `master`; avoid using a child-dedicated tag as the main tag. This is Agent integration guidance, not an automatic Git merge command.

## Parallel Integration Boundary

Worktrees isolate implementation writes but defer integration conflicts. If separate Worktrees changed or created TaskAdmin tasks, load `task-admin` and complete its cross-workspace task reconciliation before Git integration; do not resolve task directories as ordinary text conflicts or delegate semantic comparison to the user.

Before creating several implementation workspaces:

1. map slice dependencies and shared hotspots (registries, enums, schemas, manifests, generated surfaces, and shared fixtures);
2. establish shared foundation contracts serially;
3. assign each hotspot one owner per wave;
4. keep coupled slices serial even when separate worktrees are technically possible;
5. integrate in dependency order, rebase followers, and rerun relevant checks after every merge.

Do not change architecture only to avoid merge conflicts. Prefer serial integration of a legitimate shared-owner edit over duplicated authorities. Load `subagent` before delegating any slice.

If a post-create command fails, stop remaining commands, report its exit code, and retain the workspace; do not roll back copied files, links, branch, or Worktree.

## Cleanup Guards

Cleanup must refuse automatic removal when target workspace has:

- staged or unstaged modifications;
- untracked files;
- unpushed commits;
- path outside configured workspace root.

First version has no force cleanup. Report manual follow-up instead.
