---
name: ability-creator
description: "Create, edit, migrate, and audit Ability packages, including standard Agent Skill sources and Maxa runtime extensions."
compatibility: Requires Maxa Ability runtime.
---

# Ability Creator

Purpose: create and maintain the single public Ability package surface while preserving standard Agent Skill source compatibility.

## Ownership

- Global packages: `<maxa-root>/abilities/<ability>/`.
- Project packages: `<project>/.maxa/abilities/<ability>/`.
- `SKILL.md` is the standard Agent Skill instruction source.
- Optional `ABILITY.yaml` owns only Maxa discovery, composition, dependency, file-disclosure, and executor metadata.
- `SYSTEM.md`, `hooks/`, and `USER_GUIDE.md` are Ability extensions.
- `load(target="<ability>")` is the only capability loader. It returns the disclosed script/tool/reference catalog; instructions are injected separately. Read Ability content through `#ability[target]` under the always-on Ability Invocation Protocol. An existing root-confined `#ability[/path]` file resolves independently of loading and disclosure, including control/runtime files and excluded executables; reading does not authorize execution or activate the Ability. Only genuine file absence permits exact authorized resource lookup with the original target.

Before editing instruction text, load `prompt-engineering` and follow its prompt-contract rules.

## Resource Routing

| Need | Read first |
| --- | --- |
| Standard Agent Skill portability | `references/portable-universal-skills.md` |
| Routing, visibility, and disclosure | `references/ability-routing-and-disclosure.md` |
| Root `SYSTEM.md` fragment | `references/system-prompt-fragments.md` |
| AbilityHook file | `references/ability-hooks.md` |
| Import, distillation, or feedback update | `references/user-initiated-ability-workflows.md` |

Load only the relevant reference through its cataloged address, for example `read(path="#ability-creator[/references/ability-routing-and-disclosure.md]")`. Relative Markdown links remain portable source links; Maxa Agents resolve them through the owning Ability catalog.

## Invocation Examples

Agent-facing examples must prefer the Ability Invocation Protocol: use exact `#ability[target]` content addresses with `load`/`read`; load the Ability before cataloged `@ability:...` actions or authorized resource access. Actions use titled `run(scope="tool")`. Script array `args` contains literal CLI arguments; MCP `args` is an encoded JSON object string. Verify file paths against current package ownership and actions/resource identifiers against the committed catalog, replace placeholders with concrete values, and never rely on shell expansion. Resource targets retain their complete listed identifiers; do not invent suffix mapping or an Ability-name URI scheme.

```yaml
- load: {target: "ability-creator"}
- read: {path: "#ability-creator[/references/ability-routing-and-disclosure.md]"}
- run:
    title: "Inspect Ability lint help"
    scope: tool
    command: "@ability-creator:/scripts/lint_skill_descriptions.py"
    args: ["--help"]
```

Keep raw CLI syntax only where it is explicitly a human/manual, maintenance/test or internal executor contract. Current-Neovim scripts use their documented `run(scope="@neovim:lua")` entrypoint after loading `neovim`, not an invented external-process address. External API fields that require physical paths still receive paths resolved from loaded roots.

## LLM-Facing Execution Output

Before designing an Ability script or builtin extension whose result is consumed by the LLM, read `#mcp-creator[/references/llm-facing-tool-contract.md]` for the common consumer-oriented result contract. Keep internal data, model-visible output and UI separate; document the actual result and failure semantics at the scenario entrypoint. Preserve the owning executor's stdout/error/limit behavior and existing machine JSON/outputSchema contracts. This is a conditional reference route, not an unconditional MCP Creator dependency or a second result protocol.

## Package Structure

```text
ability-name/
├── SKILL.md          # required standard Agent Skill source
├── ABILITY.yaml      # optional Maxa metadata
├── USER_GUIDE.md     # required Chinese user scenarios
├── SYSTEM.md         # optional pre-load rules
├── hooks/            # optional AbilityHook definitions
├── scripts/          # external-process entrypoints and support modules
├── references/       # Agent references
└── assets/           # templates/static assets
```

Each Ability is an independent package identified by one package name.

## Standard `SKILL.md`

Required frontmatter:

```yaml
---
name: example
description: Validate project inputs and explain failures.
compatibility: Requires Maxa Ability runtime and uv.
---
```

Allowed fields are `name`, `description`, `license`, `compatibility`, `metadata`, and `allowed-tools`.

Rules:

- Package directory and `SKILL.md.name` match. Ability identifiers are single package names without `/`.
- Names contain lowercase letters, digits, and single hyphens; length is 1–64.
- `description` is nonblank and at most 1024 characters.
- `compatibility`, when present, is 1–500 characters and states real runtime requirements.
- `metadata` is string-to-string only. Do not hide Maxa fields there.
- `allowed-tools` is descriptive metadata; it grants no Chat/MCP authorization.
- Use Skill-root-relative resource paths for standard-client readability.
- Standard format compliance is not proof that another client can execute Maxa builtins, addresses, hooks, or current-Neovim operations.

## `ABILITY.yaml`

Allowed fields only:

```yaml
merge: false
visibility: search
triggers: []
dependencies: []
suite: []
include: []
exclude: []
executors: []
builtin_extensions: []
prompts: false
mcp:
  overrides: mcp/overrides.yaml
```

- `visibility`: `global`, `search`, or `hidden`. If no included Skill layer declares it, default to `global` for a highest-precedence project Skill and `search` for a global Skill. With `merge: true`, the first explicit included-layer value wins before this fallback. Current-project `abilities.visibility` in `.maxa/_meta.yaml` may override the result without editing the package or changing availability. MCP-only defaults remain description-driven.
- `triggers`: ordered unique nonblank English routing phrases.
- `dependencies`: ordered unique Ability identifiers. Same-name Skill/MCP composition is `merge: true`, never a self-dependency.
- `suite`: ordered unique suite identifiers using the Ability-name grammar; one Ability may belong to multiple suites. Use concise domain IDs such as `game-development`; the panel computes `Game Development` by replacing hyphens and capitalizing words, without a display-name map. Membership groups project switches only; it does not load or authorize capabilities. Omitted defaults to `[]`; composition follows the existing first-explicit list rule. MCP-only sources may declare `suite` in their effective Server config; composites use Skill metadata. Project selections belong to root `abilities` in `.maxa/_meta.yaml`, not package-level disable fields.
- `include`: ordered unique package-relative glob patterns that publish files hidden by the default catalog policy. It cannot override runtime hard exclusions or `exclude`, and grants no execution permission.
- `exclude`: ordered unique package-relative glob patterns suppressed from the catalog returned by `load(target="<ability>")`. Exact `#ability[/path]` file lookup is independent of this list; excluded executables remain unavailable through `@ability:/path`.
- `executors`: ordered `{match, command}` entries; first matching rule owns execution.
- `builtin_extensions`: ordered unique canonical builtin names except `multicall`; declares permission for fixed `builtin/<tool>.lua` current-Neovim interceptors. No configurable entrypoint or matcher.
- `prompts`: boolean, default `false`; the first explicit included Skill layer wins. `true` publishes direct Markdown files under `prompts/` to fixed Chat/Actions discovery without Ability loading or activation. Project/global package replacement and `merge: true` file ownership apply; `visibility` does not filter publication. Project-disabled Abilities suppress publication; pure Skills use `prompts: false` to disable prompts only.
- `mcp.overrides`: optional normalized package-relative path to a strict tool/parameter description override file; valid only for an Ability composed with a same-named MCP source.
- Omitted lists inherit from a lower included Skill layer; explicit `[]` clears; a supplied list replaces the lower list completely. The first explicit `mcp` mapping owns the whole mapping and resolves relative to its declaring layer.
- Nulls, duplicate keys, unknown fields, extra documents, anchors, aliases, merge keys, tags, malformed regexes, and unsupported types are invalid.

Example external-process entrypoint:

```yaml
executors:
  - match: '^/scripts/check\.py$'
    command: [uv, run, --project, '{root}', python, '{script}']
```

`command` is literal argv and must include `{script}`. `{root}` and `{script}` use the selected file's canonical owning root. Python always runs through that root's uv project. Keep helpers unmatched or excluded.

An MCP override file contains only changed descriptions; live MCP schemas remain authoritative:

```yaml
tools:
  tool_name:
    description: Concise tool purpose.
    parameters:
      parameter_name:
        description: Concise parameter purpose.
```

Unknown tools/parameters, blank descriptions, schema fields, missing files and root escapes are invalid. The configured file is runtime metadata, omitted from catalogs and unavailable as an action; exact root-confined file reads remain possible.

## Composition And Files

- The highest-precedence Skill candidate alone controls `merge`.
- Without `merge: true`, project replaces global and a same-name Skill/MCP collision fails.
- With merge, roots are project then global; the same-name MCP source follows them.
- One effective `SKILL.md` and root `SYSTEM.md` win by path precedence.
- First existing path owns before type/containment checks. Ordinary upper directories permit nonconflicting lower children; non-directory or symlink ancestors block lower fallback. Exact file lookup ignores disclosure/executor classification, but invalid upper owners never reveal lower files.
- Runtime control, cache, dependency, credential, and ephemeral paths are omitted from disclosure. Ordinary files under `references/`, `assets/`, `templates/`, and `examples/` are public by default; other non-executable files stay undisclosed unless `include` publishes them. Exact root-confined file lookup can address any regular package file, including `SKILL.md`, `ABILITY.yaml`, `SYSTEM.md`, `USER_GUIDE.md`, `hooks/` and `builtin/`; credential-read authorization remains separate.
- Disclosure precedence is runtime hard exclusion, effective `exclude`, effective `include`, then the default policy. It does not restrict exact file addressing.
- The overlay is an address resolver, not a mounted filesystem. Imports, data reads, `pyproject.toml`, and `{root}` remain physical-root-local.

## Entry Classification

- `@ability:/path` launches a cataloged external process with literal argv; `include` never grants execution and `exclude` never creates a hidden executable entrypoint.
- Executable files without an executor run directly. Python files must instead match an owning uv executor.
- Current-Neovim operations such as MCPHub restart scripts are not external entrypoints. Keep them unmatched/non-executable and document explicit `run(scope="@neovim:lua", command='dofile(...)')` use after loading `neovim`.
- `@ability:tool` is a same-name MCP tool; `#ability[target]` is the single Ability content address. A leading `/` tries the root-confined package file first; only genuine absence permits authorized lookup of that exact original resource identifier. Other targets match listed concrete resource identifiers exactly, without a required Ability-name URI scheme.
- No alias, URI map, shell interpolation, script sandbox, or virtual filesystem is implied.

## Builtin Extensions

A successful `load` enables declared interceptors only for the invoking Chat/workspace. Installed code and declarations are read on subsequent calls; edits require no reload, hash approval, or extension revision.

`builtin/<tool>.lua` returns a table with `match(context) -> boolean` and `run(context, response)`. Matching is synchronous and side-effect-free; inspect `context.params` and exact `context.cwd`. Matching rules belong to the script, not metadata. Current-Neovim execution is distinct from external-process scripts and AbilityHook message injection.

`multicall` is a batch execution declaration, cannot be declared in `builtin_extensions`, and always bypasses extension selection; its member builtins remain extensible. Reserved `run(scope="tool")` dispatch and internal Ability-script execution also bypass extension selection. Other calls check extensions in successful load order: `false` proceeds to the next, the first `true` handles the call, and no matches invokes the original builtin. Module/match/run errors fail the call without fallback. An async extension's `run(context, response)` returns nil and completes through `response:text(...):send()` or `response:error(...)`; do not return request IDs/handles. Preserve tool guards, bounded output, single completion, timeout/cancellation, and exact caller identity. Recursive extension re-entry is rejected.

`builtin/` is runtime-only and cannot be published in reference catalogs or as an `@` executable through include/executors. Exact root-confined `#` reads of its source do not activate extensions. Fixed files follow project/global ownership without fallback from an invalid upper owner. Use `SKILL.md` to teach the extension's parameters, result semantics, and limitations; no new builtin schema or extension catalog is needed.

Before installing external extensions, follow the permission review in `references/user-initiated-ability-workflows.md`. In-process Lua is not a sandbox; installed code remains user-owned and freely editable.

## `USER_GUIDE.md`

`USER_GUIDE.md` is required at each Ability root and excluded from ordinary reference catalogs.

- Write Chinese user-facing scenarios and example prompts.
- Cover public workflows without requiring internal path knowledge.
- Do not add README, installation guide, or changelog documents.

## System Fragments And Hooks

- Root `SYSTEM.md` is only for mandatory pre-load behavior. Follow `references/system-prompt-fragments.md`.
- `hooks/<Event>.md|lua` uses AbilityHook. Do not provide both formats for one event.
- On-load hooks are prepared before revision commit, published atomically, then `AbilityLoaded` fires with `ability_name`.
- Scripts forward events through stderr `__FIRE_EVENT__`; they do not gain direct current-Neovim access.

## Python Runtime

Any Ability with Python scripts has a root `pyproject.toml` and preferably `uv.lock`. Agent calls use the cataloged script address. The executor, internal wrapper, or explicitly labeled manual/maintenance command uses:

```bash
uv run --project <ability_root> python <ability_root>/scripts/example.py --help
```

Do not use system Python, direct shebang execution, or implicit PATH Python.

## Validation

1. Validate standard `SKILL.md` fields and strict `ABILITY.yaml` syntax/schema.
2. Resolve effective project/global/MCP composition, dependencies, overlay ownership, exclusions, symlinks, and addresses.
3. Confirm script catalogs expose only intended external entrypoints and preserve owning uv roots.
4. Validate `SYSTEM.md`, AbilityHook files, generated Ability table, and `load(target="<ability>", force_reload=true)` behavior.
5. Validate documented `@` addresses against executable catalogs and exact `#` addresses against effective overlay resolution, run safe script help through titled `run(scope="tool")`, and run focused runtime tests. Do not execute operational commands merely to validate an example.

Description lint (substitute the actual project root):

```yaml
run:
  title: "Lint Ability descriptions"
  scope: tool
  command: "@ability-creator:/scripts/lint_skill_descriptions.py"
  args: ["--project-root", "<PROJECT_ROOT>"]
```

The lint script checks standard Skill descriptions while Ability routing metadata remains in `ABILITY.yaml`.
