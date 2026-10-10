# Maintaining an Existing Prompt

## Goal

Improve an existing prompt through the smallest reviewable, verifiable change while preserving validated behavior and downstream compatibility. Apply [Direct Instruction Writing](../SKILL.md#direct-instruction-writing) across the full requested scope.

## Pre-Edit Checks

1. Locate the prompt, callers, and owning boundary.
2. Read complete semantic units before editing; do not edit from search hits alone.
3. Inventory responsibilities and distinguish familiar knowledge from prompt-specific contracts sentence by sentence, including mixed paragraphs.
4. Identify the evidenced reason for change.
5. Assess compatibility risk at the owning boundary and downstream consumers.

## Instruction Necessity And Scope

For the changed behavior, classify candidate rules before shortening or strengthening them:

| Rule type | Default decision |
| --- | --- |
| Safety, permission, credentials, or data/worktree ownership | Preserve; name the protected action and actual approval boundary. |
| Tool schema, runtime constraint, or deterministic dependency | Preserve exact semantics at the correct entrypoint. Specificity alone is not overconstraint. |
| Team acceptance requirement | Preserve applicability, required evidence, and completion conditions. |
| Ordinary workflow preference | Express a default with room for task-relevant judgment unless a real dependency requires order. |
| Familiar knowledge explained as instruction | Apply Direct Instruction Writing; retain the selected behavior, applicability, and prompt-specific differences. |
| Repetitive compensation for presumed model weakness | Remove or merge the encouragement while retaining the goal or demonstrated failure constraint. Do not invent historical motivation. |
| Duplicate normative rule | Keep one owner and route other entrypoints to it; reconcile differences in strength such as “prefer” versus “must”. |

For autonomy, clarification, approval, recovery, or completion changes, read `references/autonomy-and-completion.md`. Follow references only where a suspected issue requires them; do not preload a repository map or document stack for every edit.

## Patch Strategy

- Change the smallest section that causes the problem.
- Preserve validated rules unless they conflict with the new goal or are obsolete.
- Merge duplicates instead of appending patch-like instructions.
- Distill logs, review comments, and failure transcripts into stable constraints; do not paste them directly.
- Before major rewrite, list semantics to preserve, remove, and migrate; ask for confirmation when needed.
- For public API prompts, preserve old fields, entrypoints, and default behavior by default. Add capabilities as optional or gradual behavior.
- Under size, lint, or duplication pressure, manually keep, delete, merge, migrate, or split semantics through targeted patches. Never use scripts, bulk replacement, automatic shortening, or programmatic rewriting merely to pass checks.

## Rule Migration And Indirect Entry Points

Before moving a rule out of an always-on prompt, verify:

- The destination is loaded before the first relevant action, not merely discoverable after a failure.
- Authority and applicability are preserved. Security, identity, or ownership rules needed before Ability loading remain at that boundary; do not silently demote them into optional reference text.
- Templates, examples, role files, generated fragments, and other callers no longer reintroduce the old behavior. Inspect actual execution sources, not just the primary prompt or example.
- One source owns the normative rule; routes do not copy its full procedure or force every scenario to load all references.

For AgentSkill routing or fragment placement, load `ability-creator` and follow its instructions.

## Common Maintenance Types

### Unstable Output Format

- Define missing prompt-specific schema or field constraints and remove conflicting instructions. Add examples only for unresolved ambiguity.
- If a program parses the output, prefer strict structured-output capabilities.

### Agent Skips Required Actions

- Establish that the action is required by the goal, tool contract, safety boundary, or acceptance criteria; do not strengthen a preference solely from reviewer anxiety.
- Put genuine requirements at the relevant workflow or completion boundary. Specify tool dependencies, validation evidence, and bounded failure handling where necessary.
- Replace weak wording with a clear requirement only for that scope. Remove duplicate reminders rather than stacking stronger prohibitions.

### Context Bloat

- Remove repeated teaching rather than moving it to another reference.
- Keep necessary low-frequency detail on demand only when authority and timely availability are preserved.
- Select task-relevant context; shorten manually without changing requirements.

### Model or API Change

- Confirm target model family and message-role semantics.
- Add or update fixtures/evals for production prompts.
- Keep the prompt builder versionable, reviewable, and rollback-friendly in code.

## Validation Workflow

Review diff semantics across the full requested scope. Confirm removed explanations did not remove obligations, conditions, boundaries, or public behavior. Complete relevant required checks and reuse current evidence; use `references/quality-checklist.md` for final review. Further validation needs changes, failures, unresolved concerns, or an explicit requirement.

Report static contract, tool-integration, and model-behavior evidence separately. Claims about reduced pauses or improved routing/completion require selected-model/harness behavior trials, not lint or prompt dumps.

Protect meaningful behavior contracts rather than exact ordinary prose in automated checks. Record material decisions and untested limits; impose no mandatory full matrix, new test count, token-reduction target, or repeated self-check.
