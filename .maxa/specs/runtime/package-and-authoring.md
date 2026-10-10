---
title: Ability Package、Discovery、Loading 与 Authoring 规格
created: 2026-06-28
updated: 2026-10-09
type: source
doc_role: spec
authority: accepted
status: active
capability: ability-package-and-authoring
sources:
  - abilities/ability-creator/SKILL.md
  - abilities/ability-creator/ABILITY.yaml
  - abilities/ability-creator/scripts/lint_skill_descriptions.py
  - abilities/prompt-engineering/SKILL.md
  - lua/util/ability_catalog.lua
  - lua/util/ability_management.lua
  - lua/util/maxa_project_settings.lua
  - lua/maxa/interactions/chat/tools/builtin/tools/builtin_load.lua
  - lua/maxa/interactions/chat/tools/builtin/runtime/ability_utils.lua
  - lua/maxa/session/abilities.lua
  - tests/ability_catalog_test.lua
  - tests/builtin_load_ability_test.lua
  - tests/ability_session_catalog_test.lua
  - https://agentskills.io/specification
confidence: high
review:
  human: passed
  evidence: user-declared-change-review-2026-10-07
---

## Purpose And Ownership

This spec owns Ability package format, identity, source composition, dependencies, file/executor catalogs, atomic loading, catalog persistence, address grammar and authoring. Adjacent owners: [Request Routing And Ability Gate](./request-routing-and-skill-gate.md) for request classification/first-tool ordering; [MCPHub Runtime](./mcphub-runtime.md) for MCP transport/policy; [Chat Builtins](./chat-builtins.md) for builtin schemas and extension execution.

## Requirements

### Requirement: Ability is the only public loadable capability

Ability SHALL be the sole LLM-facing discovery, dependency, loading, reference and executable unit, backed by Skill, MCP or an explicit composite. Ability Gate loads the matching generated-table Ability at the start of non-chat work. Agent Skill/MCP are source types, not separate public loaders; this implies no generic plugin framework, script sandbox or compatibility alias.

### Requirement: Ability identity and source discovery are deterministic

Every identifier SHALL be one package name without `/`: 1–64 lowercase ASCII letters, digits or single hyphens, with no leading, trailing or consecutive hyphen. Skill identifiers equal the directory name and `SKILL.md.name`; MCP identifiers additionally start with a lowercase ASCII letter and equal the configured Server name. Resource identifiers are independent of its URI scheme.

Discovery enumerates only immediate Skill package directories under global `abilities/<name>/` and project `<project>/.maxa/abilities/<name>/`; MCP sources come from the exact workspace's effective configured Server catalog, without connection or Chat authorization. Invalid identities (e.g. `invalid_server`, uppercase/slash names, MCP `3d-tools`) fail catalog validation naming the offender; no alias, normalization or invented replacement authorization is allowed.

### Requirement: Standard Skill format and runtime portability are distinct

Every Skill-backed Ability SHALL contain `SKILL.md` conforming to `https://agentskills.io/specification` (reviewed 2026-09-21): required `name` and nonblank `description` (at most 1024 characters); optional `license`, `compatibility` (1–500 characters if supplied), `metadata` (string-to-string map) and `allowed-tools` (string).

Maxa fields SHALL NOT be custom top-level frontmatter or hidden in `metadata`. Maxa-only instructions SHALL declare runtime requirements in `compatibility`; format compliance does not prove cross-client execution. Descriptive `allowed-tools` grants no Chat/MCP authorization.

Packages may contain `scripts/`, `references/`, `assets/` and other resources. Ability extensions `ABILITY.yaml`, `SYSTEM.md`, `USER_GUIDE.md` and `hooks/` are excluded from ordinary reference lists.

### Requirement: `ABILITY.yaml` has one strict Maxa schema

`ABILITY.yaml` is optional. Only the following fields are allowed; defaults apply after composition:

| Field | Contract | Default |
| --- | --- | --- |
| `merge` | boolean composition control for this Skill layer | `false` |
| `visibility` | `global`, `search` or `hidden` | `search` |
| `triggers` | ordered unique nonblank English routing phrases | `[]` |
| `dependencies` | ordered unique valid Ability identifiers | `[]` |
| `suite` | ordered unique valid lowercase Ability-style suite identifiers | `[]` |
| `include` | ordered unique package-relative disclosure globs; no execution grant | `[]` |
| `exclude` | ordered unique package-relative globs | `[]` |
| `executors` | ordered entries with exactly `match` and `command` | `[]` |
| `builtin_extensions` | canonical builtin permissions under the existing extension contract | `[]` |
| `prompts` | boolean publication opt-in under the publication contract | `false` |
| `mcp` | mapping with exactly root-confined `overrides`; same-named Skill/MCP composites only; first explicit mapping wins | absent |

Validation SHALL distinguish absence, explicit `[]` and `null`, and decode quoted escapes before schema/regex checks. Unknown fields, wrong types, duplicate keys/dependencies/suite names, invalid identities/regexes, empty commands, nulls (including `visibility: null` and `dependencies: [null, time]`), anchors, aliases, merge keys, custom tags and extra YAML documents fail before commit with source/reason. No defaulting, entry removal or partial decoding/configuration may conceal failure.

### Requirement: Same-name composition has explicit field and file ownership

The highest-precedence Skill candidate alone controls composition:

| Its `merge` | Result |
| --- | --- |
| not `true` | Project Skill replaces same-named global Skill; same-named Skill/MCP collision fails. |
| `true` | Compose available project Skill, global Skill, then MCP; lower `merge` values cannot enable or veto composition. |

Among included Skill layers, the first explicit `visibility`/`prompts` value and first explicit complete `triggers`/`dependencies`/`suite`/`include`/`exclude`/`executors`/`builtin_extensions` list win: absence inherits, `[]` clears, lists never deep-merge. The highest-precedence `SKILL.md` supplies the sole effective Skill body.

Files overlay by identical Ability-relative path, project before global. First-existing ownership precedes exclusion/type/containment checks; invalid or excluded upper entries never fall back. Globs are case-sensitive forward-slash relative paths: `*`/`?` stay within a segment, `**` crosses segments, trailing `/` selects a subtree, no negation. Existing disclosure precedence remains.

The overlay resolves addresses rather than mounting a filesystem: imports, data, `{root}` and `pyproject.toml` retain each selected file's physical owning root. MCP tools/resources append after Skill catalogs, outside the filesystem overlay.

### Requirement: Package files follow one overridable disclosure policy

Runtime SHALL use one catalog-owned constant policy, highest priority first:

| Priority | Disclosure/execution effect |
| --- | --- |
| Runtime hard exclusion | Ability control paths and runtime-owned cache, dependency, credential and ephemeral paths cannot enter reference or executable catalogs regardless of metadata. |
| Explicit `exclude` | Omit the path, including executor-selected or executable `@` actions. |
| Explicit `include` | Publish a default-hidden regular file as a reference; no execution or containment bypass. |
| Defaults | Publish ordinary non-executable files in `references/`, `assets/`, `templates/`, `examples/`; hide other regular non-executable files from `load` catalogs and completion. |

Load-time publication includes `#` completion: `include: ["data/public-schema.json"]` exposes that regular non-executable file outside default public roots. Without matching include, `pyproject.toml`, `uv.lock`, tests and unmatched helpers remain undisclosed. **Executor rules select external-process entrypoints** owns execution eligibility independently.

Exact `#ability[/path]` file lookup SHALL ignore all disclosure rules (including hard exclusions/include/exclude), executor classification and Chat-loaded state. It reads known paths from current package layers without a committed revision, including control/runtime files and excluded executables. This MAY read files only: it authorizes no execution, sources, resources or secret inspection; credential-read safety still applies. The unified grammar below governs absence-only resource fallback.

### Ability prompt publication

Only effective `prompts: true` SHALL publish direct `prompts/*.md`, using the strict schema/composition, file overlay, physical owning roots and containment/credential exclusions. Invalid upper owners never expose lower files. Publication ignores `visibility` and loaded revisions but omits project-disabled Abilities. Pure Skills MAY use `prompts: false`; there is no package-level Skill `disabled` field. The project-owned availability contract governs project prohibition. Discovery SHALL NOT inject instructions, activate hooks/MCP or authorize a Chat. [Chat commands](./chat-commands.md) owns source priority/collisions.

### Builtin extension package permissions

- **Builtin extension permission list**: `builtin_extensions` MUST be an ordered unique list of canonical builtin names under the schema/composition above. Duplicate/unknown names fail strict validation; entries MUST NOT contain paths or match conditions.
- **Fixed runtime extension files**: Each declared tool MUST resolve only `builtin/<tool>.lua` through current effective Skill layers with root-confined first-existing ownership. Invalid/root-escaping upper owners fail without lower fallback. `builtin/` MUST remain undisclosed and unavailable as an `@` external entrypoint regardless of include/executor settings; exact root-confined `#` reads do not activate extensions.
- **External extension installation review**: Before final installation of an external Ability declaring builtin extensions, the installing Agent MUST inspect the fixed scripts and necessary support code without executing them, explain declared permissions and concrete risks, and obtain explicit user authorization. Refusal or missing approval MUST prevent installation. Review MUST NOT be described as a sandbox or safety guarantee. Installed user edits MUST NOT require a new approval store, hash authorization or renewed approval.

### Requirement: Dependencies target Abilities only

`dependencies` is the sole dependency field. Runtime SHALL validate the effective graph before root side effects, reject missing/self/duplicate/circular edges, load depth-first in declared order and deduplicate successful loads per exact Chat/workspace. Dependencies use the atomic contract below: failure blocks the root but preserves committed dependencies, with partial-success reporting. Same-name `mcp_dependencies` migration SHALL use `merge: true` and remove the self-edge, not create an Ability self-dependency.

### Requirement: Executor rules select external-process entrypoints

Each executor has exactly `match` and nonempty argv `command`. First match wins; substitution uses `{script}` and, when present, `{root}` from the selected file's canonical path/owning root. Optional `call.params.args` appends literal string argv: spaces, `;`, `$()` and quotes remain within their argument element when `call` executes, without shell interpolation.

An unexcluded regular file is executable only by executor match or executable permission: matched files use the executor; unmatched executable files run directly. Disclosure/`include` grants no execution; hidden helpers follow the disclosure policy.

Executors launch external processes, not code in the invoking Neovim; current-Neovim operations remain explicit `lua` calls. Python uses the owning Ability uv project. Execution preserves exact Chat cwd, inherited environment, isolated process groups, 300-second default timeout, bounded output, session-local async/cancellation and script-event forwarding.

### Requirement: Ability file targets are root-confined

Targets begin with `/`, use forward slashes and name a nonempty file path with no empty, `.` or `..` segment; invalid paths SHALL fail before normalization. Runtime SHALL resolve only the requested path from current effective project/global Skill layers without tree enumeration or Ability loading. First-existing ownership precedes type/containment checks.

A higher ordinary directory permits nonconflicting lower children; a higher non-directory or symlink ancestor blocks lower fallback. Safe directory symlinks may be followed only within their owning root. Runtime canonicalizes selected ancestors and the final regular file; missing, inaccessible, non-file or symlink-escaping owners fail without lower fallback.

### Requirement: Ability loading commits one exact-Chat revision atomically

Chat-owned revision state comprises effective roots/metadata, instructions, script/reference/tool/resource catalogs, MCP authorization/guidance, catalog-result association and on-load hooks. MCPHub owns backend connections, administrator policy and process lifecycle separately.

Loading SHALL proceed through these boundaries:

1. Validate sources/graph, load dependencies, prepare sanitized instructions/hooks, explicitly activate the same-named MCP source if present, collect allowed capabilities, enumerate files and prepare one complete catalog/context batch. Invalid package/config/source/file/dependency fails before root commit with owner/reason. Preparation grants no authorization, registers no hook and fires no load event. Partial dependency success/shared MCP connection facts remain preserved and reported, not root success.
2. Commit the complete root revision, protected catalog-bearing result association and hooks at one exact-Chat boundary, preserving assistant/tool-result/context ordering. Dispatch, autosave, recovery and event observers SHALL NOT see a partial revision.
3. Only after commit may `AbilityLoaded` run; post-commit hook errors do not roll back the revision.

### Requirement: Reload, concurrent loads and cancellation preserve committed state

| Condition | Required outcome |
| --- | --- |
| Unchanged ordinary load | May reconnect its MCP source; returns concise ready/unchanged facts. |
| `force_reload=true` | Refresh sources; changed successful refresh commits one complete revision. Failure retains prior revision/catalog/hooks and emits no replacement event. |
| Same-identifier concurrent loads | Serialize per exact Chat/workspace; waiters recheck state and shared dependencies load once without deadlocking acyclic graphs. |
| Different Chats | Independent authorization even with shared transport connections. |
| Cancellation/Chat destruction before commit | Discard prepared root/hooks; committed dependencies and shared transport effects remain reportable. One waiter cannot globally cancel shared activation. |
| Cancellation after publication | Does not undo published revisions. |

### Requirement: Ability load output is compact and directly composable

First/changed successful loads return compact groups `ability`, `roots`, optional `scripts`, `tools{name,description,inputSchema}` and `references`; `roots[0]` is valid for MCP-only Abilities. Tool rows retain complete schema-critical structure and unambiguous escaping. Skill instructions/MCP guidance are injected separately.

The result SHALL be the sole LLM-visible complete catalog rendering. Hidden metadata may retain normalized objects but SHALL NOT inject duplicate catalogs or add redundant target/kind/definition/dependency/URI summaries. Unchanged loads return ready facts only, without replacing the complete result.

### Requirement: The complete catalog result survives session lifecycle operations

Runtime SHALL retain each committed Ability's most recent successful catalog-bearing tool-call/result association—not simply its latest successful `load`—across direct, wrapped, dependency, save/restore, authorized compaction and deduplication paths. Unchanged/failed loads never supersede it.

Complete catalogs SHALL NOT expire by TTL or wrapper truncation; hard transport-limit overflow fails preparation before commit. Restore lacking the protected complete association is not ready even with hidden metadata; explicit fresh `load` must emit a complete catalog.

### Saved Ability identity validation

- **Saved Ability identity validation**: Session catalog/hook restore MUST ignore names failing current package-name grammar. Ignored records MUST NOT become ready, enter completion, install hooks or activate sources; stored messages MUST remain unchanged.

### Requirement: Ability references use one closed mechanical grammar

Actions retain first-colon addressing and their existing execution/exact-Chat authorization requirements: `@<ability>:/<path>` for cataloged external-process scripts, `@<ability>:<name>` for cataloged MCP tools.

All content references SHALL use `#<ability>[<target>]`, with one valid package identifier and a nonblank single-line target enclosed by the opening bracket after the identifier and final closing bracket. Internal brackets/whitespace, URI query/fragment characters, `#` and `@` remain literal target content. No quotes, type markers, alias map, URI rewriting or old colon-form `#` compatibility exists. Catalogs/completion SHALL expose the same complete address without requiring callers to identify the source type.

Resolution SHALL follow this order:

1. Leading `/`: validate the package path and perform current target-only layered lookup under the file-target contract. A valid regular file wins regardless of disclosure/readiness, retaining owning-root confinement and first-existing/symlink/overlay rules.
2. Only genuine package-file absence (including absent package roots) permits resource fallback. Malformed paths, access/I/O errors, non-file owners, containment violations or invalid upper owners fail without fallback; so do a selected file's content-read or consumer-eligibility failures.
3. Non-`/` targets go directly to resources. Match the original target exactly against the invoking Chat/workspace's committed resource identifiers, then dispatch through the owning server; never reconstruct schemes, substitute display names or normalize targets.

Resources require a ready committed Ability, complete catalog result, exact workspace provenance and catalog membership. File absence grants no resource authorization/activation; dispatch never auto-loads/reconnects. Resource templates/MCP prompts remain excluded. A file/resource collision on a leading-`/` target intentionally favors the file; no source-specific bypass exists.

### Requirement: Ability disclosure follows source ownership and metadata availability

Effective disclosure uses project `abilities.visibility` when present, otherwise the Skill/MCP default: `global` emits a full row, `search` the exact name, `hidden` nothing. Skill-backed/composite descriptions and triggers remain Skill-owned; same-named MCP sources add neither duplicate rows nor package overrides.

| MCP-only source default | Disclosure without project visibility override |
| --- | --- |
| Resolved nonblank description | Full name/description/optional-trigger row; valid Ability Gate match. |
| No description | Exact name index only. |

Project-disabled Abilities are omitted regardless of visibility; Server JSON `disabled` is retired. Visibility and permission remain independent, and retained authorization cannot bypass project prohibition.

### Requirement: MCP-only discovery has optional routing metadata

Effective Native/External Server config MAY supply `description` and ordered unique nonblank English `triggers`. A nonblank effective config description wins; otherwise discovery MAY use an already-available static self-description bound to that effective Server/workspace. Absence is valid; triggers alone invent no purpose. Wrong types report Server/field without raw config disclosure.

Server title, initialization instructions and tool schemas SHALL NOT be summarized into routing purpose. Project-over-global whole-Server replacement remains unchanged: no deep config inheritance or new visibility field.

### Requirement: Discovery metadata has no activation or persistence side effects

Generating the catalog/table SHALL NOT start/reconnect Servers/backends, authorize Chats, switch process-global workspace/UI state, write config/cache files, fetch remote metadata, load implementation modules solely for descriptions or evaluate description callbacks. Disclosure exposes safe public routing fields only; commands, args, env, headers, credentials and schemas remain private.

### Requirement: Ability discovery and authoring replace Skill discovery and authoring

`ability-creator` owns standard Skill authoring, `ABILITY.yaml`, hooks, fragments, entrypoint classification, lint and migration; `mcp-creator` owns lower-level MCP implementation. Both distinguish format compliance from runtime compatibility and use unified Ability loading, `@ability:target` actions and `#ability[target]` content, never source-specific public content forms.

- **Ability output-authoring route**: Before designing LLM-consumed output of an Ability script or builtin extension, ability-creator MUST route authors to `#mcp-creator[/references/llm-facing-tool-contract.md]`, preserving the executor's actual output/error/limit rules and required machine JSON/outputSchema contracts. Do not duplicate that full contract or add an unconditional Ability dependency.

Load `prompt-engineering` before editing prompt-like Ability artifacts. Agent-facing package artifacts are English unless a higher-priority rule overrides; `USER_GUIDE.md`, when present, remains user-facing Chinese guidance. Ability Python packages include `pyproject.toml` and invoke entrypoints through:

```bash
uv run --project <ability_root> python <ability_root>/scripts/<script>.py ...
```

System Python, direct shebang execution and implicit PATH Python are prohibited for Ability Python entrypoints.

### Requirement: Ability suites use package-owned metadata

An Ability MAY belong to multiple suites through the `suite` schema/composition below. A suite is a grouping, not an Ability dependency, load unit or authorization grant.

Discover suite names/members without activating capabilities. Skill-backed/composite membership belongs to effective `ABILITY.yaml`; MCP-only membership MAY use the effective Server config's `suite` list under the same identifier/list validation. Skill metadata wins for composites; no second membership map or wrapper package is required. Missing membership defaults to `[]`; unassigned Abilities remain individually configurable.

Store only the canonical lowercase hyphenated identifier, for example `game-development`. Display labels replace hyphens with spaces and capitalize word initials (`Game Development`), without a registry, translation map or `display_name`. User-approved package/Server classification is included; this adds no interactive membership editor.

### Requirement: Ability availability is project-owned and live

Use the exact normalized project root and runtime metadata shape owned by the [Runtime defaults delta](./plugin-entrypoints.md). Omitted Ability state permits use; project `abilities.states` is the sole Server/Ability availability policy, and Server JSON `disabled` is retired. Disabled Abilities SHALL be omitted from Agent discovery, completion, prompt publication and newly composed SYSTEM fragments, and rejected for normal/dependency loading and subsequent scripts/tools/resources/builtin interceptors. Disabled dependencies SHALL fail the root before root side effects, not be automatically enabled.

Apply policy to already committed/restored authorization and pre-commit/pre-dispatch rechecks, and suppress Ability Hook registration/restoration/delivery for that target project. Do not delete historical messages, pretend to retract injected instructions, revoke another project's state or stop shared MCP sources solely because this project disabled an Ability. Exact root-confined package-file inspection retains its read-only contract and grants no execution/readiness. Enabling restores availability only: ordinary Ability loading and exact-Chat authorization are still required. Current prompt caches must invalidate on project changes; existing Chat prompt/history contents remain intact.

### Requirement: Suite actions preserve overlap and manual choices

`enabled_suites` records explicit suite selections; `states` records actual per-Ability selection, with omitted entries available. An unselected suite whose members happen to be available is not thereby an explicitly selected protection source.

| Action | Required atomic project state transition |
| --- | --- |
| Enable suite S | Select S and set every current member's state to `true`, including previously manually-off members. |
| Disable suite S | Unselect S. Set a current member to `false` only when it is not a member of another explicitly selected suite. Leave protected members' current states unchanged, including manually-off states. |
| Enable/disable one Ability | Set only that Ability's state, even if an explicitly selected suite contains it. Do not change suite selections or establish a permanent override against later suite actions. |

Suite actions change project availability only, never MCP definitions or global package declarations, and do not load/authorize/connect capabilities.

### Requirement: Suite display reflects actual member availability

Project panel SHALL show suites and individual Abilities with direct toggle operations. For each suite, display available/current-member count: zero available = off, all available = on, intermediate = partial. Compute against actual project availability; do not persist this projection. Separately identify explicit suite selection used for overlap protection. All selected suites affected by manual member changes SHALL update their counts/state.

A partial/off suite can be enabled explicitly to turn on all selectable members; a suite can be disabled explicitly even while partial. Empty suites are not invented. Unassigned Abilities remain directly reachable.

### Requirement: Project visibility override

Effective `abilities.visibility.<name>` overrides the package/MCP default with `global|search|hidden`; absence inherits. Visibility never enables, loads or authorizes. Reset clears the selected project's availability/visibility override without changing global package metadata or suite selections.

### Requirement: Ability management separates dimensions

P displays project availability with inherited/explicit origin, visibility, source type/ownership and suites; text/suite filters retain access to unassigned/hidden/disabled entries. Details expose description, physical owners, dependencies/dependents and only the captured invoking Chat's load status when present. Listing/details do not start connections. Keep direct availability actions, project visibility selection, reset and guarded deletion in the existing view system.

### Requirement: Guarded physical deletion

P and MCP definition deletion share checks. A depends on B means B cannot be deleted while A remains installed, even disabled. Check known global/current-project layers, ownership and lower-source fallback; registered Native abilities cannot be deleted. Preview exact selected package/config owners, fallback and global/downstream impact without credentials. Confirmation defaults to Cancel; explicit confirmation then fresh dependency/ownership checks precede effects. Cancel or failed checks leave sources untouched; report operational deletion failures without claiming success. No force/cascade, escaping-package symlink traversal or unrelated runtime code/data deletion. Global deletion cannot enumerate private dependencies in unknown downstream projects, and its confirmation must disclose that limit.

## Validation And Review State

- 2026-10-08: unified management passed focused contract checks and actual fresh-Neovim management interaction. Human post-implementation review is not-run; confirmation/dependency behavior was observed without physically deleting maintained packages.

Earlier evidence retains its original scope:

- Accepted hard cut: `tests/ability_catalog_test.lua`, `tests/builtin_load_ability_test.lua`, `tests/ability_session_catalog_test.lua`, completion/system-prompt tests, literal-argv supervisor checks, hook tests and fresh-Neovim live Ability loads passed.
- Ability description lint passed with zero errors; broad/shared-trigger warnings remain nonfatal and separately owned.
- MCP-only described/name-only/disabled disclosure, config-over-static precedence, no-activation generation and default/custom-Soul prompts passed focused automation and fresh-Neovim validation.
- Human review passed by explicit user declaration on 2026-09-22; the later batch declaration is recorded above. Per-change historical limits remain below.

## Source Trace

| Owner | Source |
| --- | --- |
| Catalog/composition | `lua/util/ability_catalog.lua` |
| Loading/dispatch | `lua/maxa/interactions/chat/tools/builtin/` |
| Session revision/catalog state | `lua/maxa/session/abilities.lua`, `compaction_messages.lua`, `loaded_items.lua` |
| Authoring/lint | `abilities/ability-creator/` |

Dated checks below retain their actual scope and historical human-review limits.

| Rule group | Historical validation and limits |
| --- | --- |
| Builtin extensions | focused catalog/load checks passed, installation instructions checked statically. No third-party installation or human implementation review was performed; existing `review` metadata retains its historical baseline meaning. |
| Independent file references | Target-only lookup, current layered ownership, disclosure independence and root confinement passed focused checks. Fresh-Neovim read/load of an unloaded control file succeeded without ready state; actions/resources retain authorization. Human implementation review not-run. |
| Unified content | Focused file/absence/permission/identifier/ownership/history checks and fresh-runtime actual content reads passed. Actual Chat completion and Storybook resource access passed; human implementation review not-run. |
| Flat identities / saved restore | Focused catalog/load/session/hooks checks, generated prompt and fresh-runtime literal Chat completion passed. Human implementation review not-run. |
| Output-authoring route | Actual revised Ability load/reference reachability and scoped guideline checks passed; human review not-run. |
