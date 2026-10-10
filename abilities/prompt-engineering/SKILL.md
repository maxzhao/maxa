---
name: prompt-engineering
description: "Guide Agents to create, maintain, optimize, and repair prompts, system prompts, developer instructions, task instructions, and prompt templates for LLM or Agent workflows."
compatibility: Requires Maxa Ability runtime.
---
# Prompt Engineering

Treat prompts as maintainable behavior contracts. Optimize future models or Agents to produce verifiable results under explicit inputs, context, tools, and constraints.

## Core Principles

- **Write a proportionate contract**: Define goal, scope, inputs, tools, output, failure handling, validation, and completion. Preserve safety, permissions, deterministic dependencies, and acceptance requirements; specify an itinerary only when real dependencies require it, not to compensate for presumed model weakness.
- **Layer authority**: Separate stable rules from lower-authority user input, dynamic context, references, and examples; never let the latter override rules.
- **Select context and examples**: Include only task-relevant context. Reuse current evidence; recover missing information through the smallest necessary semantic unit. Add examples only for concrete ambiguity in prompt-specific formats, mappings, or boundaries.
- **Keep one normative owner**: Define each behavior once and route other entrypoints to it. Moving rules must preserve their authority and availability before the first relevant action, including indirect template and role-file use.
- **Scope autonomy and approvals**: Continue authorized, reversible work within the request. Distinguish internal checks, clarification, approval, and notification; stop dependent actions for concrete blockers or required approvals, not hypothetical risk or routine status messages.
- **Use existing knowledge without losing contracts**: Apply Direct Instruction Writing below when creating, maintaining, or repairing prompts. Preserve safety-critical clarity, exact code, technical identifiers and literals, validation commands, and public contracts.
- **Maintain manually and incrementally**: Prefer small, reviewed semantic patches. Before a major rewrite, inventory responsibilities and compatibility constraints. Never use scripts, bulk replacement, or automatic shortening merely to pass lint, size, or format checks.
- **Complete from evidence**: Use proportionate checks and required acceptance evidence. Reuse valid results; broaden or repeat only for changes, failures, or unresolved concerns. Do not prescribe rejection verdicts, arbitrary scores, or revision counts. Separate static contract, tool integration, and model-behavior evidence.
- **Remain portable**: Exclude secrets, private paths, one-off logs, and local preferences. Scope platform/model-specific guidance to verified host behavior; stronger models do not remove safety, permission, or team acceptance requirements.

## Direct Instruction Writing

Write for the executor. Use your own knowledge to distinguish familiar knowledge from prompt-specific contracts, sentence by sentence, including paragraphs that mix requirements with explanation.

- **Name familiar knowledge**: Use precise names for familiar concepts, formats, and methods. Omit definitions, standard procedures, explanatory enumerations, and obvious examples that add no requirement.
- **State the contract**: Specify the goal, selected behavior, applicability, environment differences, and required output. Knowing a method does not select it or make it mandatory. Include only fields relevant to the prompt.
- **Justify detail by need**: Add detail for concrete ambiguity, actual dependencies, environment/interface differences, or evidenced executor needs. When the target executor differs from you, account for its known capabilities; assume neither identical knowledge nor a need for extra teaching from a model-family label alone.
- **Remove non-operational prose**: Delete filler, repetition, and self-justification that add no execution semantics. Rewrite defensive scope or exceptions as explicit conditions; replace vague hedging with the actual uncertainty or evidence requirement.
- **Preserve obligations and boundaries**: Retain safety, permissions, prohibitions, dependencies, acceptance criteria, public behavior, and material uncertainty. Keep prerequisites and safeguards available before the governed action. Preserve requirement strength and distinctions between defaults, preferences, options, and requirements; directness must not increase certainty or obligation.

Judge semantic function, not phrasing. Retain negative rules and contrasts when they define meaningful boundaries; do not use phrase blacklists. Remove redundant teaching, not requirements, conditions, or constraints.

## Scenario Routing

- Create from scratch: read `references/create-new-prompt.md`.
- Maintain or improve existing prompt: read `references/maintain-existing-prompt.md`.
- Repair noncompliant, conflicting, oversized, or drifted prompt: read `references/repair-noncompliant-prompt.md`.
- Choose structures, examples, templates, context organization, or output patterns: read `references/patterns-and-templates.md`.
- Final review: use `references/quality-checklist.md`.
- Source/adoption review: read `references/source-analysis.md`.
- Design or repair autonomy, clarification, approval, recovery, or completion behavior: read `references/autonomy-and-completion.md`.

Load only scenario-relevant references. This Ability owns instruction semantics; for Ability descriptions, triggers, resource placement, or always-on fragment integration, load `ability-creator` and follow its instructions.

## Default Workflow

1. Identify the prompt location, executor, goal, output consumer, execution context, required contracts, relevant failure evidence, and validation method.
2. Apply Direct Instruction Writing across the full requested scope to choose the smallest effective contract. Add examples, rubrics, variables, or stages only for concrete unmet needs.
3. Produce or patch the prompt and any affected tests, examples, templates, or callers.
4. Check that removing explanations preserved obligations, conditions, boundaries, and public behavior. Complete relevant required validation; report static, tool-integrated, and model-behavioral evidence separately, with material untested limits.

Avoid persona-only prompts, raw logs or external articles, prohibition piles without a positive path, unnecessary reasoning stages or full chain-of-thought, confidence scores, self-grading, excessive examples, unevaluated fixed metrics, wholesale copies of other capabilities, and density that obscures safety-critical content.

