# Initialize Project Governance

Purpose: create minimal `.maxa/` governance for a new project. Apply `SKILL.md` boundaries and execution discipline; paths are project-relative unless named as Ability resources.

## Inputs And Workflow

Apply the checkout/external-operation boundary in `references/knowledge-vault.md`. Linked Worktrees may initialize local files; external setup/checks are not applicable, and no alternate Vault identity or primary-checkout redirection is allowed. Explicit setup is separate from ordinary CLI execution.

Reuse explicit Syncthing decisions supplied for this initialization; otherwise wait for an `ask` reply before dependent sync actions.

1. Verify project root and complete [Git preflight](../SKILL.md#git-preflight) before routing or project writes.
2. Check whether `.maxa/` exists; for an existing layout, prefer `references/sync-operation.md`, carrying forward the completed Git check and user decision.
3. Inspect project basics: name, stack, directories, command entrypoints.
4. Use `read` for `#project-admin[/references/init-layout.md]`, `#project-admin[/references/rules-authoring.md]`, and `#project-admin[/assets/rules-template.md]`; create minimal `.maxa/` and `AGENTS.md` with evidence-backed Agent routing, not a raw directory inventory.
5. Read `#project-admin[/references/knowledge-vault.md]`; create required skeleton: `inbox/`, `specs/`, `weave/`, `tasks/`, `drafts/`, `translate-cache/`, `attachments/`, `canvases/`, metadata and ignore config. Existing old generated content requires explicit migration, not parallel skeleton creation. Write shared rules to `.stignore-shared`; local `.stignore` remains exactly `#include .stignore-shared`.
6. Establish `AGENTS.md -> index.md -> weave/index.md or content indexes` and the inbox review entry. Initialize only weave index/log; topic/concept directories/nodes require actual user-requested weaving, not speculative scaffolding.
7. If a `justfile` exists or unified command entry is requested, read and apply `#project-admin[/references/justfile-guide.md]`.
8. Validate local structure using the scoped checklist in `SKILL.md`.
9. After local validation passes, for eligible projects call `ask(mode="choice")`: enable Syncthing multi-device sync of `.maxa/` / keep local. Confirm the intended device-sharing scope before registration; a generic yes does not authorize sharing with every configured device.
   - Decline: skip Syncthing setup. Approval: use `@project-admin:/scripts/project_knowledge_sync.py` through titled `run(scope="tool")`, with `--project-root` and the selected root, for `status`, `ensure`, then `status`, following `references/knowledge-vault.md`.
   - Verify `service_active`, `folder_registered` and `path_matches`; distinguish local setup from remote-device acceptance and actual multi-device sync.
10. Report local initialization, sync decision/setup status and the next execution entrypoint separately.

## Failure And Completion

Preserve existing user content. Do not create optional root categories without a project need. Report unexecuted requirements, exact blocked checks, and remaining risks rather than claiming initialization is complete.
