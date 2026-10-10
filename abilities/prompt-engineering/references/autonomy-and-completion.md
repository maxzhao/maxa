# Autonomy, Approval, And Completion Contracts

## Purpose And Scope

Use when creating or repairing Agent instructions about initiative, clarification, permission, failure recovery, validation, or stopping. This reference defines writing decisions, not permission to bypass the active host's safety or tool protocols. Do not load it for unrelated wording or formatting edits. Apply [Direct Instruction Writing](../SKILL.md#direct-instruction-writing) to the scoped continue/stop contract.

## Decision Contracts

- **Internal verification**: Say who checks what and when work can proceed; do not turn an ambiguous “confirm” into an approval gate.
- **Clarification**: Ask only when missing information materially affects the result and cannot be safely inferred or checked. Reuse explicit user intent.
- **Approval**: Name the restricted action and authority. Preparation is not permission to execute the final action; an absent response is not approval.
- **Notification**: Delivery grants no approval and does not automatically stop other authorized work. Respect an explicit user instruction to stop.
- **Completion**: Report the result and material limits when the outcome and required evidence are satisfied; no mandatory extra revision, review round, or “should I continue?” prompt.

Do not recast real safety, credential, irreversible-action, or team approval requirements as obsolete caution. If an active higher-priority rule forbids an action, writing advice cannot override it.

## Continue And Stop Boundaries

Authorize known-safe, reversible work inside the user's scope without requesting approval for every step. Plans and internal checkpoints are not user decisions unless explicitly stated.

When a decision or access requirement blocks one branch, pause actions that depend on it. Continue independent, already-authorized preparation only when it does not prejudge the answer or create the prohibited effect. Stop the whole workflow when requested or when no useful safe work remains; report the exact blocker rather than claiming completion.

A scoped request ends when its outcome is delivered. It does not authorize unrelated improvements, deployment, indefinite monitoring, or endless exploration.

## Tool And Context Recovery

Distinguish failure of one tool path from failure of the goal. Describe bounded correction using the actual error and supported, authorized alternatives. Preserve host retry limits and safety denials; do not prescribe unlimited retries or evade restrictions through a different tool.

Escalate when required work cannot proceed with available authorized options, or a real user decision/access grant is needed. A child reporting `blocked` does not establish that the main Agent is also blocked; inspect the reported cause and available recovery options.

Apply the Core Principles for context selection and evidence reuse; avoid ceremonial full rereads or absolute no-reread rules. Context size alone does not authorize compression; preserve the host's compression authorization and recovery protocol.

## Validation And Done

Define done from the requested output and applicable acceptance criteria, including required tests or runtime inspection. Appropriate validation remains necessary across models; do not remove it merely because a model tends to check its own work.

Once current relevant checks pass, broaden or repeat only for new changes, failures, unresolved concerns, or an explicit acceptance requirement. Do not force all tests for every small edit, mirror trivial implementation in low-value tests, or set default rejection verdicts, scores, or revision counts.

If validation is blocked, record the exact attempted check, blocker, and remaining risk. Missing required evidence is not a proven implementation defect, but also not proof of completion. A passing scoped review is not approval for a consequential next action.

## Boundary Checks

Select checks from changed contracts, relevant failure evidence, and unresolved boundary ambiguity. Use `references/quality-checklist.md`; do not run a fixed example suite for every edit.

Report static contract checks, actual tool integration, and model-behavior trials separately. Static review cannot establish pause frequency, routing accuracy, or improved model performance. If a case exposes conflicting authority or a genuine approval requirement, preserve that boundary and repair the proposed wording instead of weakening safety.
