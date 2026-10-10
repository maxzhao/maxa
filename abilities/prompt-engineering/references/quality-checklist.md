# Prompt Quality Checklist

## Usage

Use applicable checks across the full requested scope after creating, maintaining, or repairing a prompt. Select by changed behavior and risk, not as a mandatory all-items loop. Reuse current evidence; report material findings, fixes, and untested limits. Apply [Direct Instruction Writing](../SKILL.md#direct-instruction-writing).

## Knowledge And Contract

- [ ] Familiar knowledge is named rather than retaught; remaining detail resolves concrete ambiguity, dependencies, environment/interface differences, or evidenced executor needs.
- [ ] Mixed paragraphs were checked sentence by sentence, not retained wholesale because one sentence contains a requirement.
- [ ] Removed explanations did not remove goals, selected behavior, applicability, obligations, conditions, boundaries, or public contracts.
- [ ] Target-executor assumptions follow known capabilities, not identical-knowledge assumptions or presumed model weakness.
- [ ] The prompt contains only role-relevant fields and task-relevant context; templates and examples are not filled mechanically.

## Authority And Behavior

- [ ] Stable rules are separated from lower-authority inputs, context, and examples; user-controlled material cannot override them.
- [ ] Each normative behavior has one owner. Migrated rules retain authority and availability before the first relevant action, including indirect entrypoints.
- [ ] Requirement strength and material uncertainty are preserved. Safety, permissions, prohibitions, dependencies, and acceptance criteria remain explicit.
- [ ] Autonomy, clarification, approval, recovery, and completion use `references/autonomy-and-completion.md` where applicable.
- [ ] Procedures are executable with the actual interfaces, and the output contract is usable by the intended consumer.

## Context, Examples, And Portability

- [ ] Required current evidence is reused; missing, changed, incomplete, or expired context is recovered through the smallest necessary unit.
- [ ] Examples resolve a specific ambiguity or failure, match the required output, and remain separate from real inputs.
- [ ] Shared prompts exclude secrets, private paths, one-off logs, and local preferences; model/platform guidance is scoped to verified behavior.
- [ ] Code, technical identifiers and literals, validation commands, and public behavior contracts remain exact.
- [ ] Wording is direct and information-dense without compressing safety warnings, irreversible-action confirmations, ordered steps, acceptance criteria, migration notes, security findings, or other ambiguity-sensitive content.

## Validation And Maintenance

- [ ] Changes preserve compatibility unless explicitly authorized; affected builders, loaders, callers, references, and examples remain consistent.
- [ ] Relevant required checks are complete and current. Broader or repeated checks have a changed behavior, failure, unresolved concern, or explicit requirement.
- [ ] Static contract, tool-integration, and model-behavior evidence are distinguished; lint and generated dumps are not behavioral trials.
- [ ] Automated checks protect meaningful contracts rather than exact ordinary prose; no arbitrary scores, case counts, token ratios, or revision loops were introduced.
- [ ] Blocked validation reports the exact attempted check, blocker, and remaining risk without claiming success.
