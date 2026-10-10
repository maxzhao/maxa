---
title: MCPHub 内建运行时稳定规格
created: 2026-09-13
updated: 2026-10-09
type: source
doc_role: spec
authority: stable
status: stable
capability: mcphub-runtime
validation:
  specification: passed
  automated: passed
  live: passed
  human: passed
sources:
  - lua/maxa/mcphub/
  - lua/plugins/ai.lua
  - lua/maxa/mcphub/project_transport.lua
  - lua/maxa/session/abilities.lua
  - lua/util/ability_catalog.lua
  - lua/maxa/mcphub/native_servers/init.lua
  - bundled/mcp-hub/package.json
  - bundled/mcp-hub/package-lock.json
  - bundled/mcp-hub/disable-marketplace.cjs
  - LICENSES/mcphub.nvim-MIT.txt
confidence: high
---

> **TLDR**: Repository-owned MCPHub supplies the UI/control plane and exact-workspace transport; Ability owns Chat authorization. Capability connection never grants authorization.

## Purpose

Specify MCPHub setup, state, UI, workspace, Native framework, retained extensions, backend, recovery and reload, including its Maxa Chat/Native ownership boundaries.

## Scope

### Out Of Scope

- `maxa.mcphub.extensions.codecompanion` and dynamic Maxa MCP registration bridges. Chat integration is limited to side-effect-free effective catalog discovery, Ability activation/authorization and authorized `@`/`#` dispatch.
- Full npm `mcp-hub` source ownership/fork/upstream synchronization, protocol/backend redesign, compatibility layers and transition loaders; only the deterministic Marketplace-disable backend patch is owned here.
- Concrete Maxa Native tools under `lua/maxa/mcphub/native_servers/**`: see [MCP stable specifications](./index.md).
- First-party tools: see [Chat Builtins](./chat-builtins.md).

## Requirements

### Requirement: Maxa owns the MCPHub runtime

With required Lua dependencies and the declared npm backend, `require("maxa").setup(opts)` SHALL directly initialize repository `maxa.mcphub`, locked to MCPHub.nvim commit `7cd5db330f41b7bae02b2d6202218a061c3ebc1f`, including setup, Hub state, UI, workspace, Native framework, events and retained extensions. Module resolution SHALL be unique: no installed/loaded `ravitemer/mcphub.nvim` external plugin or Maxa extension checkout, nor external plugin/build/lock ownership.

### Requirement: Retained baseline capability has explicit removals

Within the import boundary, locked setup, hub, workspace, Native framework, Avante, CopilotChat, lualine and shared extensions SHALL remain loadable/operational on request from `lua/maxa/mcphub/**`. Exceptions are Marketplace UI/state/API, `maxa.mcphub.extensions.codecompanion`, replaced plugin bootstrap, tool-call approval/auto-approval UI/config, built-in Neovim Native server, built-in management Server/Ability `mcphub` and raw Config panel view. Retired paths SHALL NOT be synthesized for compatibility. Missing optional Avante/CopilotChat does not change Chat authorization/project transport.

### Requirement: MCPHub keeps its canonical public identity

Retain non-approval `MCPHub*` events (including `MCPHubStateChange`) and non-approval `vim.g.mcphub*` globals/setup fields. The public configuration command SHALL be only `:MaxaConfig`; `:MCPHub` SHALL NOT be registered or provided as an alias. Lua identity remains only `maxa.mcphub.*`; initialized `require("maxa.mcphub")` exposes Hub state. Parallel `maxa.ai.mcphub`, `require("mcphub")`, `require("util.mcphub")` and child-module aliases SHALL NOT exist. Retired approval events, `vim.g.mcphub_auto_approve`, `auto_approve` and `autoApprove` (including server config) remain absent. The built-in management Server/Ability `mcphub`, its tools/resources/prompts and automatic registration SHALL remain absent; core APIs and other configured services remain operational.

### Requirement: Setup owns bootstrap and transactional recovery

Setup SHALL idempotently register highlights, `:MaxaConfig`, setup state and autocmds, without duplicate commands/listeners or reliance on `plugin/mcphub.lua` / `vim.g.mcphub` auto-bootstrap. Default readiness timeout remains `15000ms`. Configuration command bootstrap allows backend-independent project views under the added panel contract.

| Condition | Required result |
| --- | --- |
| First/repeated MCP setup before readiness | `in_progress`; only Hub readiness permits `completed`. |
| Pre-readiness synchronous/asynchronous config, validation, highlight, UI, ImageCache, retained-extension or Hub startup failure | Visible `failed`, attempt-owned cleanup, retryable. |
| Backend exits after version validation; `EADDRINUSE` without successful takeover; live backend remains unready | Observed process failure or configured deadline reports error and takes the same failure transition. Valid takeover may await the existing Hub within that deadline. |
| Retry with valid dependencies | Replacement Hub can reach ready/`completed`. |

Cleanup SHALL leave no retained attempt-owned Hub/UI references, duplicate subscribers or leaked extension registrations; highlight/UI/retained-extension failures restore pre-attempt state. Hub/UI teardown removes subscriptions and attempt-owned jobs/timers/autocmds. A later `:MaxaConfig` can reopen project-only configuration despite a failed backend without falsely marking MCP ready.

### Requirement: Runtime source boundary is exact

| Disposition | Required paths/assets |
| --- | --- |
| Owned runtime | `lua/maxa/mcphub/**`, including repository Native Server/shared modules `lua/maxa/mcphub/native_servers/**`. |
| Retained runtime/legal assets | Native guide `lua/maxa/mcphub/native/NATIVE_SERVER_LLM.md` for existing creation UI, root `CHANGELOG.md` as historical material, upstream MIT notice `LICENSES/mcphub.nvim-MIT.txt`. |
| Not loadable | `lua/mcphub/**`, `lua/util/mcphub/**`. |
| Absent | `lua/maxa/mcphub/ui/views/marketplace.lua`, `lua/maxa/mcphub/ui/views/config.lua`, `lua/maxa/mcphub/native/mcphub/**`, `doc/`, vendor CodeCompanion bridge, built-in `lua/maxa/mcphub/native/neovim/**`, non-runtime upstream plugin/build/test/example/Git/CI/release/contributor/formatting artifacts. |

### Requirement: npm backend is external and exactly pinned

The external process SHALL be exact npm `mcp-hub@4.2.1` (version `4.2.1`), committed in `bundled/mcp-hub/package.json` and `bundled/mcp-hub/package-lock.json`. `just mcphub-backend-install` SHALL run `npm ci` into `bundled/mcp-hub/node_modules`, then deterministic `bundled/mcp-hub/disable-marketplace.cjs` to remove installed-entrypoint Marketplace initialization/routes before startup. Generated dependencies SHALL NOT be committed.

Missing/invalid exact project-local executable or missing patch marker SHALL fail startup with actionable `just mcphub-backend-install` guidance; no fallback to unpatched backend, global npm, `npx`, old Lazy checkout or `latest`.

### Requirement: MCPHub has no Marketplace runtime

After successful installation, startup/UI SHALL manage only locally configured servers. Marketplace UI/view/navigation/shortcuts/state/catalog APIs/installation flows SHALL be absent. Node SHALL NOT initialize Marketplace, fetch remote Registry/server READMEs, read/write `registry.json`, or expose `/api/marketplace` / `/api/marketplace/details`. User-configured `npx`, `uvx`, `pipx` and other commands remain unrestricted by this removal.

### Requirement: Project MCP configuration is project-owned

Default discovery SHALL prioritize `.maxa/abilities/mcp.json`, then `.vscode/mcp.json`, then `.cursor/mcp.json`, preserving global merge/workspace priority. Pass an existing current-project definition file to backend `--config`. Legacy `.maxa/mcp.json` and `.mcphub/servers.json` are not discovered by default; custom `workspace.look_for` remains supported. Migrate the current repository's owned old file without automatically changing other projects. Discovery does not activate connections.

### Requirement: External Server definitions use effective MCP files

External definitions SHALL come from effective global/project files under that discovery rule. `maxa.mcphub.servers` supplied to `maxa.setup(opts)` SHALL fail with actionable guidance to project `.maxa/abilities/mcp.json`, rather than remain inert. Setup obeys the no-write/no-implicit-connection rules below.

### Requirement: Backend environment keeps credentials scoped to explicit Server references

`maxa.mcphub.backend_env` SHALL accept a string-valued map or a function of the resolved workspace context returning one, defaulting to `{}`. Both UI Hub and exact-project backend startup SHALL overlay these values on the inherited backend process environment, preserve workspace `CWD`, and reject `MCP_HUB_ENV` in this map. Callback/config errors SHALL NOT expose values.

Backend-only values SHALL NOT be merged into the existing `global_env` / `MCP_HUB_ENV` broadcast. External Server configuration SHALL explicitly reference required values through the backend's existing `${env:NAME}` / `${NAME}` substitution. Maxa setup SHALL selectively map Sentry/Twitter credentials and `TWITTER_MCP_PROJECT_DIR` through `util.env.get`, preserving process-environment priority and existing Replicate input mapping; it SHALL NOT export the complete `.env` to `vim.env` or the backend. Missing optional credentials SHALL NOT block Hub setup; explicit Server startup retains missing-variable errors.

`MAXA_RUNTIME_ROOT` SHALL derive from the installed runtime root, independently of the calling project's cwd, for repository-owned Server entrypoints. Private external project paths belong in local environment configuration. This addition SHALL NOT create MCP definitions, start capability Servers implicitly, or change project-over-global Server replacement.

### Requirement: Configured MCP Servers are MCP-backed Abilities

Every effective configured Server SHALL contribute one same-named MCP Ability source. Names are 1–64 characters: lowercase ASCII letter first, then lowercase letters/digits/single hyphens; no leading/trailing/consecutive hyphen or slash. Digit-leading Skill identities are not MCP Server identities. Invalid names fail catalog validation without aliases/normalization.

MCPHub retains implementation, protocol, capability filtering and process lifecycle; project Ability settings own availability. LLM discovery/loading SHALL use Ability, not a separate Agent-facing Server loader/catalog; configured/project-disabled/connected facts remain available internally to Ability catalog/diagnostics.

### Requirement: Ability load preserves explicit MCP activation and authorization

Setup SHALL load effective config and ready backend/health/UI/core APIs without creating/rewriting MCP config or connecting configured External/repository capability Native Servers. Capability sources start disconnected; there is no automatically connected built-in management Server.

| Entry | Connection/authorization contract |
| --- | --- |
| Explicit `load(target="<ability>")` for MCP-backed/composite Ability | May start/reconnect its source and authorize the exact invoking Chat/workspace. |
| Actual MCP tool call with ready committed exact-Chat/workspace state | May connect without a new revision or authorization grant; execution/rechecks are specified below. |
| Skill-only load | May inspect side-effect-free names/collisions; SHALL NOT connect. |
| Discovery, completion, history restore, batch preflight | SHALL NOT connect capability sources. |

Connection is shared transport state, not authorization. Failed/cancelled preparation SHALL commit no partial root authorization and does not globally disconnect the source. Server start/reconnect/stop changes only runtime connection state. Backend setup, completion, history restore, dispatch, UI/backend lifecycle SHALL NOT create missing config or persist connection state; explicit admin definition/policy edits remain config operations. Same-version backend reuse requires compatible activation identity; replace incompatible legacy backends before capability use.

### Requirement: Global MCP definitions belong to Abilities

Default global config SHALL be `<Maxa-root>/abilities/mcp.json`, independent of calling project cwd. Preserve explicitly configured paths and project-over-global whole-Server overrides. Migrate owned `dotfiles/mcphub/servers.json`, remove obsolete link setup and Server-level `disabled` fields; remove approved old `mcp-bridge` instead of enabling it. Definition reads/start/stop do not write availability or create missing config.

### Requirement: MCP availability follows project Ability policy

Server-level JSON `disabled` is retired and ignored by Lua/catalog/backend; `disabled_tools`, `disabled_resources`, `disabled_resourceTemplates` and `disabled_prompts` remain supported. UI/Hub and exact-cwd transports SHALL check normalized project Ability availability before start/load/tool/resource use and after asynchronous connection; prohibition reports the project policy, never administrator JSON policy. Availability and connection remain independent: enabling does not connect; stopping does not disable. One project's prohibition does not stop a Native singleton needed elsewhere. Local backend identity includes `server_disabled_retired: true`; do not reuse incompatible local backends. Discovery/history/preflight keep no-connect behavior, and Agent dispatch still requires exact-Chat authorization.

### Requirement: MCPHub is an internal Maxa AI module without a Chat registration bridge

`maxa.mcphub.*` SHALL own setup/state/UI, process-global UI/workspace backend, Native/External Servers and public Hub identities; no `lua/maxa/integrations/mcphub/**` bridge. Hub SHALL NOT read Chat messages/authorization, inject Chat schemas/messages, register Maxa variables/slash commands or depend on the 17-builtin inventory.

Chat consumes side-effect-free exact-cwd effective catalog discovery and project-keyed tool/resource transport. Chat owns Ability authorization, complete catalog association and `@`/`#` resolution; Hub owns exact config/policy/connected-state checks. Valid backend/config setup exposes internal core/UI/Server APIs. Hub readiness/restart SHALL NOT alter Chat registries or dynamically register/load/connect capability Servers; process-global connections grant neither exact-Chat authorization nor loaded candidates.

### Requirement: Exact-Chat transport is project-keyed and UI-independent

Explicit Chat cwd SHALL resolve one workspace without changing global cwd, `State.current_hub` or the UI Hub. The process-global Hub remains current-workspace UI owner; Chat MAY reuse it only for matching normalized workspace and activation identity, otherwise using/starting that project's workspace backend. Concurrent explicit activations are keyed by `<workspace-key, server-name>`.

Provenance/completion/connection inspection SHALL be side-effect free: query only an already-running exact-identity backend or process Native instance. Missing/incompatible backend returns not loaded without port lease, backend/Server startup or UI mutation. Acquire leases only immediately before explicit backend startup; release after every failed start, timeout, `EADDRINUSE` reselection, normal/abnormal exit, setup rollback, directory switch and explicit stop. Cache reuse requires live PID and normalized workspace/config/activation identity; reject recycled ports belonging to another project.

Same-workspace Chats MAY share connection, never exact-Chat authorization/catalog state. Two projects loading `fixture` and calling `@fixture:identity` each reach their own backend, without switching/authorizing through the UI Hub.

### Requirement: Effective configured Server discovery is read-only and project-aware

Discovery SHALL resolve ordered global/project config from exact Chat cwd, preserve project-over-global whole-Server override and include repository Native identities. Validate optional public `description` and ordered unique nonblank English `triggers` without raw values in errors; no new `purpose`, `load_when` or visibility field.

For MCP-only entries, nonblank effective config description wins; otherwise MAY use an already-available static description bound to the same effective source/workspace. Missing description is valid name-only disclosure; triggers alone invent no purpose. Disabled entries remain internal policy/error facts, not public discovery. Composite routing metadata remains Skill-owned, with no duplicate rows.

Discovery SHALL NOT start/reconnect, authorize Chat, switch global state, create/write config/cache, fetch remote metadata, load implementation solely for metadata or evaluate description callbacks. Raw commands, args, env, headers, credentials and capability schemas stay within MCPHub filtering/transport.

### Requirement: MCP tool definitions remain complete and compact

Ability load SHALL obtain currently allowed tools after exact-workspace capability policy and normalize complete `name`, `description`, `inputSchema`; the compact protected Ability catalog is the sole LLM-visible definition set. Live schemas are structural authority. A same-named composite MAY apply root-confined `ABILITY.yaml.mcp.overrides` to tool/parameter descriptions only; unknown targets, blank replacements, schema edits, missing files or escapes fail preparation. Usage guidance belongs to the package, not a central prompt/cache directory.

### Requirement: MCP concrete resources preserve original identifiers

Each allowed concrete resource SHALL commit its original nonblank single-line `uri` and owning configured server. Identifiers need neither `<ability>://` nor `://`; SHALL NOT derive from display names or be decoded, normalized, prefixed or renamed. Duplicate identifiers within a server fail preparation; across servers they remain distinct. A different URI scheme alone cannot prevent valid tool/resource commitment.

The Ability owner governs source-neutral `#ability[identifier]` file-first selection. If a resource is selected, require committed catalog membership and exact Chat/workspace provenance, then send its original identifier to that same server's resource read. SHALL NOT fetch it as HTTP, auto-start/reconnect, authorize arbitrary tool-result strings or read unlisted identifiers. Templates/prompts and unsupported embedded-resource authorization remain excluded.

Disabled-resource config continues matching original `uri` before normalization. Project Ability availability, connected-state checks, textual read/load restrictions and atomic preparation/failure behavior remain enforced; original identifiers imply neither MCP Apps rendering nor binary conversion.

### Requirement: Chat authorization and project transport keep separate ownership

Before transport, Chat SHALL verify ready committed Ability state, complete catalog-result presence, exact workspace provenance and target membership. Explicit-cwd project transport owns effective config, project availability/capability policy, connected-only Native/External tool/resource dispatch, timeouts and protocol errors; it SHALL NOT inspect Chat messages, import `maxa` or own Ability authorization. Resource access never starts/reconnects; raw config remains MCPHub-owned. Tool connection before dispatch follows the next rule.

### Requirement: Validated MCP calls dispatch without programmatic approval

Validated MCP calls SHALL dispatch only from committed `@ability:tool`. After exact-Chat/workspace authorization, membership, effective server/tool policy and parameters pass, actual execution SHALL connect a disconnected source through existing project transport and await success without approval. Connection failure reports the source error and prevents execution. After asynchronous connection, recheck authorization, policy, parameters and cancellation/Chat closure. Preserve schema validation, disabled-capability policy, exact-workspace transport, result/image/resource normalization and output bounds.

Authorized disconnected sources execute through `run(scope="tool", command="@ability:tool", args=<encoded JSON object>)` with a nonblank title without another Ability load.

### Requirement: MCP and Ability names are aligned in the hard cut

Repository-owned/configured Server names, server-name references and capability policy SHALL satisfy Ability grammar at source/config. Resource URI schemes/original identifiers remain independent and are not renamed to match. `genai`, `session`, `subagent` retain names; retired `cc_history` SHALL NOT return as `cc-history`. No old-name aliases or runtime normalization.

### Requirement: First-party Chat builtins and the retired Neovim tool server are not MCP servers

MCPHub SHALL own only non-builtin MCP sources. Core SHALL NOT automatically register a management `mcphub` Server. `maxa.setup(opts)` SHALL register exactly three repository capabilities from `lua/maxa/mcphub/native_servers/**`: `genai`, `session`, `subagent`. They start disconnected under current composition/policy and authorized execution-time connection rules.

First-party Chat builtins and retired Neovim tools/resources/prompts SHALL NOT be registered/synthesized as MCP Servers/groups; `Native.is_native_server("neovim")` SHALL be absent. Bare builtins remain Chat-owned and callable regardless of Hub readiness. Sources: `lua/maxa/mcphub/native_servers/init.lua`, `lua/maxa/interactions/chat/tools/builtin/`, [Chat Builtins](./chat-builtins.md).

### Requirement: Repository-owned Lua uses full Neovim reload

Behavior changes under `lua/maxa/mcphub/**`, including Native Lua `lua/maxa/mcphub/native_servers/**` source/setup/schema/registration, SHALL receive local validation followed by full Neovim restart-resume for fresh-process validation. MCPHub restart alone is not reload evidence.

### Native local tool presentation

- **Native local display definition**: Raw Native Lua tools MAY provide `display(args,result)` under the sole view contract in `.maxa/specs/runtime/chat-builtins.md`. Framework SHALL retain original `req.tool` for authorized calls, not copy handler/display into new registries. Chat binds the actual definition only after Ability/config/tool policy checks; display resolution SHALL NOT load, reconnect or authorize sources.
- **Local callback protocol isolation**: Agent/MCP catalog projection SHALL exclude local `handler`, `display`, UI handles and `interactive` declarations, preserving public tool names, description, inputSchema and result protocol. Local callables/interaction flags SHALL NOT become model parameters or break load/catalog through function serialization. `interactive=true` is only for authorized local dispatch/preflight; Chat Builtins solely owns batch prohibition rules.
- **Opaque Native UI transport**: Keep `handler(req,res)`. With exact Chat call context, host MAY inject `req.ui` through in-process options; Chat creates/destroys its capabilities. Framework/transport passes the opaque handle without reading Chat messages, importing Chat renderer or depending on builtin inventory. External HTTP/stdio requests SHALL NOT serialize it.
- **Native UI absence behavior**: Ordinary Native calls without Chat/UI context remain executable; input-requiring handlers SHALL report UI unavailable, never guess last/current Chat. Optional progress may be skipped; local display failure uses Chat's safe fallback without changing an already-produced business result.

## Acceptance Criteria

The requirements define acceptance for source/asset/legal boundaries, canonical API/command, retained management UI, dispatch, setup transactions, exact patched backend, reload and separate Chat/Native ownership. Focused static/headless/backend/bridge tests and fresh-Neovim live checks SHALL pass. Historical evidence below retains its dated scope, not a claim of new runtime validation.

### Requirement: Maxa configuration extends the retained panel

`:MaxaConfig` SHALL toggle the existing floating panel with a centered, compact three-row half-block `MAXA` logo, muted offset base and small accent ornaments, one blank row above/below and horizontal clearance, displaying its normalized project root. Built-in panel labels, Help and directly invoked selection/confirmation messages SHALL use English; external Ability descriptions, logs, provider names and user content remain unchanged. Capture the exact invoking Chat's project when present; otherwise use the invoking buffer's project, not whichever cwd/Chat is active when an asynchronous picker finishes. A missing project permits clear read-only/unavailable project-setting feedback, not writes to an invented/other project.

Retain MCP server groups/status/expand, runtime start/stop, config edit/add/delete, tools/resources/templates/prompts forms, custom instructions, prompt preview, log/help views, refresh/restart and Active Hubs operations. The raw Config view, `C` navigation button/keymap and its registration SHALL be absent; effective MCP definition loading/merging/editing remains operational. H displays project availability separately from connected/disconnected/error state; t is runtime start/stop and cannot bypass project prohibition. Definition deletion uses the [guarded Ability deletion](./package-and-authoring.md#requirement-guarded-physical-deletion) checks/confirmation, including Native protection. Renaming definitions cannot bypass those checks: delete the old source through the guarded flow before adding the new name. Internal MCP-specific descriptions may still name the protocol/service; panel-wide title/navigation SHALL identify Maxa configuration, not MCPHub.

Use separate views: `P` for Ability/suites, project availability/visibility/details/filter/reset/delete, `D` for project service defaults; model/adapter controls SHALL NOT be embedded in Ability management. Both use existing view/keymap/row machinery, without a new framework or automatic tool activation, and remain usable when MCP setup/backend is not ready or has failed. Capture invoking Chat identity only in UI, not Hub; show its loaded status only when present. Project selection targets the captured project independently of process-global MCP UI/transport state; H start refuses a mismatched backend project instead of silently acting on another workspace. Adding these views SHALL NOT make Hub inspect Chat authorization/messages or grant MCP permissions. [Ability owner](./package-and-authoring.md) and [Runtime defaults owner](./plugin-entrypoints.md) own their state/actions.

Help (`?`) SHALL be one English Maxa usage page using the existing renderer, describing P/D/H/L/? navigation, relevant controls, availability/visibility/connection versus explicit Chat Ability authorization, inherited defaults/effect scope and existing log troubleshooting. It SHALL NOT load removed `doc/` content or show upstream welcome/sponsorship/community/native/changelog tabs. Native creation UI/internal guide remains supported; MCP Creator routes to its existing package-owned template instead of removed `mcphub` resources.

State/provenance segments SHALL apply existing theme-derived highlights rather than render as uncolored strings: enabled/connected use success; partial availability/connecting/disconnecting use warning; errors use error; disabled/disconnected and provenance use muted; visibility/project overrides use informational accents. Keep state words/icons/counts: color is not the sole signal. Logo/main headings, accents and muted base SHALL have distinct roles. Preserve current palette ownership, safe confirmation warnings and behavior; do not add hardcoded machine-local colors, animation or a presentation framework.

## Validation Evidence

- 2026-10-09: English Maxa panel: affected-Lua syntax/core-load checks and fresh actual English navigation, selectors/cancellation, compact centered padded logo and semantic state highlights passed. Panel paint cleanup prevents cross-view extmark accumulation; settings/external content unchanged. Human implementation review not-run.

- 2026-10-09: Retained plugin surfaces: focused core/Native/completion/setup checks, two fresh-Neovim observations, actual P/D/H/L/? and Help refresh interaction, Config absence and authorized retained `misc:echo` passed. Human implementation review remains not-run; a nonfatal slash-check prompt-discovery warning is recorded task-side without a full-discovery claim.

- 2026-10-08: unified management passed focused real-backend start/stop, project availability and ignored-JSON-disabled checks, followed by actual fresh-Neovim P/H interaction and authorized MCP call. Earlier administrator-policy validation below is historical, not the current contract. Human post-implementation review is not-run.

### Scoped contract evidence

Dated results below retain their actual scope and historical human-review limits.

| Behavior group | Recorded validation and limits |
| --- | --- |
| Original resource identifiers | Focused identifier/ownership checks and full restart, then live GVE `sb-gve` load, safe discovery and textual `#sb-gve[ui://preview-stories/preview.html]` read passed. No third-party identifier/config changes or MCP Apps rendering. |
| Authorized tool reconnect | Scoped automated/live connection evidence passed; human implementation review not-run. |
| Tool presentation ownership | Fresh Native catalogs excluded local functions; actual authorized SubAgent calls supplied their own answer folds and call-scoped progress. Framework/External wire isolation checked in scoped source; human implementation review not-run. |
| Complete presentation projection | Scoped projection stripped local interaction flag; fresh SubAgent catalog reload passed without leakage. Overall human implementation review not-run. |

### Dated runtime evidence

The following checks passed in their recorded scopes, with review exceptions stated explicitly:

- **2026-09-13 — import/install**: Original 75-file baseline passed then-current inventory checks (superseded by accepted 53-file boundary after built-in Neovim removal); exact `mcp-hub@4.2.1` install/version passed via `just mcphub-backend-install`.
- **2026-09-13 — automation/review**: 12 headless groups covered setup/highlight/UI/backend/extension transactions, readiness deadline/retry, changelog/Native/retained-extension/workspace boundaries, direct composition, then-current Maxa AI bridge/ready behavior, live backend, Native load-server and Maxa AI runtime/setup regressions. Independent review's setup/subscriber/changelog/boundary/validation and follow-up backend/highlight/extension findings were repaired; final re-review: `Pass`. Explicit human acceptance approved repository-owned runtime.
- **2026-09-13 — live**: Full restart-resume resolved only `<PROJECT_ROOT>/lua/mcphub/init.lua`, reached `setup_state=completed` / Hub ready, exposed `:MCPHub`, opened/closed UI, configured six then-current Native servers, loaded then-current Maxa AI bridge, completed live `session__get_session_status` and `session__get_loaded_items`.
- **2026-09-14 — builtin ownership**: Former first-party tool server absent; exactly five repository Native servers retained. Focused MCPHub/bridge tests, independent re-review, final restart-resume, live namespaced session calls and explicit human acceptance passed.
- **2026-09-16 — approval/Neovim removal**: Removed approval/config/UI/bridge code and `lua/mcphub/native/neovim/**`. Focused setup/capability/bridge/repository/backend/extension tests, Lua/JSON/static checks and two full restart-resume validations passed. Fresh state: `setup_state=completed`, connected Hub, exact Native list `{genai,json_artifact,mcphub,misc,session,subagent}`, no Neovim server or approval/builtin-tools setup fields; live `misc__echo` without permission prompt.
- **2026-09-16 — Marketplace removal**: Removed UI/state/API; moved discovery to `.maxa/mcp.json`; exact `mcp-hub@4.2.1` gained deterministic disable patch. ProjectAdmin sync, five focused headless/backend tests, patch syntax/idempotence, static checks, full Neovim restart and explicit MCPHub process restart passed. Fresh state: `setup_state=completed`, Hub ready, UI views `{config,help,logs,main}`, no `M` mapping, `/api/marketplace` returned `404`, live `misc__echo` succeeded.
- **2026-09-20 — project transport**: Project-keyed Chat transport, side-effect-free effective config discovery, workspace provenance, port lease/identity lifecycle, disabled capability filtering, remote endpoint handling and data minimization passed focused automation, independent repair review, two restart-resume cycles and live authorized/unauthorized/restored dispatch; human acceptance passed.
- **2026-09-20 — activation/policy**: Explicit activation, runtime-only connection state, administrator `disabled=true`, activation-identity backend replacement, side-effect-free inspection, same-workspace sharing and connected-only dispatch passed all focused MCPHub/Chat suites, live External lifecycle/config-byte checks, two full restart-resume cycles, independent SubAgent review and explicit human acceptance.
- **2026-09-22 — Ability integration**: Exact-name validation, described/name-only/disabled MCP-only discovery, no-side-effect generation, live schema/description overrides, mechanical resource URIs, Chat-independent explicit-cwd resource dispatch, 17-builtin separation and fresh-Neovim live loads passed; human acceptance passed.
- **2026-09-24 — runtime ownership**: Focused composition/setup/transport/backend/module checks and full restart-resume passed. Fresh state: Maxa AI ready, Hub `completed`/ready, `:MCPHub` present, old Lua modules absent, configured `tauri-wdio` disconnected. Explicit `load`/`call` on management `mcphub` and Native `misc:echo` succeeded; human runtime review not-run.

Historical human specification review: `passed` for earlier scopes; automated/live validation: `passed` only for recorded scopes. Latest claimed runtime restart: 2026-09-24; human runtime review of that change: `not-run`, not a separate gate. The opening batch-review note governs later human-review provenance without changing these historical records.

## Source Trace

- Core: `lua/maxa/mcphub/`.
- Composition: `lua/maxa/init.lua`, `lua/plugins/ai.lua`, [Runtime Plugin Entrypoints](./plugin-entrypoints.md).
- Chat transport/authorization: `lua/maxa/mcphub/project_transport.lua`, `lua/maxa/session/abilities.lua`, `lua/util/ability_catalog.lua`, [Maxa AI](./maxa-ai.md).
- Native: `lua/maxa/mcphub/native_servers/`.
- Maintenance: [MCP Creator Workflow](../abilities/base/mcp-creator/mcp-creator-workflow.md).
- First-party tools: [Chat Builtins](./chat-builtins.md).
