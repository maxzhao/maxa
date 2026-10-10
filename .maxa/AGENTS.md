# Maxa Monorepo Rules

> Maxa project-level L0 supplemental rules. Priority is lower than the main system prompt, Ability Gate, tool-safety rules, and loaded Ability instructions.

This repository is the **single authoritative Maxa monorepo / reference implementation**. It is not an ordinary personal configuration. It provides runtime support, shared capabilities, and governance constraints for Agents running in other projects.

### 1. Project Scope

- Resolve the current project root from the invoking Chat's runtime context. Resolve repository-relative paths against that root; do not hardcode a machine-specific path.
- This repository provides the **Maxa runtime foundation**. It is not a normal LazyVim personal configuration and not a single business feature.
- Agents in other projects reuse this repository's Abilities, Native MCP servers, hooks, prompts, workflows, knowledge governance, SubAgent orchestration, Artifact protocol, image tools, session history, and validation methods.
- Default prompts, Ability instructions, MCP tool schemas, hook behavior, command entrypoints, and `.maxa/` governance constraints in this repository may become downstream public behavior.
- Therefore, every analysis and change must consider **cross-project reuse**, **backward compatibility**, and **downstream impact** by default.

### 2. Higher-Priority Constraints

- Safety > correctness > completeness > simplicity.
- This file is lower priority than the main system prompt, Ability Gate, tool-safety rules, and loaded Ability instructions.
- If this file conflicts with higher-priority rules, follow the higher-priority rules.
- Do not turn local temporary preferences into shared runtime contracts.
- Do not sacrifice reuse or stability in other projects for convenience in the current directory.

### 3. Monorepo Design Principles

- Prefer abstracting new capabilities as **reusable primitives** instead of satisfying only the current machine or current project.
- Any behavior inherited by downstream Agents must be treated as a public API.
- Prefer **incremental compatibility** and avoid breaking changes.
- Keep adapter, tool, skill, prompt names, inputs, outputs, and default behavior stable.
- Explicitly isolate local-only logic so it does not pollute the shared layer.
- During design, ask: **"Can an Agent in another project read this rule and use it correctly?"**

### 4. Runtime Components

The full development checkout and filtered public snapshots have different file sets. Check the current checkout before using a component. In the development checkout, `release/.release.gitignore` owns additional publication exclusions. Do not recreate excluded or optional components merely because this file mentions them.

- `lua/maxa/init.lua`: shared runtime entrypoint; `maxa.setup(opts)` initializes Maxa AI and MCPHub.
- `lua/plugins/ai.example`: published startup configuration example. The development checkout's `lua/plugins/ai.lua` is a private startup configuration, not a downstream dependency.
- `lua/maxa/interactions/*` and `lua/maxa/lifecycle/*`: Chat/background execution, tools, UI, request lifecycle, and events. Changes directly affect Agent behavior.
- `lua/maxa/mcphub/*`: MCPHub core and framework; `lua/maxa/mcphub/native_servers/*` owns Native MCP Server implementations and their public capability surface.
- `lua/maxa/session/*`: session state, notifications, history, trace, and recovery; `lua/maxa/_extensions/*` owns the Maxa AI extension registry.
- `lua/maxa/abilities/*`, `lua/maxa/project/*`, `lua/maxa/task_browser/*`, `lua/maxa/prompts/*`, `lua/maxa/providers/*`, and `lua/maxa/adapters/*`: discovery, Ability hooks, project workflows, prompts, providers, adapters, and quota implementations.
- `abilities/*`: loadable global Abilities backed by standard Agent Skill packages and/or MCP sources. Ability Python entrypoints use their owning root's `pyproject.toml` with `uv run --project <ability_root>`. Public snapshots contain the selected packages, not every development Ability.
- `prompts/*`: system prompts, command prompts, MCP documentation, and workflow prompts. These are part of the shared behavior contract.
- `mcp-servers/*`: external MCP server implementations and integration environments, including Browser MCP and its Tauri/CDP integration.
- `tools/*`: standalone helper services and tools. Public snapshots contain only the selected services.
- `obsidian-plugins/*` and `web/*`: knowledge governance, UI, and plugin subprojects. Validate changes through the affected package's existing entrypoint.
- Development-only editor components are listed in §8; they are not required by the published Maxa runtime.
- `.maxa/*`: project knowledge growth layer, not runtime source code.

### 5. Default Judgment Before Analysis Or Modification

- First decide whether a change is **local-only** or part of the **shared runtime**.
- If it affects the shared runtime, prioritize downstream compatibility.
- If it changes Agent behavior, tool interfaces, prompt semantics, session recovery, or MCP interaction, treat it as a public behavior change.
- For public behavior changes, prefer:
  - unchanged defaults;
  - continued support for old interfaces;
  - optional opt-in for new capabilities;
  - graceful degradation on failure.
- If a change is meaningful only for the current environment, mark it clearly as local-only to avoid misleading downstream projects.
- Do not treat "it works for me now" as proof that it is safe for other projects.

### 6. Project Knowledge Vault Rules

- The project knowledge Vault is located at `.maxa/`. It contains knowledge zones plus Vault-visible workspace zones; runtime source code is outside the Vault, and TaskAdmin storage remains TaskAdmin-owned even though it is Vault-visible.
- Vault identity is project-local instance data. Resolve it through `project-admin` for the selected project root; never assume a fixed Vault name.
- `AGENTS.md` provides only the L0 entrypoint and stable constraints. It must not contain long-form body text, task progress, note catalogs, drafts, or one-off logs.
- Agent entry: `.maxa/AGENTS.md` -> `.maxa/index.md` -> selected `weave/index.md` or content indexes; capture/feedback/pending knowledge enters through `inbox/index.md`. Read only relevant nodes/sources, not the whole Vault.
- Content belongs to semantic categories. `weave/` holds compact LLM-maintained topic/concept navigation; load `project-admin` for requested weaving, budgets, guarded Obsidian retrieval and checks. Intake/query/check does not implicitly weave; generated views do not replace source authority.
- For external graph operations, load `project-admin` and use its guarded `project_knowledge_vault.py exec` with an explicit `--project-root`. It supplies the verified Vault selector; do not use the default active Vault or bypass checkout-ownership and registration checks.
- `.maxa/{ideas,research,rules,specs,reports}/` are semantic content owners, created only when applicable; retired nested `.maxa/knowledge/` is not an init/sync output or fallback.
- `.maxa/tasks/`, `.maxa/drafts/` and `.maxa/translate-cache/` are Vault-visible workspace zones with separate ownership; task/transient/runtime data do not become content or weave sources automatically.
- Every maintained knowledge directory under `.maxa/` should provide its own `index.md`; maintained top-level knowledge directories must also provide `log.md`. Parent indexes are routing indexes: they must point to direct child indexes or directly owned files, not duplicate deep child index content.
- Root `raw/` is retired. Route raw/evidence material to a semantically owned top-level directory such as `research/`, `reports/`, `attachments/`, or `canvases/`, or define a new top-level directory with its own `index.md` and `log.md`.

### 7. Environment, Commands, And Validation Rules

- The main runtime environment is Neovim + Lua + Maxa AI + MCPHub. Supporting stacks include Python/uv, Node/TypeScript, Elm, Vitest/Playwright, Obsidian plugins, and WSL/Windows bridging.
- Before running commands, check `justfile.md` when present and prefer matching `just` recipes. Otherwise use the applicable runtime Justfile discovery protocol. Public snapshots may omit the development root recipes. If `justfile` changes, update `justfile.md` as well.
- When present, `justfile.md` should stay aligned with recipes exposed by `just --summary`; do not expand the full recipe list in `AGENTS.md`.
- After modifying code, configuration, runtime prompts, Abilities, hooks, MCP servers, or other behavior-affecting artifacts, run the relevant existing validation. Do not skip validation because the change is small.
- Lua / Neovim runtime changes: prefer the closest relevant `nvim --headless` test file; many test files document their run command in the file header.
- Python Ability or tool changes: use the corresponding uv project, for example `uv run --project <ability_root> ...` or `uv run --project <tool_root> ...`; do not fall back to system Python.
- Telegram Bridge changes: prefer `just telegram-bridge-test`.
- Node/TypeScript/Elm subproject changes: enter the relevant subproject and prefer its `Justfile`, `package.json` scripts, or existing test entrypoints, such as `npm run build`, `npm test`, `npm run test:e2e`, or `elm-test tests`.
- For MCP Server reloads, load `mcp-creator` and follow its reload matrix: MCPHub core/framework and Native Server changes under `lua/maxa/mcphub/**` require a full Neovim restart; external Server code/config changes use the MCPHub restart path. Validate after reload.
- When Lua changes require a fresh Neovim process (including runtime/plugin patches), first validate locally, then load `mcp-creator` and run its `scripts/restart_nvim_resume.lua` inside the current Neovim with `lua`/`dofile` and the loaded Ability root. It requires tmux and a history-backed caller Chat; on `ERROR:` resolve the blocker without exiting, and on `OK:` end the turn so the restored Chat can resume testing.
- For debugging, inspect Snacks notifier history before deciding to add logs.
- When chat or session state must be inspected, use the existing project toolchain first instead of guessing internal state manually.

### 8. Main Directory Responsibilities

- `lua/maxa/`: shared Maxa runtime and project-workflow implementations; canonical callers use `maxa.*` modules. Use the component owners in §4, not legacy `util.*` or `codecompanion.*` paths.
- `lua/config/` and `lua/plugins/`: development editor configuration and plugin integrations. Public snapshots omit the private configuration and retain `lua/plugins/ai.example`; downstream startup configuration is user-owned.
- `lua/godot/` and `lua/plugins/godot.lua`: development-only Godot editor support, independent of the published Maxa runtime; callers use `godot.*` modules.
- `lua/util/`: development-only editor helpers, not the shared Agent runtime. Do not restore legacy forwarding modules.
- Copilot Proxy, Agent Loop, `pause_loop`, `localllm`, and LiteLLM runtime behavior are retired; do not restore them. Active provider/quota code belongs to `lua/maxa/providers/` and `lua/maxa/adapters/quota/`, configured by the selected Maxa startup entrypoint.
- `abilities/`: global Ability packages. Standard `SKILL.md`, optional `ABILITY.yaml`, resource routing, script invocation, hooks, and fragments are inherited by downstream Agents.
- `prompts/`: system prompts, command prompts, MCP documentation, and workflow prompts. These are shared behavior contracts.
- `mcp-servers/`: external MCP server workspaces, including Browser MCP with browser and Tauri/CDP automation.
- `tools/`: standalone helper services, including Telegram Bridge.
- `obsidian-plugins/`: maintained Obsidian plugins and reference plugins for project knowledge governance and dogfood.
- `web/`: frontend / UI subproject, not the core Maxa Lua runtime. Use its existing validation entrypoints.
- `dotfiles/`: development-only machine configuration, excluded from public snapshots. Do not promote its local preferences into shared Maxa rules unless explicitly requested.
- `.maxa/tasks/`: TaskAdmin internal storage. Any task creation, reading, updating, execution, or completion operation must load `task-admin` first. Do not guess task paths manually.
- `.maxa/drafts/`: Agent temporary draft directory. It only stores uncommitted temporary drafts and is not a substitute for knowledge, task, handoff, or runtime source storage.
- `.maxa/`: project knowledge Vault. Enter through `index.md`; do not expand all notes into `AGENTS.md`.
- `.maxa/tmp/`, `.maxa/artifacts/`, `.maxa/history/`, `.maxa/reports/`, `.maxa/handoff/`, and `.maxa/e2e/`: project governance and runtime support data. Use them according to their own tool/process constraints; do not promote one-off run output into rules.
- `tests/` and module-local test files: existing validation entrypoints. Prefer the closest existing check. Public snapshots may omit development tests; report unavailable checks rather than treating missing test directories as an installation defect.

### 9. One Sentence For Future Agents

Treat this repository as the **Maxa runtime foundation**, not a personal preference configuration. Every change should prioritize sharing, stability, reuse, and portability.

### 10. Additional Reminders

- Do not add plaintext secrets or credentials to source code. Do not read `.env` / `.env.*` or suspected credential files unless the user explicitly asks and only the necessary fields are read.
- If a shared interface is touched, also consider documentation, skill instructions, tests, and downstream adaptation.
- If rules and implementation diverge, prefer fixing either the rules or the implementation so the contract remains clear.
- When updating this file, keep only stable, common, low-context project-level rules. Long-form research, design details, temporary state, and complete note lists should go to `.maxa/`, the owning TaskAdmin plan/TODO or linked task document, or `.maxa/drafts/`.
- This project has been active for a long time. Before syncing `AGENTS.md`, first audit project structure, `.maxa/` governance files, the knowledge entry chain, `justfile.md`, and the most relevant recent implementation. Do not mechanically rewrite from old rule text only.
- `.maxa/AGENTS.md` must be written in English. Keep downstream project `AGENTS.md` files English as well unless a higher-priority project rule explicitly requires another language.
