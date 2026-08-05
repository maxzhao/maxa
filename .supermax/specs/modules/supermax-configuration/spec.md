---
title: maxa Runtime Configuration (LazyVim opts) and Project State
created: 2026-08-02
updated: 2026-08-05
doc_role: target-module-spec
authority: draft
status: partial
baseline: ../modules/bootstrap-configuration/spec.md
---

# Configuration authority

maxa configuration follows LazyVim plugin rules (reference: CodeCompanion `setup(opts)` + internal defaults deep-merge, `bootstrap-configuration` spec): ALL runtime configuration defaults live in `lua/maxa/init.lua` `M.defaults` (comments are the config documentation; there is no separate config doc file), and users override them through LazyVim `opts` in their own `lua/plugins/maxa.lua` (or `{ "maxa", opts = {...} }`). `maxa.setup` deep-merges and validates fail-closed through `maxa.runtime.config`. There is NO `.maxa/runtime.yaml` configuration layer.

Project-local *extension content* follows CodeCompanion file conventions and is NOT opts parameters: `.maxa/mcp/servers.yaml` (project MCP declarations) and `.maxa/skills/` (project Skills; see `mcp-skill-runtime`). The only `.maxa/` state file is `.maxa/state.yaml` (runtime status, yaml format; role like SuperMax's `.supermax/_meta.yaml`), read/written via `maxa.runtime.config` `load_state`/`save_state`. `.supermax/` is only the development mother repository's Agent/knowledge/specification environment and MUST NOT be used as the final runtime project's configuration, prompt, Skill, MCP or history root. The runtime MUST distinguish missing, invalid, unsupported and stale project configuration/state.

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

Schema/state validation occurs once per discovered project root before/when the first project Chat is opened; it compares the runtime schema version to the target project's `.maxa/state.yaml:schema_version` and reports `ok`, `project-upgrade-required`, `runtime-upgrade-required`, `project-version-invalid`, or `runtime-version-unavailable`. The target must replace the current acknowledgement popup with a declared Chat/runtime policy, and MUST NOT silently load the development mother repository's `.supermax` or another project's `.maxa` state.

## Target file layout

```text
.maxa/
├── state.yaml                # runtime state file (formal name, yaml; NOT a config layer)
├── system.md                 # optional system-prompt wrapper/override
├── prompts/                  # optional named project prompt fragments
├── skills/                   # project Skills; override same-name global Skills
├── history/                  # runtime-local session history (not source)
└── mcp/
    └── servers.yaml          # optional project external MCP declarations
```

`state.yaml` carries runtime status only (`schema_version`/`project_id`/`created`/`updated`/`status`); missing state is "not initialized", never a configuration error. All other configuration is LazyVim opts (defaults in `lua/maxa/init.lua`, user overrides in their `lua/plugins/maxa.lua`). Absence of optional content paths selects bundled runtime defaults. The target project `.maxa/` is the only project-local runtime state root; the development mother repository's `.supermax/` is never a fallback. Knowledge indexes/rules/specs are loaded only through declared prompt/rule/context routing; directory presence alone does not inject their content.

## LazyVim opts configuration (effective config tree)

Configuration is a Lua opts tree merged over bundled defaults (`lua/maxa/init.lua` `M.defaults`) by `config.configure(defaults, opts)` and validated fail-closed:

- Unknown top-level keys are validation errors, except the declared forward-compatible `extensions` object whose keys are namespaced.
- `provider.definitions` may be empty (built-in `mock`/`echo` mode); `provider.default` must be a built-in provider or exist in `definitions`.
- Literal credentials anywhere in the tree are rejected; `api_key_env`/`proxy_env` must name environment variables.
- Protocol capability matrix: declaring `false` for a protocol-native channel (openai_responses/anthropic/gemini `tools`+`reasoning`, openai_chat `tools`) is a configuration conflict; `vision` is optional everywhere.

Effective config fields (defaults are the source of truth; users override via opts):

```lua
-- lua/maxa/init.lua M.defaults (comments are the documentation)
provider = {
  default = "mock",          -- built-in mock|echo, or a definitions id
  definitions = {            -- real providers (optional)
    ["deepseek-chat"] = {
      protocol = "openai_chat",          -- openai_chat|openai_responses|anthropic_messages|gemini
      base_url = "https://api.deepseek.com",
      api_key_env = "DEEPSEEK_TEST_KEY", -- env-name reference only
      model = "deepseek-v4-flash",
      capabilities = { vision = false, tools = true, reasoning = true },
      request = { timeout_ms = 60000, connect_timeout_ms = 10000, retries = 0 },
      -- context_window = 4096           -- optional positive integer
    },
  },
},
model = "mock-model",        -- initial model label
ui = { show_reasoning = false, layout = "vertical" }, -- host view defaults
history = { enabled = false },
orchestrator = {},           -- un-declared internal defaults live in orchestrator
skills = {}, mcp = {}, status = {},     -- phase-3/5 switches
keymaps = { chat = "<leader>mx" },
extensions = {},             -- open forward-compatible namespace
```

Provider IDs and model names are identifiers, not protocol expansion: a provider named `deepseek`, `open_router`, or a private gateway still MUST resolve to one of the four protocol enum values. `api_key_env` names an environment variable; configuration MUST NOT contain credential values.

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

1. Bundled runtime defaults (`lua/maxa/init.lua` `M.defaults`); LazyVim deep-merges multiple opts.
2. User LazyVim opts (`lua/plugins/maxa.lua` or `{ "maxa", opts = {...} }`); development `.supermax/` is not a configuration source.
3. Explicit session creation overrides for provider/model/UI fields allowed by policy.
4. Runtime state changes such as selected model affect that session only unless explicitly persisted into `.maxa/state.yaml` (state, not configuration).

The merged configuration is validated once by `config.configure` into the effective tree (`config.effective`); provider records are resolved per call via `config.resolve_provider` and never contain credential values. A running request retains the provider record with which it was created. Reload affects future requests/sessions; changed MCP declarations follow the lifecycle diff policy in `mcp-skill-runtime`.

## Failure policy

- Invalid/unsupported project schema blocks project Chat creation and external MCP startup; diagnostics identify file and field path.
- Missing optional configuration uses defaults.
- Missing credential environment values mark only affected providers/servers unavailable unless they are selected as required defaults.
- Prompt composition failure blocks request submission without corrupting session history.
- Configuration dumps redact resolved secret values.
- No acknowledgement popup changes validation truth; upgrades are explicit project governance actions.

Required configuration, prompt and cross-project-isolation fixtures are defined in `../../runtime-fixture-contract.md`.
