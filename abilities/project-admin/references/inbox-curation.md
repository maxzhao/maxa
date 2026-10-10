# Inbox Content Curation

Purpose: review pending captures into durable content with traceability. `self-improvement` selects/captures; ProjectAdmin curates. Apply `knowledge-governance.md`, layout/ownership in `knowledge-vault.md`, and guarded Obsidian syntax in `obsidian-cli.md` before live graph operations.

## Trigger And Scope

Run on user-requested organize/clean/review. Accumulation is a reason to suggest curation, not automatic permission. Choose a small useful cluster; broad movement/merge/retirement requires the user's scope. Exclude `inbox/feedback/`, task documents, drafts and runtime data. Never copy captures to another Vault by default.

Read root routing -> `inbox/index.md` -> matching content indexes; selected weave nodes may help locate sources but are not merge destinations. Inventory frontmatter/TLDR before reading full candidate captures and target content. Do not scan the whole Vault.

## Queues And Decisions

| Queue | Condition | Handling |
| --- | --- | --- |
| Active | empty/draft/active status; no resolved relation/reason | Review candidates. |
| Resolved | merged with `merged_into`, or deprecated with reason | Exclude from active groups; keep provenance. |
| Invalid resolved | merged missing target, deprecated missing reason | Repair only from known evidence; otherwise report. |
| Reopen candidate | missing/broken target, new conflicting evidence or explicit review request | Report; do not silently reactivate. |
| Non-capture | indexes/README/migration/support files | Exclude. |

Cluster by meaning, not source shape. Record topic, captures, existing content owner, action (`merge|organize|keep|archive|deprecated|split`) and reason. A complete reviewed capture may remain content under inbox if no better owner is justified; do not create a category per cluster.

| Meaning | Content target |
| --- | --- |
| Operation/constraint/governance lesson | `rules/` source note; not automatically a live Agent instruction. |
| Investigation/API/evidence | `research/`. |
| Product/runtime idea or unaccepted tradeoff | `ideas/`. |
| Dated review/audit/validation result | `reports/`. |
| Accepted behavior contract | SpecAdmin workflow, not curation silently editing specs. |
| Immature, weak evidence, disputed | Keep pending in inbox. |

Weave maintenance is separate and user-triggered; reviewed content may later support small topic/concept nodes. Never mark a capture fully absorbed merely because a generated summary links to it.

## Apply And Validate

1. Read complete captures/target semantic sections; compare current rules/status. Keep valid experience; mark obsolete detail historical, separate conflicts and unknowns. Ask only for a concrete unresolved destructive or interpretive decision.
2. Merge conservatively or create content using the durable note contract; retain all prior provenance and useful unique facts. Do not overwrite original evidence or promote every capture.
3. Mark originals only after actual absorption into durable content. `status: merged`, `review_status: reviewed`, `reviewed_at`, `merged_into: ["[[owner/note]]"]`; deprecated captures require a concrete `deprecated_reason`. Keep pending captures active without invented review dates.
4. Archive only when authorized and link-safe, normally `inbox/archive/YYYY-MM/`; otherwise retain marked originals. No physical deletion without explicit authorization.
5. Update the nearest content index/log and inbox review entry. Parent/root indexes route, not duplicate deep lists. Resolved captures leave active lists; short Recently Curated entries may preserve traceability.
6. Validate target existence, frontmatter/provenance, entry chain and affected links; actual graph checks use the eligible registered Vault. Report file/live coverage and changed content/queue state. Do not force a sync scan.

## Existing Script Assistance

Use cataloged `@project-admin:/scripts/inbox_curation.py` through titled `run(scope="tool")`, literal argv and owning uv executor. Resolve `<VAULT>` to current `.maxa/`. Help first when uncertain:

```yaml
- title: Inspect curation help
  scope: tool
  command: "@project-admin:/scripts/inbox_curation.py"
  args: ["--help"]
- title: Inventory active captures
  scope: tool
  command: "@project-admin:/scripts/inbox_curation.py"
  args: ["--vault", "<VAULT>", "active-list", "--with-tldr"]
- title: Mark absorbed capture
  scope: tool
  command: "@project-admin:/scripts/inbox_curation.py"
  args: ["--vault", "<VAULT>", "mark-merged", "--target", "rules/example", "--file", "inbox/learnings/example.md"]
- title: Validate capture relations
  scope: tool
  command: "@project-admin:/scripts/inbox_curation.py"
  args: ["--vault", "<VAULT>", "validate"]
```

Script owns inventory/report/mark-merged/validate mechanics only. Agent owns clusters, semantic body edits, indexes and authorized moves. Report generation is optional, not proof of completed curation; use existing task/log/final output rather than a redundant report.
