---
title: Runtime Plugin Entrypoints 行为规格
created: 2026-06-28
updated: 2026-10-13
type: source
doc_role: spec
authority: accepted
status: active
capability: runtime-plugin-entrypoints
sources:
  - lua/plugins/ai.lua
  - lua/plugins/task_browser.lua
  - lua/plugins/tools.lua
  - lua/util/init.lua
  - lua/util/git_workspace_context.lua
  - lua/maxa/mcphub/native_servers/init.lua
  - lua/maxa/mcphub/native_servers/config.lua
  - lua/maxa/mcphub/native_servers/genai/
  - lua/util/project_nvim_sessions.lua
  - lua/util/nvim_restart_resume.lua
  - lua/maxa/
  - lua/maxa/mcphub/
  - bundled/mcp-hub/package.json
  - bundled/mcp-hub/package-lock.json
  - prompts/system.md
  - prompts/soul.md
  - prompts/commands/
  - tests/system_prompt_contract_spec.lua
confidence: high
review:
  human: passed
  evidence: user-declared-change-review-2026-10-07
---

### Scope

Owns composition/wiring, not peer runtime/`../prompts/` adapter wire, 17-tool inventory, session internals or prompt bodies. Maxa AI composes Chat/MCPHub/HTTP/media/default/status; `tools.lua` wires editor persistence; Task Browser is separate UI. Imperatives mean SHALL; MAY remains optional.

### Core composition

#### Requirement: `ai.lua` supplies deployment options to the Maxa AI composition root

After third-party dependencies and final Lazy merge, `lua/plugins/ai.lua` calls `require("maxa").setup(opts)` exactly once with deployment adapter/model, providers, display, rules, prompts, Chat/Actions, tools, slash commands and session/lifecycle options. Load Maxa AI/MCPHub from repository runtime paths, not external plugin/lock entries. Keep Plenary, Treesitter, render-markdown, img-clip, completion/noice/lualine; omit `mini.diff`, `extensions.mcphub` and bridge fields. Internal composition below owns MCPHub/Native setup, never the plugin spec.

#### Requirement: Shared Lua defaults compose before consumers

`lua/maxa/config.lua` owns model knowledge/providers/presets/model-limit overrides, lifecycle/retry/compaction, translation/Telegram/GenAI/status/tool tuning/SubAgent/upload/MCPHub defaults. `ai.lua` supplies deployment adapter/model/media/upload-hostname choices and provider declarations through Lazy `opts.maxa.providers`, never registering/resolving providers or injecting HTTP adapters.

After final merge, `maxa.config.setup(opts)` registers capabilities/composes HTTP adapters before HTTP adapter setup; `maxa.setup(opts)` consumes those values. Preserve project/env defaults, explicit/restored Chats, per-adapter compact/summary complete-block overrides and persisted GenAI precedence.

#### Requirement: Separated default roles and preset discovery

`maxa.defaults` owns `chat`, `compact`, `summary`, `translate`, `title`, `image`, `tts`, `video`; each value is a named reference or inline configuration. `maxa.presets` owns arbitrary reusable names with `type=chat|image|tts|video`, optional boolean `visible` (default false) and `description`. Visible entries require nonblank description. Unknown/wrong-type references fail before dispatch; metadata never enters provider parameters.

Runtime replaces `<presets_table>` with a name-sorted, cell-escaped name/type/description table for visible entries; hidden entries remain callable. Metadata guides selection, not permissions or higher-authority instructions. Omitted selectors preserve configured defaults/inheritance.

#### Requirement: Preset lookup distinguishes missing names from empty inheritance

- No new named preset is reserved or mandatory. Composition supplies nonblank adapter through `defaults.chat`; shared compact uses `adapter="inherit"`; omitted summary/translate/title use `defaults.chat`.
- Explicit named lookup does not become role lookup based on spelling. Named Chat configurations support `model`, `thinking_mode`, `temperature`, including `0.0`; inheritance is explicit.
- Untyped legacy `presets.default/compact/default_agent` and legacy GenAI globals remain compatibility inputs only when the corresponding new role is not supplied. Preserve legacy parent inheritance; do not inject those names into the new registry.
- Provider/adapter compact and summary complete blocks, including automatically generated compact, win before role defaults without filling missing fields. `compact_self` forces parent adapter/model inheritance independently.

#### Requirement: Background requests use named shared presets

`Background.new()` uses `defaults.chat`; explicit `preset` resolves the named registry, while internal `default_role` resolves the role with parent-aware provider priority. Reject raw adapter names/specifications/resolved objects. Parent-aware compact preserves inherited settings/provider overrides, subject to `compact_self`, never a fixed deployment model. Automatic title callbacks require explicit enablement.

#### Requirement: Final Lazy options are the deployment source

Declare deployment in Lazy `opts.maxa`; plugin-spec loading neither configures Maxa nor expands presets. Only final merged options feed provider/preset composition and one-time deployment command/translation registration. No pre-merge `deployment` table or comparison-based copied-field repair. Restart-resume registers early as below.

#### Requirement: Named Chat and title preset references

Chat resolves `defaults.chat` at creation; automatic title resolves `defaults.title` at request time. Explicit `interactions.chat.preset`/title-generation `preset` remain named references; internal title `default_role` is not a registry name. Both use final merged configuration, never copied `ai.lua` fields. Preserve explicit adapter/model, explicit/restored Chats and project > global > shared precedence.

#### Requirement: Provider model preset references

After Lazy merge, `opts.maxa.providers.<id>.llm.<protocol>.schema.model.preset` selects the named preset's model, including the provider's corresponding choice. Missing preset/model errors; explicit model declarations without preset are unchanged.

#### Requirement: External integrations use canonical identity

Filetype rendering, clipboard images and completion target only `maxa_ai`; no old Chat filetype, Agent Loop or `pause_loop` command/continuation registration.

#### Requirement: Restart-resume is registered early

Lazy `init` registers configuration-independent `util.nvim_restart_resume.setup()` before `VimEnter`, avoiding lazy AI startup-data loss. Valid `.maxa/tmp/nvim-restart-resume.json` drives editor restore → MCPHub readiness wait → history Chat lookup/recreation → resume-message append/submit when possible. Failure never force-interrupts other active Chats.

### Prompt and rules assembly

Source/fragment errors fail explicitly without identity replacement or instruction loss.

#### Requirement: Generated system prompt is inspectable

`:DumpSystemPrompt` resolves project context and opens generated default Runtime + selected default Soul in read-only Markdown scratch. `:DumpSystemPrompt current` instead shows stored Chat Runtime/Soul and applicable mode instructions; missing Chat/base prompt errors. Distinguish views by command/display context, never model-visible debug markers. Neither includes provider schemas/later injected context/Abilities nor claims a complete provider request.

#### Requirement: Soul selection is explicit and project-aware

Mandatory Runtime: repository `prompts/system.md`. Select one complete Soul: explicit `soul` (legacy child `soul_file|soul_prompt` supported) → `<project_root>/.maxa/soul.md` → valid root `soul` in `.maxa/_meta.yaml` → `prompts/soul.md`. Missing optional project Soul advances; selected unreadable/invalid/empty Soul or missing Runtime fails without fallback. Main Chat stores separate initial Runtime/Soul messages; `GenerateSystemPrompt` MAY return a combined string. Inheritance retains selected Soul; project Soul never stacks global Soul or retired system content. Legacy metadata projection follows the canonical metadata contract.

#### Requirement: Project prompt inputs and fragments are deterministic

Retired `.maxa/system.md`/`<system_prompt>` wrapper expansion has no effect, Soul reinterpretation, automatic conversion or alias. Expand `<plugin_rules_root>`, `<date>`, `<vim_ver>`, `<machine>`, `<root_dir>`, `<git_workspace_context>`, generated Ability table/index and declared Ability `SYSTEM.md` slots. Apply project-over-global fragment overlay then slot/priority order; nonempty unknown/unconsumed slots fail exactly, never drop mandatory instructions. Only `<project_root>/.maxa/AGENTS.md` may auto-load project rules, as separate ordinary context—not Soul/system replacement or alternate Rules-group lookup.

#### Requirement: Model context exposes only an exact explicit Git Workspace match

Read only `<project_root>/.maxa/workspaces.yml`; normalize current root/configured absolute paths and require one exact valid `main|child` definition. Match emits one XML-safe `<git_workspace type="main|child" name="…">` containing one `<responsibility>` inside `<model_context>`. Missing/unreadable/unsupported-version/incomplete/duplicate-path/unmatched definitions emit none; never leave `<git_workspace_context>`. No primary-worktree discovery, Git/uv/Python invocation or branch/directory/template inference.

#### Requirement: Prompt library reads repository and project prompts

`lua/maxa/prompts/{markdown,sources}.lua` discovers direct Markdown non-recursively/no watcher from fixed `<maxa-root>/prompts/commands/`, `<project>/.maxa/prompts/` and eligible effective Ability `prompts/`; missing optional roots yield no candidates. No `config.prompt_library` Lua entries, custom directories or runtime builtin prompts; metadata has no interaction modes/Actions options.

Startup discovers current project; Chat creation/restore prepares exact project scope without Ability load. Chat-owned `project_root`/`cwd` governs lookups/isolated caches, never another window's cwd.

- **Chat cache refresh includes prompt discovery**: `:Maxa RefreshCache` rescans calling Chat/project prompt discovery plus existing Chat filters; another window/project cwd cannot change sources.

Peers own [Ability declaration/activation](./package-and-authoring.md), [priority/collisions](./chat-commands.md), [format/insertion](../prompts/markdown-format.md).

### Gateway adapters

#### Requirement: Provider owns adapters

`opts.maxa.providers` maps stable IDs to connection/quota defaults and optional `llm`/`genai` declarations: one named adapter per supported LLM protocol/media capability. Media `adapter` MAY be omitted and defaults to provider ID; explicit names remain unchanged. Same-provider LLM/media may share names without connection inheritance; distinct LLM protocols/providers may not claim the same name. Maxa config parses/composes. Reject undeclared services, including `opts.adapters.http.<name>`; consumers select declared names, not a separate provider selector. Unknown names fail descriptively, never resolve independent built-ins. Protocol implementations remain reusable bases; retain non-service `opts.adapters.http.opts` except obsolete proxy settings.

#### Requirement: Central model knowledge

Combine `session/model_limits.lua`, HTTP `schema.model.choices`/opts and `maxa.models` overrides into one effective protocol/model capability, context and warning/output-threshold view. No all-model enumeration in `ai.lua`; handlers/schema own wire mappings. Unknown models inherit no unverified capabilities/limits.

#### Requirement: Gateway factory requires an explicit supported protocol

One provider `llm` block → one named HTTP adapter. Supported keys only:

- `openai_responses`: extend Responses at `<normalized-base>/responses`; preserve request/schema, unsupported-parameter sanitation, stable `prompt_cache_key`.
- `anthropic_messages`: extend Anthropic at `<normalized-base>/messages`; preserve handlers/headers, omit Responses-only settings.
- `openai_compatible`, `gemini`: existing implementations/endpoints, not Responses/Anthropic suffixes/handlers.

Blocks MAY override provider connection defaults and `schema`, `headers`, `handlers`, `raw`, `env`, `url`, not provider-owned proxy via `llm.proxy`/`llm.maxa.proxy`. Unsupported protocol, blank name or missing effective URL/key fails before requests. Wire incompatibility requires explicit code extension as DeepSeek uses; config cannot define new protocol implementation tables/arbitrary model-response parsers.

#### Requirement: Chat stage timeout configuration is centralized

`maxa.lifecycle.watchdog` owns these independent millisecond controls, each default `180000`:

| Field | Owner and boundary |
| --- | --- |
| `connect_timeout_ms` | curl connection establishment, including DNS/TLS establishment semantics. |
| `first_response_timeout_ms` | watchdog from HTTP dispatch until first effective output; may overlap connection establishment. |
| `response_idle_timeout_ms` | watchdog while receiving text/reasoning or subsequent effective response progress. |
| `tool_args_idle_timeout_ms` | watchdog while receiving model tool arguments, not while executing tools. |

Positive finite values enable the stage; `-1` disables its local enforcement, not real upstream failures or recovery. Reject zero, other negatives and invalid/non-finite values. `check_interval_ms` remains positive, default `10000`. Neither connection nor first-output setting implicitly disables the other. [Lifecycle](./lifecycle-and-message-injection.md#requirement-chat-watchdog-observes-effective-request-progress) owns effective progress and request settlement.

#### Requirement: Chat timeout configuration preserves explicit precedence

Explicit canonical value > explicit legacy alias > default. `no_message_warn_after_ms` maps to first response; `no_progress_warn_after_ms` maps to either unspecified idle stage through early/setup composition. Tolerate obsolete `max_auto_submit_retries`, but do not use it as another retry budget.

#### Requirement: Chat curl timeout arguments derive from centralized policy

Per Chat request, remove conflicting connection/low-speed/response-total raw options, including equivalent short forms, without mutating shared adapters. Positive connection values emit exactly one `--connect-timeout` in seconds; `-1` emits none, including removing HTTP defaults. Preserve protocol/proxy/TLS/retry options and auxiliary-request policy. `--retry-max-time` remains a retry window, not a response-total deadline.

#### Requirement: Anthropic gateway schema is safe

At construction resolve `schema.model.choices` to table and `schema.model.default` to string. Apply replacement/extension/discovery/default rules below even on discovery failure; never admit undiscovered official Anthropic models. Fallback default supplies implicit compact unless overridden.

#### Requirement: Explicit model-choice replacement

Normal `schema.model.choices` extends options for compatible provider-listed IDs/explicit corrections without absent-model leakage. `model_choices="replace"` requires nonempty `schema.model.choices` and uses only it regardless of discovery. Other schema keys retain `adapters.extend()` merge semantics.

#### Requirement: Gateway model discovery is opportunistic

- Without explicit `models`, query OpenAI-compatible `<normalized-base>/models` with each adapter's effective key. Anthropic defaults: `x-api-key`, `anthropic-version: 2023-06-01`; `models.headers` may override.
- `models={source="api",url=...,headers=...,fallback=...}` supplies custom discovery/explicit fallback; `models={source="static",choices={...}}` requires nonempty choices/no request.
- HTTP `>=400`, malformed/empty data or network failure permits only configured fallback/explicit protocol choices; otherwise unavailable, never implicit protocol lists. `/models` failure does not prevent endpoint construction.
- Response `data` accepts string IDs or objects with nonblank `id`; display priority: `display_name` → `name` → `formatted_name` → `id`. Known models require matching protocol except explicit corrections; discovered uncataloged IDs remain selectable without inferred capabilities/limits.
- Missing preferred default selects first sorted nonempty effective ID; empty list fails. Cache without cross-key leakage; no discovery during adapter/media picker listing. Responses choices MAY be functions; Anthropic construction follows its shape rule above.

#### Requirement: Backend and quota metadata have one source

Metadata: `backend.provider` = provider `type`; `backend.protocol` = LLM key; `backend.api_root` = normalized effective service base. Provider-only `quota`: `nil|false` disables; `true` is type-derived; table specifies only type-specific differences (e.g. `newapi` `access_token`/`user_id`), not implementation kind/proxy policy.

One balance source serves all provider adapters; adapter status remains available. Every request uses current provider proxy. Unregister discards the stored quota adapter and stops/invalidates cached provider-group source; remaining adapters MAY recreate lazily. Missing billing credentials → unavailable/no request/no invented balance. Never expose secrets in diagnostics/specs.

### Scoped Chat defaults

#### Requirement: New Chats resolve project > global > shared

Resolve new Chats from source-buffer project: complete root `default_adapter` + `default_model` in `<project>/.maxa/_meta.yaml` → complete runtime `.env` `MAXA_AI_DEFAULT_ADAPTER` + `MAXA_AI_DEFAULT_MODEL` pair → shared preset. Explicit constructor/restored adapters win; no project leakage within Neovim. Legacy-wrapper reads follow the canonical metadata contract above.

#### Requirement: Project metadata edits are conservative

Project write/clear touches only owned root settings in existing readable `_meta.yaml`, plus explicit legacy-wrapper migration under the canonical metadata contract. Reject duplicates, conflicts, malformed mappings and incomplete model pairs; preserve other fields/comments/order; publish by sibling temp + rename. Missing metadata never creates governance files; pickers create neither `.maxa/` nor `_meta.yaml`. Global write/clear preserves unrelated `.env` lines.

#### Requirement: Default picker is scope-aware

`<leader>aA` global, `<leader>aa` project and exact-Chat `ga` normal-mode pickers share the stable `llm/image/tts/video` overview: effective LLM adapter/model and media adapter, explicit unconfigured/unavailable feedback and no state change on cancel at any stage. Configured incapable media are unavailable. Media lists only declared capable adapters, selecting adapter not model. Unsupported-medium errors name adapter/medium without secrets.

`<leader>aA` initially shows/edits global values only: LLM adapter/model with `Clear Default Override`; media changes global selection. `<leader>aa` initially shows/edits its captured project's values and inheritance sources only, persists to `_meta.yaml` and offers per-service inheritance; no global-scope switch. Neither silently changes an existing Chat's LLM adapter. Existing callable scoped-default APIs remain available.

### GenAI adapter capabilities and picker

#### Requirement: Adapter declarations are the only media capability source

Providers MAY declare one block each for `genai.image`, `genai.tts`, `genai.video`. Present blocks declare independent media services; optional `adapter` naming and capability/provider-only connection precedence are owned by [GenAI](../abilities/base/genai/native-mcp.md#requirement-adapters-are-the-only-media-service-identities). Presence alone means support; absence unsupported. No `enabled` flag or protocol/URL/key/models/type/endpoint inference. Validate/copy into lightweight media-name registry without LLM construction/discovery. Do not publish media capabilities on LLM adapters; media-only needs no fictitious LLM protocol.

Capabilities own mode, credentials, relative endpoints, request policy/limits and per-service defaults. Non-absent tool params override capability defaults, then GenAI global defaults. Proxy remains provider-owned.

#### Requirement: GenAI defaults are independent by medium

| Medium | Runtime defaults | Persisted adapter key |
| --- | --- | --- |
| Image | `model=gpt-image-2.5`, `text_model=gpt-5.5`, `requested_size=auto`, `output_format=png` | `GENAI_DEFAULT_IMAGE_ADAPTER` |
| TTS | `model=gpt-4o-mini-tts`, `voice=alloy`, `response_format=mp3`, `speed=1` | `GENAI_DEFAULT_TTS_ADAPTER` |
| Video | `model=sora-2`, `seconds=6`, `size=1280x720`, `resolution_name=720p`, `preset=normal` | `GENAI_DEFAULT_VIDEO_ADAPTER` |

Shared adapter defaults are `{}`; repository `lua/plugins/ai.lua` selects `xuanjing_openai` for all three before consumers initialize. Persisted selections independently/immediately override deployment, preserving other keys/env content. Neither choice configured → explicit no-adapter error; selected adapter lacking explicit medium capability → unsupported, never inferred availability.

#### Requirement: Unified session and global adapter pickers

Under the shared picker contract, `ga` shows current LLM/effective media with session/project/global source labels; changes affect only this Chat. Media marks the current effective adapter and offers `Restore Project/Global Default`, which clears only its session override and resolves project then global inheritance. No candidates errors without default mutation; stale overrides remain clearable.

Keep callable selectors. `<leader>aA` is now the global entrypoint; `<leader>aa` is the project entrypoint. `<leader>cxm`, `gI`, `<leader>cxia`, `gip`, `gia` remain absent. Four media tools retain optional `adapter`, never expose/read `provider`. [GenAI owner](../abilities/base/genai/native-mcp.md#requirement-defaults-are-independent-by-medium) owns precedence/persistence; `gi` remains cursor inspection owned by [Maxa AI](./maxa-ai.md).

#### Requirement: Gateway proxy policy is metadata-owned

Global `opts.maxa.proxy` defaults to `"env"`; omission uses that default. `"env"` resolves `HTTPS_PROXY`, then `HTTP_PROXY`, then `ALL_PROXY`; nonempty process values precede runtime-local file values. Explicit `false` disables the shared proxy and MUST NOT consult environment. A custom address string or function(current provider with stable ID) → address/`nil` remains supported. No address means direct. Proxy values are data, not activation, and SHALL NOT be exported globally or injected into unconfigured consumers.

Provider `opts.maxa.providers.<id>.proxy` routes:

- Omitted/`false`: direct.
- `true`: evaluate global for this provider; disabled/unset/`nil` = direct.
- Address string: own address, never consult global.
- Function(provider): own address/`nil`, no global fallback.

Reevaluate each newly started HTTP operation: discovery, application retries, media follow-up/polling, balance. Curl-internal retries MAY reuse invocation policy. Direct/`nil` forbids legacy/inherited process-proxy fallback; model-discovery requests SHALL add `--noproxy '*'` only when no proxy is resolved, never alongside an enabled proxy. Empty/invalid address, bad config/return type or callback failure errors descriptively, never silently reroutes. No adapter-name/provider-type allowlists or adapter-level override granted by provider metadata identity. Non-provider user `/image` URLs do not inherit Chat-provider proxy by name.

MCP proxy variables SHALL be supplied only through existing explicit server env declarations; backend placeholder inputs do not activate proxying for other servers. Existing proxy-consuming shell commands use `tools/proxy-env.sh` to resolve process/selected-file proxy fields without executing the file or loading unrelated secrets. Preserve existing route enablement, explicit overrides and consumer fallback order; no automatic reachability detection or new direct/proxy retry switching.

The standalone `install.sh` accepts only explicit `--proxy <http(s) URL>` for proxy selection. Omission routes directly and ignores inherited proxy variables; it MUST NOT read project proxy configuration. Missing/empty/unsupported proxy input fails before installation effects. Explicit mode passes the selected address to normal and elevated network commands; direct apt mode is explicit. Existing .env preservation/template initialization is not proxy configuration consumption.

### Chat/MCPHub/UI wiring

#### Requirement: Chat builtin inventory is referenced, not duplicated

Default Chat uses exactly 17 first-party tools from [Chat builtins](./chat-builtins.md); no name duplication here or tool-system-prompt summaries/`replace_main_system_prompt` configuration. Allow configured tool-error auto-submit. [Maxa AI](./maxa-ai.md) owns tool/Rules message boundaries.

#### Requirement: Slash commands use explicit owned callbacks

Register session/history/fragment/upload/trace/compression/repeat/Ability-picker commands through current `maxa.session.*`; [Chat commands](./chat-commands.md)/[Session compression](../abilities/base/session/session-compression.md) own semantics. No `util.mcphub.cc_history`, Agent Loop or `pause_loop` registrations.

#### Requirement: Repository-owned MCPHub is composed directly

`ai.lua` never calls `mcphub.setup`, composes `native_servers` or independently initializes plugins/extensions. `maxa.setup` directly initializes MCPHub from effective `maxa.mcphub`, registers repository Native Servers and preserves process-global UI/current-workspace control plane, `auto_toggle_mcp_servers=false`, `explicit_server_activation=true`.

Reject `maxa.mcphub.servers` as unsupported with actionable project-config guidance, not an External catalog. Project External Servers belong in `.maxa/abilities/mcp.json`, not shared defaults. Require pinned `bundled/mcp-hub/node_modules/.bin/mcp-hub` with deterministic Marketplace-disable/explicit-activation patches. Missing backend or version/source/final-fragment mismatch fails installation/runtime validation closed with `just mcphub-backend-install` guidance; no global/latest/Lazy fallback.

Readiness connects no External/capability Native Server, creates no config and grants no Chat authorization. Core APIs and process-global UI provide the control plane; the built-in management Server/Ability `mcphub` and its automatic registration remain absent. Discovery reads exact-project config without transport start, UI-Hub switching, file creation or config writes. No approval setup, retired Neovim Native server or dynamic-registration bridge.

Only unified Ability `load` activates/authorizes Agent capability. Startup, Hub restart, completion, history restore and `@ability:tool`/resource-selected `#ability[target]` dispatch never auto-load; connection/workspace state grants no dispatch permission. UI start/stop MAY change allowed connections, not Chat authorization or project Ability availability. Successful composite/MCP load publishes only exact-Chat provenance-bound revision/catalogs.

#### Requirement: Runtime lifecycle and status UI initialize deterministically

Initialize direct lifecycle/session/Telegram owners once, including idempotent completion-listener defaults. Available Lualine adds details/notify/spinner with `__maxa_ai_status` markers. Task Browser registers UI commands/navigation only for recognized buffers, never replaces protocol authority.

Request metrics are process-local and grouped by stable adapter name across all HTTP consumers, including silent/background, child Chat, compaction, title and cache-warmup requests. Adapter-owned `parse_metrics` normalizes effective output progress and usage; unsupported adapters provide no invented measurement. Exclude failed/cancelled requests, input/cache tokens from speed, protocol-only first chunks and repeated terminal output. Prefer final provider output usage; fallback output counts use cumulative UTF-8 bytes divided by four without per-chunk rounding. Output usage already includes reasoning tokens.

Lualine shows the current Chat adapter's shared `[1.2s] [35.8 tks]`: arithmetic mean request-to-first-effective-output time and total output tokens divided by summed request durations, excluding tool/user waiting. In-flight observable output contributes estimated counts until final provider usage replaces it. A user submission and its automatic tool continuations form one Chat round; the next editable `Me` heading shows the completed round's `[12.4k tok] [1.2s] [35.8 tks]` as virtual text, never role/input text. Round token totals sum provider input and output usage; unavailable totals show `--`, not output-only totals. Neither metrics scope is serialized or restored from history; values have no `~` prefix.

`interactions.chat.opts.notify_when_done_default=false` exactly; no `ai.lua` override. Seed process-local effective default from config; global normal `<leader>aN` toggles/reports for future Chats only; restart discards toggles/reseeds. New/history-restored eligible main Chats initialize once after post-construction markers settle; exclude positive `_subagent_recursion_depth`, `_maxa_hidden_image_analysis`, `_is_rescue_session`. Delayed enabled initialization revalidates exact Chat liveness without manual-enable success notification/binding-status check.

Listener persists across success/error/stopped/cancelled turns until disable/toggle/close; runtime-only, never serialized/recovered. Restore may create a fresh listener only from current default. Cancel then stopped/error yields at most one decision. Lualine: `🔔` active, `🔕` inactive, no `📡` or listener/binding exclusion. Local input remains available between turns.

Suppress terminal-turn topic delivery only on positive observation: exact buffer visible in current tab, including unfocused split, never hidden tab. Without tmux this suffices; with tmux a connected client must also show the exact window containing `TMUX_PANE`. Tmux checks are async/bounded. Partial/invalid env, command/output error, timeout, no client, wrong window or callback after buffer ceased foreground → conservative send. Disable/close invalidates pending callbacks without sending. Retry/race rules follow; eligible idle TG input is independent of delivery success.

#### Requirement: Final response presentation projects local file links

At the tool-free terminal response boundary, apply [local Markdown link projection](./chat-commands.md#requirement-local-markdown-link-projection-preserves-canonical-content) to the selected visible assistant response, independent of notify activation or foreground suppression. Preserve canonical model/history text, editable draft, cursor and message provenance. History rendering reconstructs eligible final/pre-ask presentation, not arbitrary intermediate/tool output. Actual terminal Chat and redraw observation confirmed automatic URLs, raw canonical paths and unchanged draft.

#### Requirement: Completion notices retain the complete LLM response

Completion-listener notices MUST retain the complete selected LLM text between their existing status/header and reply hint, except eligible local Markdown destinations are projected through the [file-link contract](./chat-commands.md#requirement-local-markdown-link-projection-preserves-canonical-content) before delivery. Do not normalize, summarize or truncate other text. Use [complete sequential notifications](../services/telegram-bridge.md#requirement-plain-telegram-notifications-are-complete-and-sequential). Existing foreground suppression, listener lifecycle, exact-topic delivery, reply admission, receipt edits and bounded safe pre-delivery retry remain unchanged; no whole-notice replay after partial delivery.

Existing listener checks passed on 2026-10-12; user-observed long delivery verified its shared plain-notification send path after full Neovim restart. A post-restart actual hidden Chat completion delivered its projected file URL in the notification receipt; foreground observation suppressed the preceding notice. A new full-length listener terminal-turn interaction was not separately exercised.

#### Requirement: Neovim notify-only Telegram control surface

No `:TelegramAttachChat`, `:TelegramDetachChat`, `:TelegramUnbindChat`, `:TelegramChatStatus`, `<leader>at`, `<leader>aT`. `:TelegramBridgePing`, `:TelegramBridgeStart`, `:TelegramBridgeStop` MAY remain; `<leader>aN` retains default-toggle role.

Notify-active idle Chats accept authorized exact-session-topic TG messages while locally editable. Preserve unsent local drafts; reject TG submission if busy/notify disabled before submission. Local-only input never depends on listener state; serialized history cannot reconstruct activation beyond effective default.

#### Requirement: Reply opportunity on a completion notice

For an unobserved notify-active terminal turn, attempt an exact-topic completion notice: replies/ordinary topic messages require Chat open, notify-active and idle. Positive foreground observation or stopped/error duplicates after cancellation send no further notice.

- Known pre-delivery connection failure/explicit retryable rate limit: bounded delayed retries only while enabled and same completed turn current; exhaustion → local error. Timeout/ambiguous delivery failure: no blind retry risking duplicate delivery.
- Disable/close/newer completed turn cancels pending retries; intentional foreground suppression never retries.
- Local ordinary input before TG claims opportunity MUST asynchronously attempt one edit of the last delivered segment, preserving its original text and appending `⏳ 已在 Chat 端继续；上一轮回复机会已结束，请等待本轮完成通知。`. If input precedes send acknowledgment, attempt after successful delivery only while the same listener generation/turn remains current. Retain receipt/exact caller identity in runtime state only. No new message, retry, fallback, user-visible warning or Chat error is permitted for this edit; missing receipt, old/unavailable Bridge, timeout and all edit exceptions leave submission/conversation unaffected.
- TG-origin submit, `@ask` reply, automatic continuation, delivery failure, disable or close never falsely announces a local win.

On 2026-10-12 the user confirmed local-first input only edited the existing TG notice without another notification. The real missing-message edit returned unsuccessful without a Chat warning. Pending-delivery race and long-segment status edits were not independently observed live.

### Project-aware Neovim sessions

#### Requirement: Persistence ownership resolves per operation from global cwd

`lua/util/project_nvim_sessions.lua` reads canonical `vim.fn.getcwd(-1,-1)` per `current/save/load/list/last/select`, selects nearest ancestor with real `.maxa/` directory and retains operation scope. Buffer paths/`:lcd`/`:tcd` cannot select scope. No marker preserves ordinary `persistence.nvim`; cwd/filesystem failure visibly errors, never fakes ordinary-project fallback.

#### Requirement: Maxa editor sessions are project/branch scoped

Store only under `<root>/.maxa/history/nvim/`: branch `branch-<sha256-exact-branch-name>.vim`, detached `detached-<full-commit-id>.vim`, non-Git `default.vim`. Header: `\" maxa-nvim-session: ` + compact JSON `{version=1,kind=branch|detached|default,value=<exact label|null>}`. Validate header/filename agreement; `main` ≠ `master`. Only save creates directories; missing read store is empty. Unexpected Git execution failure errors, never overwrites non-Git slot.

#### Requirement: Persistence public APIs share project routing

Preserve `persistence.current/save/load/list/last/select` and four LazyVim keymaps. Exact restore: current branch only/no fallback. Latest: newest valid current-project slot across branches. Picker: selected exact file/no branch recomputation; abort on global-cwd scope change while open. List/latest sort mtime seconds then nanoseconds descending, filename ascending tie-break. Restart-resume `load({last=true})` obeys project boundary.

#### Requirement: Session writes preserve the last complete record

Write `mksession` to operation-unique store temp, prepend validated header, replace final slot only after complete success. Failure preserves prior file/cleans owned temps where possible. Skip/warn malformed/unreadable/disappearing records; listing never executes Vimscript. Missing/invalid/source errors report operation/path/cause, never successful restore/save or source rollback. Concurrent processes: last-successful-writer-wins; no locking/merge, migration, dual write, global fallback, branch checkout, project registry or buffer partitioning.

### Validation

#### Automated/runtime evidence retained

Historical evidence below retains its scope; original tasks own implementation details. No new Agent UI run is claimed.

- Unified model selection: fresh `ga`/`<leader>aa`, LLM/media branches, set/clear, inheritance/unavailable feedback. Earlier picker mappings below are historical.
- Notification/session input: local/idle TG submit, receipt/draft preservation, replyable/local-first notices, foreground+tmux suppression vs hidden/unobserved send, safe pre-delivery retry vs no ambiguous/suppression retry. Actual command/keymap/lualine checks: no bindings/`📡`, retained controls/toggles, notify-off/close rejection. Bridge/Lua/restart evidence retains its recorded scope. User confirmed remaining notification/idle TG/receipt/draft/local-first observations 2026-09-30.
- Gateway smoke: Responses/Anthropic endpoints/protocol/schema/quota/fallback; fresh `xuanjing_anthropic` excludes official Anthropic choices. Scoped-default tests: precedence, YAML preservation/clear, two-project isolation, explicit/restore bypass, picker stages.
- Chat stage policy: actual early/setup composition, legacy precedence, invalid/disabled values and final curl argv passed focused checks; fresh Neovim loaded all four `180000 ms` defaults and completed ordinary Responses requests. Live provider-outage/stall and Gemini/Anthropic API requests were not induced; simulated timeout evidence is not live outage evidence.
- GenAI: 120 focused Lua cases, Native restart/reload, five live tools; four schemas have `adapter`, no `provider`; historical `gi` only; proxy true/false/rename/discovery passed.
- Editor sessions: `tests/project_nvim_sessions_spec.lua`, `tests/project_nvim_sessions_wiring_spec.lua`, Stylua/diff passed. Earlier fresh composition: no `mini.diff`, approval field or retired Neovim Native server.
- 2026-09-23 prompt: main/child rendering, XML escaping, unmatched/duplicate fail-closed, complete placeholder removal; no Git/external process for workspace context.
- 2026-09-22 composition: 17 builtins, unified loading, `auto_toggle_mcp_servers=false`, no `extensions.mcphub`/bridge, exact-Chat transport independent of Hub; focused suites/restart/live authorized calls and human acceptance passed.
- 2026-09-24 runtime ownership: composition/setup/transport, full restart, management/Native calls, disconnected project `tauri-wdio` discovery. Human runtime review then not-run.
- 2026-09-20 activation: global/project backends `explicit_server_activation=true`; fresh-ready zero capability connections, same-version incompatible backend replacement, runtime-only UI; two restarts/live load/stop/reconnect/disabled-policy/config-hash and human acceptance passed.
- Listener: focused consecutive turns/current-tab/unfocused split/hidden tab/tmux failure/cancel dedupe/stale callbacks/binding exclusion/lualine; full restart/runtime-only toggles. User confirmed tmux-detach delivery 2026-09-18. Default automation: false/configured defaults, restored/future-only, helper exclusions, silent/nonpersistent activation; setup-atomic 6/6, configured keymap/default smoke and human acceptance passed 2026-09-19. Binding behavior later superseded.
- Human specification reviews passed through 2026-10-07; earlier human not-run remains historical. Automated/live gaps and unmeasured model behavior are unchanged.

#### Unrun or limited validation retained

- Project defaults: original live `gA` Global/Project, two-project creation/restored-Chat smoke incomplete; automated isolation/persistence is not UI acceptance.
- GenAI: paid TTS/video unrun; upstream deployment availability unverified.
- Editor sessions: real Windows rename-over-existing, interactive two-project keymap/layout/cwd, full fresh-process restart-resume UI acceptance incomplete.

Recorded scopes passed; these provider/project-default UI/paid-media/Windows/editor-session checks remain `not-run`/`partial`. Human specification review passed.

### Source trace

Composition: frontmatter. Workspace context: `prompts/system.md`, `lua/util/init.lua`, `lua/util/git_workspace_context.lua`. Defaults: `lua/maxa/session/default_adapter.lua`, `default_adapter_ui.lua`. GenAI: `lua/maxa/mcphub/native_servers/genai/`, `lua/maxa/adapters/proxy.lua`. Persistence: `lua/util/project_nvim_sessions.lua`, `lua/util/nvim_restart_resume.lua`.

Telegram: `lua/maxa/session/notify_when_done.lua`, `lua/maxa/session/telegram_bridge/`; Current notify-only session input supersedes historical binding-specific routing.
### Requirement: Project configuration reuses existing metadata

Store project runtime selections directly at the root of `<normalized-project-root>/.maxa/_meta.yaml`; do not create `config.json` or add a `maxa_ai` wrapper. Governance metadata and runtime fields share this project-owned file. Canonical settings:

```yaml
default_adapter: adapter-name
default_model: model-name
soul: "#agency-nexus[/agents/engineering/security-engineer.md]"
abilities:
  enabled_suites: [game-development]
  states:
    browser: true
    twitter: false
genai:
  default_adapters:
    image: image-adapter
```

This illustrates schema, not deployment choices. Model defaults are an optional complete nonblank string pair; `soul` is an optional nonblank string. `abilities.enabled_suites` is an ordered unique suite-identifier list; `abilities.states` maps Ability identifiers to booleans. Missing sections/list/map mean no explicit suite selections and current default Ability availability. [Ability owner](./package-and-authoring.md) governs actions/availability. `genai.default_adapters` optionally maps `image`, `tts`, `video` to declared-capable adapter names; absence means dynamic inheritance, not a copied global value. Preserve unrelated/unknown metadata; reject invalid owned shapes. Removed package identities do not authorize capabilities or trigger rewriting.

Read old `maxa_ai` blocks through a root-level projection without changing files. A root/legacy duplicate field is a visible migration conflict, not an override. An explicit setting write or explicit migration lifts the entire old block to root, removes the wrapper and preserves unknown fields, comments and literal-block content. Other projects are not automatically rewritten.

Opening/reading/discovery SHALL NOT create `.maxa/`, `_meta.yaml`, defaults or disk caches. Malformed/unreadable metadata reports error, never bypasses prohibition. Missing metadata permits inherited/default reads but no setting writes. Publish explicit edits by sibling temp + atomic rename; validate the complete post-edit model pair, not half-applied leaf edits; failure leaves the file unchanged.

### Requirement: Project metadata includes Ability visibility

Existing root `<project>/.maxa/_meta.yaml` `abilities` mapping additionally accepts `visibility`, an Ability-identifier mapping with exactly `global|search|hidden` values. Absent map/key inherits source defaults; invalid identifiers/types/enums fail without writes. `states` remains identifier/boolean availability and `enabled_suites` retains overlap selections. Editing/resetting visibility is project-local, preserves other metadata/comments and uses existing compare-and-rename publication; reading never creates files. [Ability owner](./package-and-authoring.md) governs projection and actions.

### Requirement: Project defaults are independently inheritable

The independent default-service view (`D`) in the full configuration panel and the separate `<leader>aa` selector SHALL share project-only controls for `llm/image/tts/video`; Ability view (`P`) contains no model/adapter controls. LLM selects adapter/model as the existing complete pair; media selects adapter only. All media validation uses existing declared capability metadata, not protocol/key/model inference. Each service independently supports the English `Inherit global` action; selecting it deletes only that service's project override. Absence and inheritance are equivalent and track later global changes. Explicit invalid/unavailable project selections report unavailable/error, never silently fall back.

Initial open SHALL display the effective value and English provenance labels `[Project override]` or `[Inherited global]`, plus the exact shown project identity. Project configuration may not switch into writing global state. LLM changes apply to new Chats only; constructor/restored/current Chat choices remain intact. Media defaults govern subsequent requests under [GenAI Native MCP](../abilities/base/genai/native-mcp.md); no global singleton mutation or paid requests are necessary to select defaults.
