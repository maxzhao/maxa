# Creating a Prompt from Scratch

## Goal

Create an executable, verifiable, maintainable prompt for a new LLM or Agent task. Default audience: future Agent or application runtime, not human-facing explanatory prose. Apply [Direct Instruction Writing](../SKILL.md#direct-instruction-writing).

## Input Collection

Establish from available context before writing; these are internal checks, not a request for the user to approve each field:

- Prompt location and target executor's known capabilities.
- Objective, inputs, tools, trust boundaries, and output consumer.
- Required contracts, failure evidence, and applicable acceptance checks.

If the prompt governs autonomy, clarification, approval, recovery, or stopping, read `references/autonomy-and-completion.md`. Reuse explicit intent and checkable facts; ask only for a concrete unresolved decision. Do not load that reference for unrelated output-format work.

## Structure And Output

Choose only sections needed by the contract; do not fill a fixed template mechanically. Name the output format and define its prompt-specific schema, fields, or rendering constraints. Add workflow steps only for actual dependencies, and examples only for concrete ambiguity.

## Creation Steps

1. Define the task contract and output consumer.
2. Put stable rules before dynamic context and mark trust boundaries.
3. State desired behavior first; add prohibitions only for necessary boundaries.
4. Select formats and methods under Direct Instruction Writing; use `references/patterns-and-templates.md` only when relevant.
5. Remove non-operational prose and repeated teaching across the complete prompt.
6. Select normal and boundary checks appropriate to the changed behavior and risk; complete required validation and state material gaps. Do not add a fixed case count or unnecessary review loop.

## Model Differences

Verify the selected model and harness before adding model-specific guidance. Preserve tool protocols and acceptance requirements across models. For structured output, define the required schema or field constraints rather than relying on appearance alone.

## Few-Shot Example Selection

Use examples for an identified prompt-specific ambiguity or evidenced failure, not by default for a task category. Match the required output, separate examples from real inputs, and preserve privacy. Select examples by the meaningful distinctions they resolve, not a fixed count.

## Validation

Use applicable items in `references/quality-checklist.md`. Confirm the target consumer can use the output; select relevant normal, boundary, missing-information, conflict, or tool-failure cases. Distinguish static contract checks, tool integration, and model-behavior trials, and report important untested behavior. Passing required current checks permits completion unless a change, failure, or unresolved concern justifies further work.
