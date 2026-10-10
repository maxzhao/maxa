# Bootstrap Specs From Code

Purpose: extract evidence-backed `authority: draft` behavior contracts from brownfield code, not source inventories or invented product decisions. Apply `references/spec-authoring.md` for statement syntax, examples and semantic checks.

## Scope And Workflow

1. Read relevant entrypoints/specs/rules within the user's requested behavior or module boundary. A single-behavior request does not authorize whole-module extraction; do not scan the whole repository.
2. Identify in-scope user/API/UI/CLI/runtime surfaces and relevant coverage dimensions below.
3. Read each behavior chain: entrypoint → handler/controller → service/domain logic → repository/storage → schema/model constraints, plus relevant tests, configuration, documentation and visible results. File/symbol names alone are insufficient.
4. Convert evidenced branches and operation flows into named, testable behavior statements. Conditions, authorization, state/data effects and failure behavior belong in the contract, not only in evidence links. Add scenarios only when they add necessary boundary or sequence detail.
5. Map every code-derived rule to source evidence and a validation/review method. Separate observations from assumptions and unresolved questions.
6. Audit module coverage; record gaps and uninspected behavior rather than inventing defaults, errors or guarantees. Check cross-module conflicts/overlaps before declaring the whole scope complete.
7. For requested spec output, fill `assets/spec-template.md` and update required Vault indexes/logs. Extraction and publication need no task; future implementation of identified gaps follows `references/taskadmin-integration.md` only when planning is requested.
8. Keep drafts non-normative until the promotion gate below is satisfied. Record actual validation/review status, not expected success.

## Coverage Audit

For requested module-wide or multi-module extraction, assess relevant dimensions within that scope and record gaps. For a small behavior extraction, inspect only its chain and directly relevant boundaries; no whole-module audit is required. The table guides applicable checks, not extra implementation/testing or a mandatory matrix in every spec.

| Dimension | Inspect When Applicable |
| --- | --- |
| Normal behavior | Inputs, outputs, side effects and visible results. |
| Actors / authorization | User roles, anonymous/authenticated/admin/API-key/system callers and guard failures. |
| State / data | Reads, writes, updates, deletes, emitted events/jobs and schema constraints. |
| Failure / boundaries | Invalid input, missing state, permission failure, disabled settings, empty data and unsupported values. |
| External dependencies | Network/provider/database/cache/email/payment/model-provider failure responses. |
| Concurrency / idempotency | Duplicate requests, locks, retries, races, transactions and replay. |
| Configuration | Feature flags and runtime/environment settings that affect behavior. |
| Validation | Required primary behavioral evidence, applicable regression checks/human review, actual status and missing coverage. |

Coverage must point to behavioral rules, not merely inspected files. A rule with explicit conditions and outcomes does not require a duplicate scenario to count as covered. Mark applicable dimensions `covered`, `partial` or `missing`; use `n/a` only with a rationale. Unknowns are gaps, never implicit `n/a`.

For multi-module or high-risk extraction, use `assets/coverage-audit-template.md` as scoped review evidence; temporary drafts may link it. Formal output retains necessary source coverage and material gaps directly, without execution associations. A small extraction may record dimensions/evidence/gaps in a compact list. Do not omit unchecked dimensions for brevity.

## Evidence And Automation

Every code-derived requirement must map to at least one exact source; grouping rule names under shared evidence is valid when attribution remains clear. Sources may be code path + symbol/route/schema, tests, existing docs/specs, linked TaskAdmin evidence or explicit user input.

The hierarchy below ranks evidence for extracting a contract, not for accepting runtime behavior. Source logic plus tests does not prove actual UI interaction or live integration. Apply the minimum evidence required by `Acceptance Evidence` in `references/spec-authoring.md`; mark material runtime verification gaps without turning draft extraction into unrequested implementation, test development or live acceptance work.

Extraction evidence strength, highest first:

1. Source logic plus behavior-confirming tests.
2. Source logic plus confirming configuration/schema.
3. Source logic alone.
4. Documentation/user input, explicitly marked as non-code evidence.
5. Inference, explicitly marked as an assumption or open question, not an observed fact.

Automation may generate route tables, schema/function inventories, module maps and source-coverage reports. These are support artifacts, never final specs. Inspect actual behavior logic before deriving a rule; link substantial evidence maps from `Source Trace` rather than pasting them into the behavior body. Do not claim an existing test passed without running it or citing valid recorded evidence.

## Quality And Completion

Apply the authoring semantic check to each rule; audit actors, guards, decisions, state transitions, integrations, data effects, success/failure and validation across the module as applicable. Preserve depth through operation-level rules rather than forcing every dimension into every sentence.

Rewrite statements such as:

- `The system implements related operations through the listed files.`
- `The module supports CRUD/management/processing.`
- `The system handles errors.`

They lack operation-specific inputs, effects or named failure outcomes. A large module with only a few broad statements needs a coverage check, not automatic extra prose.

A module may be marked complete only when its relevant behavior chains were inspected and translated into contracts. Record:

- inspected entrypoints, logic, persistence models, tests/configuration/docs and visible surfaces;
- rule references for evidenced branches/flows;
- remaining uninspected files or branches and their scope impact;
- actual validation/review status.

If core behavior is uninspected, label the output `partial draft`, `evidence map` or `coverage report`, not a completed module spec. Do not mask missing analysis with `TODO: deep-read later`. For large projects, repeat scoped read → derive → audit per module; repository-wide inventory is a separate output only when requested. Prefer depth over breadth.

## Output And Promotion

Use the minimal shape from `references/spec-authoring.md`: behavior statements, validation mapping, source trace and known gaps. Put failure/data constraints with their owning rules; retain separate sections only for distinct facts. Temporary drafts may link existing coverage/implementation evidence without duplicate logs; formal output follows the independent-contract boundary.

Brownfield frontmatter retains:

```yaml
doc_role: spec
authority: draft
status: experimental
confidence: low|medium|high
sources:
  - <source path or repo/commit>
```

Drafts become normative only after review or successful use in a real implementation/validation cycle. Promotion is blocked by:

- file/function inventories standing in for behavior;
- uninspected in-scope behavior chains or missing source evidence;
- unknown validation/review status;
- unresolved assumptions presented as facts.

Missing information remains an explicit gap. Narrow completion to inspected boundaries; formatting is not evidence. Authorized promotion follows `references/change-workflow.md`: retain source/coverage limits, remove draft execution associations, record review in the existing spec log and delete successful change inputs if present. Do not create a change workspace or task solely to promote a standalone draft.
