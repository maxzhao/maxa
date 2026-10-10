# Upgrade v0 To v1 Root Vault

Purpose: make `.maxa/` the project-local Obsidian Vault root while applying current content/weave ownership. Read `knowledge-vault.md`, `migrate-playbook.md` and `wiki-to-weave.md` for semantic generated-content migration.

## Version And Ownership

Read only `_meta.yaml.schema_version`: missing field/file means 0; target is 1. Preserve name, creation provenance, Folder ID, Ability selections and supported settings. Vault root is fixed, not metadata-configurable. Set version only after required checks pass.

Apply checkout policy before external work. Linked Worktrees perform local-only steps without another Vault's identity/graph; unresolved ownership blocks required external work. Existing historical registrations need separately authorized repair; ordinary `ensure` rejects conflicts and cannot silently retarget.

## Ordered Upgrade

1. Resolve project; inspect root and immediate legacy `.maxa/knowledge/` paths, source/index content and target collisions. At minimum compare rules/AGENTS, old/new metadata/Obsidian/shared ignores, reports, specs/source categories, generated content and root index/log targets.
2. Prepare explicit no-overwrite mapping and backup/recoverable originals. Do not blindly copy skeletons or semantically classify legacy root files from filenames alone.
3. Move/copy governance and content with current owners:

| Legacy | Current handling |
| --- | --- |
| `.maxa/rules.md` | `.maxa/AGENTS.md`; reconcile target, then repair references. |
| `knowledge/_meta.yaml` | Root metadata; preserve identity/settings, version updated last. |
| `knowledge/.obsidian/` | Root stable config; do not copy local workspace/cache/trash state as shared assets. |
| `knowledge/.stignore` | Shared rules in `.stignore-shared`; local include remains exactly `#include .stignore-shared`. |
| `knowledge/sources/{ideas,research,rules,specs}/` | Same semantic root categories; no-overwrite merge and index/log. Specs retain their owning lifecycle. |
| `knowledge/{inbox,reports,attachments,canvases}/` | Same root zones; preserve and reconcile indexed content. |
| `knowledge/{patterns,decisions,modules,glossary,templates}/`, old root synthesis/index/log or `wiki/` | Classify through `wiki-to-weave.md`; unique articles go to content owners, navigation is regenerated in weave, redundant structures retired after preservation. No wholesale rename or parallel archive. |
| `knowledge/*.md` except index/log | Preserve original root filename without overwrite. Further semantic relocation requires the explicit project mapping; target conflicts remain recoverable. |
| `knowledge/raw/` | Inspect evidence and route to semantic owners; obsolete pointers/empty directories retire only after useful facts are preserved. No root raw fallback. |
| `knowledge/tasks/` | Remove only after confirming obsolete export output, not actual TaskAdmin storage. |

4. Create lightweight root router and L0 AGENTS. Route to content/weave/inbox/workspace owners, never filename-only catalogs. Inspect target content before writing useful one-line index descriptions.
5. Ensure required `inbox/specs/weave/attachments/canvases` index/log, workspace directories and maintained child indexes; optional content categories only for actual content. Weave bodies require the explicit migration/weaving scope, not speculative generation.
6. Write shared Syncthing rules and bootstrap local include on every joined client before Vault writes. Preserve root-anchored runtime exclusions for both directory and contents; include `(?d)/knowledge` and `(?d)/knowledge/**` before old-root removal to prevent remote recreation. Git ignore, Obsidian visibility and Syncthing exclusion remain independent; tasks/drafts/cache stay Vault-visible, drafts/cache may remain Git-ignored.
7. Repair root rules/runtime/source references and remove retired task-export tooling under the authorized scope. Do not rewrite task/chat/Git history or active unrelated user files.
8. If eligible historical external paths need repair, perform only separately authorized repair and verify current physical target; unresolved repair blocks deletion of externally referenced originals. Linked projects mark this external step not applicable.
9. Validate content preservation, current routing/ignores and affected links; then retire old nested root/raw/generated containers. No old active compatibility path remains.
10. Set schema version 1 only after validation. Report exact incomplete local/external checks, mapping/conflicts and remaining manual items; prepared candidates are not completed body migration.

## Acceptance

```bash
test -f .maxa/AGENTS.md
test -f .maxa/index.md
test -f .maxa/_meta.yaml
for d in attachments canvases inbox specs weave; do
  test -f ".maxa/$d/index.md"
  test -f ".maxa/$d/log.md"
done
for d in tasks drafts translate-cache; do test -d ".maxa/$d"; done
for d in ideas reports research rules; do
  if [ -d ".maxa/$d" ]; then
    test -f ".maxa/$d/index.md"
    test -f ".maxa/$d/log.md"
  fi
done
test ! -e .maxa/knowledge
test ! -e .maxa/raw
test ! -e .maxa/wiki
printf '#include .stignore-shared\n' | cmp -s - .maxa/.stignore
test ! -f abilities/task-admin/scripts/export_tasks_to_knowledge.py
```

Inspect shared ignore semantics rather than inferring them from Git: runtime exclusions and retired nested-root guards use root-anchored directory/content pairs; tasks/drafts/cache are not excluded as knowledge sync zones. After version update, confirm canonical marker and preserved identity/settings.

For eligible external sync verification, call cataloged `project_knowledge_sync.py` with literal `--project-root <PROJECT_ROOT> status`; require actual `path_matches`, `marker_exists`, `stignore_exists`, `stignore_shared_exists` true. Linked projects mark policy-excluded external checks not applicable; unresolved/null facts are not permission to repair. CLI checks use guarded current physical Vault, not default selection.

Inspect paragraph-level index quality, source preservation, weave sizes and affected links; existence/keywords are only structural smoke. Script help/compile and closest runtime checks apply only to changed behavior. No forced scan or full suite is implied.

## Failure

Collision: keep recoverable source, report exact paths/type and request only the necessary choice. Unclassifiable content remains pending, not guessed. Lock/trash/Syncthing temporary files or remote old-root reintroduction block cleanup: preserve originals, resolve only authorized service/ignore/registration steps, then repeat affected checks. Never update version or claim completed upgrade with required cleanup/validation outstanding unless an explicit user exception records the remaining risk.
