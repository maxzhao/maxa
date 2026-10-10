# Ability Routing And Progressive Disclosure

## Purpose And Inputs

Use when creating or changing descriptions, triggers, resource layout, load dependencies, or oversized Ability entrypoints. This reference owns packaging and loading decisions; load `prompt-engineering` for instruction semantics, autonomy, approvals, and completion rather than duplicating those rules here.

Inputs: supported capabilities, representative requests, mandatory versus optional entry conditions, actual host generator/loader, existing frontmatter, resource tree, and any observed routing failures.

Output: a task-specific Ability entrypoint, reachable scenario resources, preserved runtime boundaries, and evidence appropriate to the change. Do not turn a wording-only edit into a full Ability or repository audit.

## Description And Trigger Decisions

- Description: state the primary capability and applicable situation. Avoid a complete feature catalog, generic claims of usefulness, procedural instructions, or competing broad selection language. Preserve real multi-domain capability when it belongs to one owner.
- Triggers: use intent-bearing phrases. An explicit Ability request is an invocation; an ordinary word that matches an Ability name is not sufficient by itself. Interpret request context or use supported discovery when uncertain, rather than load every possibly relevant Ability.
- Mandatory protocols may favor recall, but their actual entry condition must be stable and explicit before the first governed action. Optional capability triggers should avoid unrelated tasks.
- Check nearby competing Abilities only when the proposed description or trigger creates overlap. Resolve real ambiguity through scope or routing priority, not by shrinking supported capability arbitrarily.
- Inspect the actual host's initial listing, metadata budget, truncation/omission behavior, dependency loading, and selected-body loading when claiming a loading problem. Another host's documented limit is not proof of local truncation.

Line count and byte/token size identify candidates, not defects. Evaluate conditional relevance and selection ambiguity. Do not introduce a universal ideal length, new reduction target, or fixed routing accuracy threshold; existing format/runtime limits still apply.

## MCP-only Discovery

- All sources use the generated Ability table/index; do not maintain a separate Server list in `prompts/system.md`.
- Skill-backed and composite entries keep their effective `SKILL.md` description and `ABILITY.yaml` visibility/triggers; never add another row for the same MCP source.
- MCP-only entries use the effective Server config's optional `description` and `triggers`. Description must be a string; blank means absent. Triggers use the existing ordered unique nonblank English phrase-list contract.
- A nonblank configured description wins over an already-registered static Native description. External cold-start routing requires configured metadata; do not connect or fetch metadata to build the prompt. Missing description falls back to exact-name disclosure.
- MCP-only entries default to full routing rows with descriptions and names only without them. Project `abilities.visibility` may override that default; project-disabled Abilities are omitted and prohibited. Visibility never overrides availability; Server JSON `disabled` is retired.
- Discovery is read-only and exact-workspace scoped. Do not expose raw connection config, invoke description callbacks, create metadata caches or summarize Server instructions into a purpose.
- Pre-load source access rules belong to this Ability's root `SYSTEM.md`; common Runtime and Soul do not duplicate them.

## Resource Placement

| Content | Owner / load point |
| --- | --- |
| Purpose, supported scope, shared boundaries, scenario selection | `SKILL.md` |
| Multi-workflow routing | Short rows: entry condition, target reference, essential prerequisite only |
| Detailed ordered scenario, acceptance gates, examples | A focused `references/<scenario>.md`, loaded for that scenario |
| Operations truly shared across scenarios | One focused operations reference, with relevant sections selected rather than all callers repeating it |
| Deterministic repeated logic and usage | Scripts plus stable help/arguments/output documentation at the required entrypoint |
| Templates and role assets | `assets/`, reached through an explicit scenario route |
| One-time setup or low-frequency internals | Scoped setup/development references, not the ordinary root workflow |
| Rules required before ordinary Ability loading | Minimal `SYSTEM.md`; follow `references/system-prompt-fragments.md` |
| User-facing discovery and examples | Root Chinese `USER_GUIDE.md` |

A useful router does not restate the whole procedure inside a long table cell. Script roots must still expose enough help and common parameters for the Agent to act without reading implementation source.

Do not move a full root handbook into one giant support file and then require all tasks to load it. Split by actual scenario ownership, reuse existing references, and preserve meaningful technical details at their owner. Do not create a document per sentence or duplicate small shared rules merely to reduce root size.

Mandatory `dependencies` load only what every invocation needs. Conditional workflow companions use scenario routing, not unconditional dependencies. Preserve existing public dependency contracts unless the requested change authorizes altering them.

## Migration And Indirect Execution

For each relocated rule or capability, identify:

- source owner and destination;
- scenario trigger and load timing before the first relevant action;
- authority and scope retained, especially security, identity, and ownership boundaries;
- affected templates, examples, role files, fragments, hooks, and script output that can still instruct the Agent;
- validation or evidence demonstrating the migration did not remove the capability.

Update actual execution sources as well as examples. A corrected inline reviewer prompt does not fix a stale role loaded through a `soul` reference. One normative owner must remain; callers route instead of maintaining divergent copies with different “prefer/must” strength.

Keep all supported scenarios reachable, exact tool/schema/command details intact, and user guidance accurate. A reference being listed in a resource inventory is not proof that it will be loaded at the required time.

## Routing And Disclosure Checks

Choose cases implicated by the edit, not a mandatory suite:

| Case | Expected selection |
| --- | --- |
| User explicitly requests this Ability | Load the named Ability through the host's supported entrypoint. |
| Request clearly needs its capability without naming it | Select this Ability; load only the applicable scenario and genuine common prerequisites. |
| Ordinary word matches an Ability name but request is unrelated | Do not invoke it solely from the word match. |
| Request belongs to a neighboring Ability | Select the proper owner, or discover when genuinely uncertain. |
| Simple operation inside a multi-workflow Ability | Avoid unrelated setup, migration, advanced media, or orchestration manuals. |
| A safety/identity constraint must apply before loading | Keep it at the pre-load boundary rather than demote it to an optional handbook. |
| Project override, wrapper, or non-global Ability | Verify the actual host behavior and effective routes; do not assume global defaults. |

Validation layers:

- **Static**: standard `SKILL.md` frontmatter, strict `ABILITY.yaml`, lint, exact paths, resource reachability, generated fragment placement, duplicate normative text, and scoped preservation of constraints.
- **Integration**: affected generator, loader, wrapper, dependency or script/help behavior exercised with the actual entrypoint.
- **Model behavior**: representative selection and completion trials with the target model/harness before claiming measured accuracy or fewer pauses.

Automate stable structural and interface checks where useful; avoid pinning ordinary prose verbatim. Existing lint does not prove intent matching or progressive disclosure. Disclose material untested behavior, and reuse current valid evidence rather than create repeated-check rituals.

## Failure Handling

If host behavior cannot be inspected, distinguish a suspected risk from a demonstrated defect. If a migrated constraint cannot retain authority or load timing, leave that constraint at its original boundary and report the remaining design issue. Do not weaken safety, remove necessary detail, or claim successful migration merely to meet a size check.
