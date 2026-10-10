# Task Creation Guide

Purpose: plan unperformed work in one executable TaskAdmin workspace for a future Agent with fresh context.

## Entry Rules

Use this guide when the user asks to register work as TaskAdmin, create a task, or convert current analysis into an implementation task.

- Search/read only context needed to make the task executable. Consult project rules, relevant specs/code, peer tasks or scoped knowledge only where they determine this task; this is not an unconditional reading checklist.
- Create a task only for work still to be performed. Do not backfill tasks/checklists to record completed analysis, authoring, implementation or validation. Existing facts may constrain the plan; they are not planned work.
- Specification drafting/revision/review is not specification implementation; use specs as inputs to future implementation plans, not a reason to create writing tasks.
- Do not create a shell task that tells the next Agent to repeat current analysis.
- Ask one targeted question only when an unresolved decision changes scope, behavior or implementation ownership.
- Keep cohesive work in one task. Create multiple peer tasks only for separate durable outcomes; use ordinary integer dependencies for required order.
- TaskAdmin never creates structural parent/subtasks.

## Work Type And Creation Gate

An `implementation` task is the default. Before calling `create_task.py`, complete the analysis needed to determine:

- applicable project rules, specifications and scoped project knowledge;
- current code behavior and implementation ownership;
- selected approach, affected paths and relevant compatibility constraints;
- acceptance criteria and the smallest sufficient checks selected under `Validation Strategy` in `references/execution-protocol.md`;
- decisions that would change scope, public behavior or ownership.

Publish an implementation task when scope, ownership, approach and the next concrete actions are clear. Stop pre-creation analysis at that point; local implementation details may be resolved during scoped execution. Do not leave open-ended items whose purpose is to discover what to change, where to change it or which approach to choose. Reading named authoritative paths, checking preconditions and bounded reproduction/diagnosis are legitimate execution steps; creation readiness does not require those checks to have passed already.

An `exploration` task is allowed only when the user explicitly requests investigation, research, comparison, feasibility work or a spike. Do not convert an insufficiently understood implementation request into an exploration task on the user's behalf. An exploration task must still define a bounded question, evidence scope, stop condition and concrete deliverable; it must not claim an implementation decision that the exploration is intended to produce.

Existing tasks without an explicit work type remain valid and are treated as implementation tasks unless their plan clearly records an explicit exploratory outcome.

## Required Plan Content

Prepare `plan.md` using only relevant fields from `read(path="#task-admin[/assets/plan-template.md]")`. A simple task needs goal/scope, necessary paths, concrete steps and minimum acceptance/validation; add the following detail only when it affects implementation or recovery:

- work type (`implementation` by default, or explicitly requested `exploration`);
- goal and observable outcome;
- in/out scope and non-goals;
- authoritative inputs and paths;
- current evidence and constraints;
- selected implementation approach and decisions, or the bounded question/evidence/stop condition/deliverable for an exploration task;
- affected modules/source paths;
- risks and failure handling;
- acceptance criteria;
- validation plan: smallest sufficient checks and expected results; runtime targets, separate regression coverage or recovery only when needed.

When the work comes from an external specification system, include a concise reference block without copying the full spec:

```markdown
## Spec References

- Change/proposal: <path>
- Delta specs: <paths>
- Stable owners: <paths>
```

## Required TODO Content

Prepare `todo.md` using only relevant fields from `read(path="#task-admin[/assets/todo-template.md]")`. Keep the executable checklist and current/next state; add changed files, actual check results and blockers as work progresses, not placeholder tables for every possible fact:

- ordered executable checklist;
- current status/phase and next action;
- required context/supporting document links;
- known blockers and creation-ready facts needed for execution.

For implementation tasks, use only concrete implementation and validation actions; do not add research, investigation, option selection or architecture-discovery placeholders. For explicitly requested exploration tasks, use bounded evidence-gathering actions that converge on the plan's stop condition and deliverable.

Keep TODO items proportional. One check may cover primary validation and regression; record it once. Do not add a separate test track, rejected-alternatives section or supplementary report without a concrete need. For UI work, plan actual observation → smallest fix → affected-path recheck under the execution protocol, not test-code development. Any authorized test-writing item must cite the explicit request or mandatory rule allowed by the Runtime UI Validation Boundary; an Agent-written plan or coverage concern cannot grant that permission.

## Publication Workflow

1. Confirm the intended current tag before publication; explicitly switch if needed. Prepare complete UTF-8 plan and TODO files in temporary paths.
2. When parameters are uncertain, invoke titled `run(scope="tool", command="@task-admin:/scripts/create_task.py", args=["--help"])`.
3. Resolve project/input paths and task name, then pass these run fields (literal CLI strings; no shell expansion):

```yaml
title: "Publish prepared TaskAdmin task"
scope: tool
command: "@task-admin:/scripts/create_task.py"
args: ["--project-root", "<PROJECT_ROOT>", "--name", "<task name>", "--priority", "medium", "--plan-file", "<PLAN_FILE>", "--todo-file", "<TODO_FILE>"]
```

Optional inputs:

- `--description <TEXT>`
- `--dependencies 1,2`
- `--workspace <NAME>`

The script validates references, publishes `_meta.yaml`, `plan.md` and `todo.md` as one task workspace, and returns exact paths. Delete caller-owned temporary inputs after successful publication.

## After Creation

- Use returned task ID/path; do not construct paths manually.
- Read the published plan/TODO when verifying content.
- Use `manage_deps.py` / `analyze_deps.py` when dependency changes need validation.
- Report task ID, tag, workspace path, dependencies, key references and next executable action.

## Failure Handling

- Missing/invalid dependency: fix the requested peer IDs; do not create placeholders.
- Partial script failure: do not claim task creation; inspect the exact error and confirm no published `task_NNN/` exists before retry.
- Duplicate existing work in the current checkout: update the existing task plan/TODO rather than create another task. If another Git branch or Worktree already created overlapping TaskAdmin work, do not improvise an identity merge here; follow `references/workspace-reconciliation.md` before Git integration.
- Insufficient context for an implementation task: continue pre-creation analysis or ask one targeted question when required; do not publish a placeholder task. Record only assumptions that do not decide scope, public behavior, ownership or the implementation approach.
