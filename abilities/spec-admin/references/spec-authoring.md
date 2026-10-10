# Spec Authoring

Purpose: encode a complete behavior contract in the fewest useful tokens for an independent LLM reader. A fresh Agent should recover the intended decisions from the spec and its explicit dependencies. This reference owns writing style for all SpecAdmin entrypoints and templates; `spec-optimization.md` owns authorized optimization of existing specs.

## Inputs And Workflow

1. Read the user intent, relevant rules/specs and evidenced API/code behavior; identify capability, actors, triggers, scope and consumers.
2. State the behavior once in its owning spec. Choose the compact representation below, retaining exact governed terms, paths, schema keys, enum values, error strings, numeric limits and ordering.
3. Include the conditions that determine success/failure: authorization, observable result, state/data effects, precedence, exceptions and recovery when applicable.
4. Map behavior to sufficient acceptance evidence. Keep expected observations and material coverage limits in the spec; detailed implementation results remain with their existing evidence owner. Formal output follows the boundary below.
5. Check semantic coverage and affected references, then deliver the requested spec without creating an authoring task. Future implementation planning follows `taskadmin-integration.md`; editorial corrections and optimization follow `SKILL.md`. Apply the Vault/index/log contract to durable writes.

## LLM-Oriented Contract

Use stable descriptive rule names, unique within the owner. Keep the consumer-required name/anchor when editing an existing rule. Prefer the least costly representation that preserves the full decision:

| Behavior shape | Representation |
| --- | --- |
| One independently verifiable behavior | Named clause with condition, obligation and observable result. |
| Several rules share actor, scope or prerequisite | Define the common premise once, with explicit applicability; state each rule's distinct outcome and exceptions. |
| Input combinations or precedence choose outcomes | Small condition/result table or explicit ordered precedence. |
| State or temporal order changes the result | Ordered steps or transitions including failure, cancellation and terminal behavior. |
| A boundary needs clarification beyond the rule | One focused example carrying that additional information. |

Default clause:

```markdown
- **<stable name>**: <applicable condition>, <subject> MUST <observable result>; <exception or precedence>.
```

Reconstruct the rule from its complete semantic facts, choosing their most compact common home. A prerequisite, invariant or consequence stated once applies throughout its explicit scope; examples and validation reference that rule. Fold a scenario's unique error, side effect or boundary into the owning clause/table when the same decision remains clear. Keep a separate scenario when its ordered interaction itself adds information.

Use natural-language clauses, standard technical vocabulary, lists and tables. Repeated subjects may be implicit within an explicitly scoped block. Distinct permissions, transactions and failure states remain individually recoverable. A useful section contributes a distinct fact, contract boundary or acceptance gate. Rule identity and consumer-required anchors remain stable; explanatory layout follows the resulting contract.

Use intentional MUST/MUST NOT, SHOULD/SHOULD NOT or MAY; SHALL/SHALL NOT remain valid. Preserve obligation strength and project vocabulary. Chinese contracts may use 必须／不得, 建议／不建议 and 可以 respectively. An imperative block may declare once that its clauses express SHALL obligations while explicit optionality remains optional.

Retain every fact affecting pass/fail: actor, trigger/precondition, result, side effects, failure, limits, exceptions and priority. Include the applicable subset for each behavior. Write coupled outcomes together; separate different conditions or independently owned behavior. Rule text that already determines pass/fail also serves as behavioral acceptance. Safety warnings, irreversible-action confirmations, ordered migration steps and acceptance criteria retain the detail needed for unambiguous execution.

## Positive Examples

Examples illustrate representation; the actual source supplies domain facts.

### Conditional publication and execution eligibility

```markdown
- **Publish one support file**: On Ability load, effective `include: ["data/public-schema.json"]` publishes the default-hidden file as `#<ability>[/data/public-schema.json]` in references/completion. An `@` script entry additionally requires selection by the existing executor or executable-permission rules.
```

The clause preserves effective metadata, publication timing, address/surfaces and the independent execution gate.

### Exact input and failure boundary

```markdown
- **Timeout validation**: `timeout` MUST be an integer in `1..60` inclusive; other input returns `INVALID_TIMEOUT` before scheduling work.
```

This retains type, inclusive bounds, exact error and failure timing in one rule. Defaults and coercions are included when established by the source.

### Scoped priority

```markdown
- **Exclude precedence**: When effective `include` and `exclude` both match a file, the public catalog MUST omit it; exact-reference access remains governed by its separate owner.
```

The decision stays scoped to catalog disclosure and points to the separate access contract.

### Terminal-state ordering

```markdown
- **First response wins**: A pending request completes once with the first valid response. Later responses leave its result and terminal state unchanged and emit no further completion.
```

Expand into an ordered sequence when a distinct race, cancellation boundary or state transition requires additional evidence.

### One contract owns shape, failure and projection

```markdown
### Requirement: Structured Vector3 Value

For a `Vector3` descriptor, input through `value` or `--value-json` MUST be a native JSON array of exactly three finite numbers; wrong kinds, lengths or components return the existing coercion-error family before mutation. Writes report `type: "Vector3"`; every emitted/read value uses the same numeric `x`, `y`, `z` array projection. For example, `[-2.5,0,1]` yields `[-2.5, 0.0, 1.0]`.
```

This single rule carries accepted shape, numeric validity, source inputs, rejection/error timing, state preservation, result type, projection order and the normalization example. Its requirement identity remains available while the facts share one normative home.

## Acceptance Evidence

Read `#task-admin[/references/execution-protocol.md]`, especially `Validation Strategy`, before selecting acceptance mappings.

- Map each changed rule/group to the smallest sufficient check and expected observation. A focused check may provide both current acceptance and regression protection.
- For UI appearance/interaction, use the affected path in the actual app and observable result under the Runtime UI Validation Boundary. Test-code authoring follows its explicit user/mandatory-rule authorization. Existing build/static checks supplement actual observation.
- Distinguish specification, automated, live and human evidence. Preserve actual `validation.automated`/`validation.human` values (`passed|failed|not-run`) and existing coverage qualifiers. Tool-driven observation is automated evidence; user review is human evidence. `human: not-run` is a gate only when human review is required.
- Keep expected behavior and material current coverage gaps locally recoverable; task records own actual commands/results. Formal contracts do not depend on task links to recover their behavior or limitations. Dated evidence retains its original scope/status; current review does not relabel historical failures/not-run results. Required unavailable checks follow bounded recovery/handoff with the exact remaining gap; user-accepted exceptions preserve the actual failed/not-run result.

```markdown
- Settings save — interact with the app, save a value and reopen the page → visible save feedback and retained value. Actual commands/results stay with existing implementation evidence, not the formal contract.
```

## Minimal Document Shape

`assets/spec-template.md` and `assets/delta-spec-template.md` provide scaffolds. Publish the relevant content in the least repetitive structure:

- purpose and ownership boundary;
- named requirements with shared premises, applicable exceptions and failure/data constraints;
- sufficient acceptance observations and current material gaps;
- source/stable-dependency references; no task association is required.

Each behavior has one authoritative statement. Reference it from examples, validation or peer owners when needed. Consolidate source/evidence mapping by owning rule group. Retain directly needed validation limits alongside the contract; detailed history and execution records stay with their task/log owner. Brownfield coverage follows `bootstrap-from-code.md`.

### Independent Formal Output

Formal specs contain current behavior, scope/permissions/failure/compatibility boundaries, expected acceptance, actual material coverage limits and direct code/test/research or formal-spec dependencies. They SHALL NOT contain implementation-task fields/IDs/links, change IDs/paths/backlinks, proposal/delta trace catalogs, cleanup history, volatile TODO/debug logs or task lifecycle events. Remove these associations from frontmatter, body, validation, source lists and current navigation during promotion; replace needed behavior dependencies with their formal owner rather than dropping conditions or safety rules.

The prohibition concerns execution provenance, not the governed product: TaskAdmin or change-management behavior may name its real APIs/paths/schema when that is the spec's subject. Do not erase those requirements to satisfy a keyword scan. Preserve accurate failed/partial/not-run qualifiers and source attribution; detailed execution/review history remains in existing tasks/logs with one-way references to formal owners.

New draft/proposal/delta artifacts need no task fields. Existing temporary implementation links are handled by `taskadmin-integration.md`; never create a task to supply missing authoring provenance. `change-workflow.md` owns promotion ordering and deletion of successfully promoted inputs.

Default stable/draft path: `.maxa/specs/<capability>/spec.md`. Preserve the existing lifecycle schema/conventions; unvalidated drafts use `authority: draft`, accepted behavior may use `authority: normative`. Delta `authority: proposed` and acceptance lifecycle remain owned by `change-workflow.md`.

## Compatibility And Migration

Read existing `### Requirement`, `#### Scenario`, GIVEN/WHEN/THEN and equivalent forms. For authorized edits, choose between retaining consumer-required grammar and converting the affected content into the compact contract above.

Before changing headings/anchors, check inbound references and downstream validators/parsers. Protect the exact consumer-required subset: retain required names/anchors or provide an explicit mapping with updated affected references. Consolidate unreferenced explanatory headings into the owning rule when their facts fit its compact contract. Validate compatibility through actual consumer requirements and reachable references; the resulting heading/paragraph/scenario counts follow the semantic organization. Preserve unrelated content; batch optimization uses the explicit target inventory and checks in `spec-optimization.md`.

Delta matching uses the existing name whether heading or compact label. MODIFIED provides complete resulting behavior; REMOVED identifies the old rule and reason; renames map old to new and reconcile affected consumers. External-tool compatibility is established by the actual consumer grammar/checks.

## Semantic Check And Recovery

Compare old/source and new contracts by rule or independently verifiable behavior group: conditions, actor, obligation strength, result, permissions, side effects, failure, exception, ordering and limits. Verify both retained facts and the basis for each resulting assertion. Confirm a reader can determine the same outcomes and recognize the same unknowns from the new spec and explicit dependencies.

Validate reference reachability and compatibility after structural changes. For scope-wide optimization, use the reproducible measurement and bounded fresh-reader check in `spec-optimization.md`. A blocker affects only dependent changes: retain the established contract, name the unresolved meaning/evidence/compatibility issue, and ask one targeted question when a decision is required. Resume publication after the required meaning/consumer/evidence checks pass.
