# Source Screening and Adoption Decisions

## Source Scope

This Ability derives principles from these source types. The list preserves reviewability; do not copy external source text directly into runtime prompts.

- OpenAI official prompt engineering guidance.
- All files from `dzackgarza/ai` under `opencode/abilities/prompt-engineering`.
- All prompt-engineering files from `Dokhacgiakhoa/Agent-skills-setup-for-AntiGravity`.
- The `prompt-engineer` skill from `RightNow-AI/openfang`.
- All prompt-engineering skill files from `levalencia/agent-god-mode`.
- The `prompts-writing` skill from `ModelEngine-Group/nexent`.
- The prompt-engineering skill from `inference-sh/skills`.
- [`Kiterlin/anti-defensive-writing`](https://github.com/Kiterlin/anti-defensive-writing), specifically its `SKILL.md` rules for removing unnecessary defensive framing while preserving necessary precision.

## Adopted Principles And Owners

This file records provenance and adoption boundaries, not a second copy of the writing rules.

| Owner | Adopted responsibility |
| --- | --- |
| `SKILL.md` | Core Principles and Direct Instruction Writing, including use of the author's existing knowledge without losing prompt-specific contracts. |
| `references/patterns-and-templates.md` | Pattern selection, task-specific output contracts, context, variables, and examples. |
| `references/maintain-existing-prompt.md` | Incremental maintenance, rule ownership, and migration compatibility. |
| `references/quality-checklist.md` | Contract preservation and proportionate evidence. |

## Adopted as Conditional Guidance

- Chain-of-thought: do not request full reasoning disclosure by default; ask for concise analysis, key evidence, or runtime-supported hidden planning when needed.
- Confidence scores: omit by default; use only when calibration, ranking, or human review makes them valuable.
- A/B testing and statistical significance: suitable for high-traffic production prompts; ordinary Agent prompts can use representative examples and human acceptance checks.
- Multi-agent work, self-consistency, repeated sampling: useful for high-value complex tasks, not default structures.
- Model-specific techniques: use only when target model/runtime is known; do not make them cross-project universal rules.

## Excluded Content

- External platform commands, installation instructions, and frontmatter fields such as `belt`, `npx skills`, or `allowed-tools`.
- Large image/video generation prompt material; route to image generation or `genai`-related Abilities.
- Unverified fixed numeric targets: exactly 10 test cases, 90% pass rate, or 30–50% improvement.
- “Must research prompt best practices online every week.” Re-checking should depend on model/API changes, production risk, and user need.
- “Never create prompts from scratch.” Creating from scratch is reasonable when requirements are clear and validation is possible.
- “Every Agent prompt must include a Reference Skills section.” Maxa combines capabilities through Ability Gate, project rules, and explicit loading, not hardcoded internal Ability identifiers.

## Model-Migration And Host Guidance

Relevant source entrypoints:

- OpenAI model guidance: `https://developers.openai.com/api/docs/guides/latest-model` (mutable; verify the selected model when using model-specific claims).
- OpenAI skill guidance: `https://developers.openai.com/codex/build-skills` (Codex host behavior, not a universal loader contract).
- Eric Provencher, `Rethinking skills and prompts for GPT-6 Astra`: `https://x.com/pvncher/status/2095991462416490862` (practitioner guidance, not a formal evaluation or security policy).

Apply the writing rules in `SKILL.md`; `references/autonomy-and-completion.md` owns autonomy and approval guidance. Skill structure and routing belong to `ability-creator`.

Adoption boundaries:

- Do not assume description truncation or skill omission from another host's documented budgets. Inspect the actual generator/loader before making a local claim; no universal character or token threshold is adopted here.
- Keep shared contracts model-neutral. Tune a model-specific workflow only when the target model/harness is known and relevant evidence supports the change.
- Treat static conflicts as contract findings, not measured model failure frequencies or proof of improved completion. Separate static, tool integration, and model-behavior evidence.
- Trace claimed historical motivation to actual history when available; otherwise label it as inference. Do not cite practitioner or secondary commentary as formal OpenAI policy.
- Retain source provenance without copying articles, one-time audit logs, local research paths, measured size reductions, or temporary preferences into runtime rules.
- Revalidate external claims when freshness, a changed host/model, or a disputed recommendation matters. Routine prompt edits do not require a new web search; use available source evidence within its stated limits and disclose freshness gaps when material.

## Anti-Defensive Writing Adaptation

The source's direct-expression and claim-first guidance is adapted to executable instructions, not confident tone. [Direct Instruction Writing](../SKILL.md#direct-instruction-writing) owns the operational rules and preservation requirements. External installation files, host assumptions, and essay-specific phrase lists are not imported.

## Maxa Adaptation Decisions

- This Ability is a global shared capability reusable across projects; it excludes local paths, temporary research directories, and machine-specific runtime assumptions.
- `SKILL.md` stays focused on core principles, concise instruction-writing guidance, and scenario routing; detailed workflows live in root-level `references/*.md`.
- No `SYSTEM.md`: prompt engineering is not a mandatory protocol that must apply before Ability loading.
- No scripts: current workflow relies on Agent judgment, document review, and runtime validation. Add scripts later only if stable automatable checks emerge.
