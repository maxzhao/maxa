---
title: SuperMax Project Configuration and Prompt Composition
created: 2026-08-02
updated: 2026-08-02
doc_role: target-module-spec
authority: draft
status: partial
baseline: ../modules/bootstrap-configuration/spec.md
---

# Configuration authority

The runtime MUST discover configuration from the current target project's `.maxa/` entry chain. `.supermax/` is only the development mother repository's Agent/knowledge/specification environment and MUST NOT be used as the final runtime project's configuration, prompt, Skill, MCP or history root. The runtime MUST distinguish missing, invalid, unsupported and stale project configuration.

The development mother repository source has no `.maxa/system.md` or `.maxa/prompts/` files in this repository snapshot; `GenerateSystemPrompt` therefore falls back to runtime `prompts/system.md`. The target must preserve this fallback while defining the project override layout for downstream projects. The mother repository's `.supermax/` rules/specs are Agent development evidence only, not an automatic substitute for `.maxa/system.md`.

## Prompt composition

The generated system prompt MUST include the stable runtime contract plus the applicable target-project rules/context selected through `.maxa`; the development mother repository's `.supermax` content is not implicitly included. Project prompts and runtime additions have explicit precedence and source trace. Prompt dumps are reproducible for the same project/session/configuration snapshot.

Current source evidence reads `<project-root>/.supermax/system.md`; the target changes that runtime path to `<project-root>/.maxa/system.md`. When it contains `<system_prompt>`, the composer expands that placeholder from the bundled runtime `prompts/system.md`; otherwise it falls back to bundled runtime `prompts/system.md` (`lua/util/init.lua:995-1013`). It replaces `<plugin_rules_root>`, `<date>`, `<vim_ver>`, `<machine>`, `<root_dir>`, `<skills_table>`, and declared Skill `SYSTEM.md` fragment slots (`lua/util/init.lua:1015-1125`). Unknown declared slots are a composition error, not silently ignored. `DumpSystemPrompt` uses the same builder.

## Target prompt template contract

The bundled runtime `prompts/system.md` contains the stable high-authority runtime contract. A target project `.maxa/system.md` is a wrapper and MUST contain exactly one `<system_prompt>` placeholder. The development mother repository's `.supermax/` is never this target project state. The current behavior that allows a project file without the placeholder to replace the complete runtime prompt is corrected: target validation reports `missing-system-prompt-placeholder` and blocks request composition.

Built-in placeholders:

| Placeholder | Value / failure behavior |
| --- | --- |
| `<system_prompt>` | complete mother-repository stable prompt; exactly once in project wrapper |
| `<plugin_rules_root>` | absolute mother-repository prompt resource root; missing root is composition failure |
| `<date>` | composition snapshot date, fixed for one prompt build |
| `<vim_ver>` | normalized Neovim semantic version |
| `<machine>` | normalized host class (`Linux`, `Windows`, `Mac`, or declared raw fallback) |
| `<root_dir>` | resolved project root, never an unrelated current working directory after project binding |
| `<skills_table>` | deterministic discoverable Skill table |
| `<skill_system_prompt_fragments>` | default Skill SYSTEM slot |
| `<skill_system_prompt_fragments:slot>` | named Skill SYSTEM slot matching `[A-Za-z0-9_-]+` |

Composition rules:

1. Resolve and bind project root once; all project paths use that snapshot.
2. Read/validate runtime prompt and optional project wrapper.
3. Expand `<system_prompt>` before lower-authority dynamic fragments.
4. Expand scalar placeholders from one immutable composition context.
5. Discover Skills with project-over-global same-name precedence; render the Skill table deterministically.
6. Collect eligible `SYSTEM.md` fragments by slot, order by numeric `priority` ascending then stable Skill ID ascending, and concatenate with two newlines.
7. Each Skill slot placeholder may appear at most once. Duplicate placeholders are `duplicate-skill-slot-placeholder` errors rather than repeated high-authority injection.
8. A placeholder with no fragments renders empty. A nonempty declared fragment slot without a matching placeholder is `unbound-skill-system-slot` and blocks composition.
9. A leftover recognized placeholder or malformed named slot is a typed composition error. Literal angle-bracket text outside the declared placeholder grammar is preserved.
10. Normalize line endings to LF and prompt block boundaries deterministically; do not trim meaningful code/content interiors.

Skill `SYSTEM.md` eligibility follows current evidence with a stricter deterministic contract:

- Global Skill fragments are eligible.
- Project/non-global Skill fragments require explicit `allow_non_global: true`; otherwise they remain ordinary loaded Skill context and cannot elevate into the stable system layer.
- Empty `slot` normalizes to `default`; invalid slot characters fail validation.
- Missing/invalid `priority` defaults to `100`; equal priority is resolved by stable Skill ID, not filesystem scan order.
- A malformed frontmatter delimiter fails that fragment; it is not interpreted as body-only system content.
- Fragment source path, Skill ID, slot and content hash are recorded in the prompt composition trace.

`DumpSystemPrompt` and production request composition MUST call the same pure composer with the same input snapshot. The dump redacts secrets and includes a separate source manifest; it never changes composition output.

The current `ai.lua` logic around `make_supermax_config`, `system_prompt`, project prompt directory resolution, history configuration and MCP native-server injection is evidence for the target contract. Hard-coded CodeCompanion config keys are not target API requirements.

## Runtime defaults

Default provider/model, gateway proxy, model capabilities, retry/raw curl policy, history/title provider, MCP timeout, automatic tool execution, SkillHook registration and status integration are configured in the mother repository and may be overridden only through declared project configuration fields.

Schema validation occurs once per discovered project root before/when the first project Chat is opened; it compares the runtime schema version to the target project's `.maxa/_meta.yaml:supermax_schema_version` and reports `ok`, `project-upgrade-required`, `runtime-upgrade-required`, `project-version-invalid`, or `runtime-version-unavailable` (`lua/util/supermax_schema_check.lua:25-110,216-244`). The target must replace the current acknowledgement popup with a declared Chat/runtime policy, and MUST NOT silently load the development mother repository's `.supermax` or another project's `.maxa` state.

## Target file layout

```text
.maxa/
├── _meta.yaml
├── runtime.yaml              # optional project runtime overrides
├── system.md                 # optional system-prompt wrapper/override
├── prompts/                  # optional named project prompt fragments
├── skills/                   # project Skills; override same-name global Skills
└── mcp/
    └── servers.yaml          # optional project external MCP declarations
```

Absence of optional paths selects bundled runtime defaults. The target project `.maxa/` is the only project-local runtime state root; the development mother repository's `.supermax/` is never a fallback. Knowledge indexes/rules/specs are loaded only through declared prompt/rule/context routing; directory presence alone does not inject their content.

## `runtime.yaml` schema

Unknown fields are validation errors by default. The runtime MAY support a declared forward-compatible `extensions` object whose keys are namespaced; it MUST NOT silently accept unknown core fields.

```yaml
schema_version: 1
provider:
  default: provider-id
  definitions:
    provider-id:
      protocol: openai_chat|openai_responses|anthropic_messages|gemini
      base_url: https://example.invalid/v1
      api_key_env: ENV_VARIABLE_NAME
      model: model-id
      capabilities:
        vision: true|false
        tools: true|false
        reasoning: true|false
      request:
        timeout_ms: integer
        connect_timeout_ms: integer
        retries: integer
        proxy_env: ENV_VARIABLE_NAME|null
history:
  enabled: true|false
  auto_save: true|false
  continue_last_session: true|false
  title_provider: provider-id|null
  expiration_days: integer
orchestrator:
  tool_concurrency: integer
  watchdog:
    enabled: true|false
    timeout_ms: integer
    max_retries: integer
  context_stop:
    enabled: true|false
    target: string|number|null
ui:
  layout: vertical|horizontal|float|buffer
  start_in_insert_mode: true|false
  spinner_delay_ms: integer
  show_reasoning: true|false
  fold_reasoning: true|false
skills:
  global_enabled: true|false
  project_enabled: true|false
mcp:
  project_servers: true|false
  request_timeout_ms: integer
  auto_start: true|false
status:
  lualine: true|false
  billing: true|false
extensions: {}
```

Provider IDs and model names are identifiers, not protocol expansion: a provider named `deepseek`, `open_router`, or a private gateway still MUST resolve to one of the four protocol enum values. `api_key_env` names an environment variable; configuration files MUST NOT contain credential values.

## MCP server schema

`.maxa/mcp/servers.yaml` is target-project-local and has no cross-project or development `.supermax` fallback:

```yaml
schema_version: 1
servers:
  server-id:
    enabled: true
    transport: stdio
    command: executable
    args: []
    env:
      KEY: literal-or-${PROJECT_ROOT}
    cwd: ${PROJECT_ROOT}
    request_timeout_ms: integer|null
    startup_timeout_ms: integer|null
```

Only declared substitutions such as `${PROJECT_ROOT}` and environment references are expanded. Missing environment references remain validation errors or explicit unavailable-server state; secrets are never persisted into resolved config dumps.

## Precedence and snapshot

1. Bundled runtime defaults.
2. Target project `.maxa/runtime.yaml` overrides at declared fields; development `.supermax/` is not a configuration source.
3. Explicit session creation overrides for provider/model/UI fields allowed by policy.
4. Runtime state changes such as selected model affect that session only unless explicitly persisted as project configuration.

Configuration is normalized into an immutable project snapshot with source paths and hashes. A running request retains the snapshot with which it was created. Reload affects future requests/sessions; changed MCP declarations follow the lifecycle diff policy in `mcp-skill-runtime`.

## Failure policy

- Invalid/unsupported project schema blocks project Chat creation and external MCP startup; diagnostics identify file and field path.
- Missing optional configuration uses defaults.
- Missing credential environment values mark only affected providers/servers unavailable unless they are selected as required defaults.
- Prompt composition failure blocks request submission without corrupting session history.
- Configuration dumps redact resolved secret values.
- No acknowledgement popup changes validation truth; upgrades are explicit project governance actions.

Required configuration, prompt and cross-project-isolation fixtures are defined in `../../runtime-fixture-contract.md`.
