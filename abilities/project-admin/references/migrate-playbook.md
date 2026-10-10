# ProjectAdmin Migration Playbook

Purpose: migrate legacy/partial/custom `.maxa/` layouts into the current project-local root Vault without losing content. `knowledge-vault.md` owns layout, identity, checkout eligibility and ignore/sync boundaries.

## Select Workflow

| State | Action |
| --- | --- |
| New/empty | `init-operation.md`. |
| Partial current layout | Compatible structure/index repair; no semantic body moves. |
| Version 0 or legacy nested root | `upgrades/v0-to-v1-root-vault-layout.md`; documented version upgrade precedes sync. |
| Version 1 with article-oriented wiki area | Explicit `wiki-to-weave.md` migration, preserving schema/version/identity; never create parallel structures. |
| Custom content/tooling | Preserve ownership; prepare reviewed target mapping before moves. |

Current required roots: `inbox/`, `specs/`, `weave/`, `tasks/`, `drafts/`, `translate-cache/`, `attachments/`, `canvases/`. Content categories (`ideas/`, `research/`, `rules/`, `reports/` or another explicit owner) exist only for actual content. Root routing and each maintained category index/log follow the single layout owner.

Retired nested `.maxa/knowledge/`, root `raw/`, `.maxa/rules.md`, old `sources/` publishing and task exports are migration inputs, never reader fallbacks or new outputs. Low-cost context/relationships belong to `weave.md`, not a parallel backfill pipeline.

## Ordered Migration

1. Select explicit project and read root/indexes; inventory only relevant current/legacy files and collisions.
2. Apply checkout ownership before external work. Linked Worktrees retain local steps without primary-Vault redirection; unresolved ownership blocks required external steps. Ordinary `ensure` never retargets registrations.
3. Prepare no-overwrite mapping and recoverable temporary copies or verified Git originals. Preserve user-authored content; uncertain destructive/semantic decisions require one targeted question.
4. Apply the selected version guide or `wiki-to-weave.md`; mechanical compatible shells/indexes may be repaired, semantic content needs full-source review. Never equate prepared candidates with migrated bodies.
5. Preserve unique content at its semantic owner; create optional categories only when justified. Record status/authority/provenance, reconcile target duplicates conservatively and maintain progressive indexes/logs.
6. Retire obsolete containers/exports only after useful content and references are preserved. Completed old-area cutover retains no compatibility router or dedicated legacy archive; task/chat/Git history remain untouched.
7. Validate local structure, affected links/content preservation and scoped live graph checks when eligible. A layout-only migration preserves schema; a version upgrade changes it only after its guide passes.

## Required File Checks

```bash
test -f .maxa/AGENTS.md
test -f .maxa/index.md
test -f .maxa/_meta.yaml
for d in inbox specs weave attachments canvases; do
  test -f ".maxa/$d/index.md"
  test -f ".maxa/$d/log.md"
done
test -d .maxa/tasks
test -d .maxa/drafts
test -d .maxa/translate-cache
test ! -e .maxa/knowledge
test ! -e .maxa/raw
for d in ideas reports research rules; do
  if [ -d ".maxa/$d" ]; then
    test -f ".maxa/$d/index.md"
    test -f ".maxa/$d/log.md"
  fi
done
```

## Output And Failure

Keep mapping/dispositions and actual validation in the owning task/log or a necessary existing report; no duplicate report by default. Report changed files, retirement, exact unresolved decisions and file/live coverage. On collision retain source and stop dependent movement; do not overwrite. Missing graph evidence is explicit, not another Vault's result. Do not claim migration complete from skeleton creation or script status alone.
