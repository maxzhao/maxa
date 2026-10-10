---
title: Maxa AI 内建运行时规格
created: 2026-09-13
updated: 2026-10-09
type: source
doc_role: spec
authority: accepted
status: active
capability: maxa-ai-runtime
sources:
  - lua/plugins/ai.lua
  - lua/maxa/
  - lua/maxa/mcphub/native_servers/session/
confidence: high
review:
  human: passed
  evidence: user-declared-change-review-2026-10-07
---

### Scope

Owns repository HTTP Chat, Markdown slash, adapters/providers, tools, session, lifecycle and MCPHub integration. Responses wire, builtin inventory and hidden image-analysis children have peer owners. Runtime root: `lua/maxa/`; Session Ability: `session`, executable targets `@session:<tool>`.

### Requirements

#### Requirement: Maxa owns the retained AI runtime

`require("maxa").setup(opts)` SHALL atomically initialize HTTP Chat, adapters/providers, fixed project-rule context/Markdown slash discovery, first-party tools, completion, context/image, session and UI from `lua/maxa/**` under Runtime setup below; external `codecompanion.*` runtime SHALL NOT load. Title-generation failure SHALL format structured/string/nil errors without table concatenation and call its failure callback exactly once.

#### Requirement: Runtime version has one mother-project source

`require("maxa").version()` MUST read the first line of the mother runtime's root `.version`, trim surrounding whitespace and return the nonnegative-integer version as a string, including before `setup()`. Resolve the runtime root from the installed version-reader module's source path, never the selected project or cwd. API and project-schema comparison MUST share this reader. Missing/unreadable input returns `nil, "missing"`; empty, nonnumeric, nonfinite, negative or fractional input returns `nil, "invalid"`. An unavailable module source returns `nil, "runtime-root-unavailable"`. No inherited `18.7.0`, old-filename, child `.version` or project-metadata fallback. This version remains the runtime/project-schema compatibility generation, not upstream software SemVer.

#### Requirement: Runtime is HTTP-only

HTTP bases SHALL be `anthropic`, `openai`, `gemini`, `openai_compatible`, `openai_responses`, selectable only through named provider `llm` declarations, never independent built-in presets. Anthropic Messages gateways SHALL compose via `anthropic`. ACP adapters/transport and presets `copilot`, `ollama`, `azure_openai`, built-in `deepseek`, `githubmodels`, `huggingface`, `jina`, `mistral`, `novita`, `tavily`, `xai` SHALL remain absent, without aliases or fallback to retained identities. A configured DeepSeek gateway MAY explicitly decorate `openai_responses` in code without restoring a deleted preset. Official Responses/provider differences: [OpenAI Responses adapter](./openai-responses-adapter.md).

#### Requirement: Exactly two core commands exist

Runtime SHALL expose only `:Maxa` (Chat) and `:MaxaHistory` as core commands; `:MaxaActions`, `:MaxaChat`, `:MaxaCmd` SHALL remain absent without aliases. Mappings SHALL include normal `<leader>ac` → `:Maxa`, visual `<leader>ac` → `:Maxa Add`, normal/visual `<leader>aC` → `:Maxa` command-line entry; MUST NOT restore `<leader>av` AI interaction. `<leader>aA` and `<leader>aa` select global and project service defaults respectively under [Plugin entrypoints](./plugin-entrypoints.md#requirement-default-picker-is-scope-aware), not core command-line entry.

- **Actions and alternate prompt creation are absent**: MUST NOT provide `<leader>aw`, `MaxaAI.actions()`, `MaxaAI.prompt()`, Actions static/picker/creation flow, `display.action_palette` or removed-name compatibility aliases. Core Chat/sidebar, history, Lua callbacks and fixed Markdown discovery remain.

#### Requirement: Independent Inline, Cmd, and edit-review subsystems are absent

Runtime SHALL NOT expose independent Inline interaction/API/command/completion/adapter handlers or Cmd interaction/prompt/API/mapping. Chat tools SHALL NOT install approval caches, `require_approval_before` gates, YOLO approval modes, edit tracking, accept/reject/revert UI, Super Diff or Diff providers/keymaps/config. Removed owners SHALL remain absent: `maxa.interactions.chat.edit_tracker`, `super_diff`, `helpers.diff*`, `helpers.wait`, `tools.approvals`, `maxa.providers.diff.*`. File tools apply validated effects directly, returning ordinary bounded results.

#### Requirement: Canonical identities use Maxa names

| Surface | Canonical identity |
| --- | --- |
| Chat events/highlights/types | `MaxaAI*` |
| Chat filetype/completion/context | `maxa_ai` |
| Lua modules / AI globals | `maxa` and `maxa.*` / `vim.g.maxa_ai_*` |
| Builtin MCPHub | Configuration command `:MaxaConfig`; retain `MCPHub*` events, non-approval `vim.g.mcphub*` and retained capability server/tool names; Lua namespace `maxa.mcphub.*`. The built-in management Ability `mcphub` and retired `:MCPHub` command alias remain absent. |
| Vendor-specific Tree-sitter queries | `maxa_ai_symbols`, `maxa_ai_context` |

Coc provider, discovery, Vimscript bridge and `_G.MaxaAIBridge.coc` SHALL remain absent. Retained commands and internal named fields use `:Maxa*`/`maxa*`, without adding removed Actions/Inline/Cmd interactions. The retained command set, HTTP-only behavior, atomic setup/rollback, completion permissions and explicit Ability authorization are unchanged.

All retained runtime source/spec references use root `lua/maxa/`, setup `require("maxa").setup(opts)`, guard `vim.g.loaded_maxa_ai` and project rule `.maxa/AGENTS.md`. Preserve internal directories and associated non-Lua resources, including runtime `queries/`; approved `autoload/`, generated `test/` and inherited `doc/` are removed, not actual `tests/`. No `maxa.ai`/`maxa.ai.*` module compatibility aliases or implementation tree remain; downstream callers must migrate. Normalize directly affected active module/source references without changing non-naming conditions or historical evidence. Non-module log/autocmd identities remain unchanged.

#### Requirement: Runtime setup owns bootstrap atomically

`maxa.setup(opts)` SHALL register guard `vim.g.loaded_maxa_ai`, highlights, filetype/syntax, context tracking, commands and autocmds, then initialize builtin `maxa.mcphub` directly after final config composition, without prior plugin/extension Hub startup. Missing dependencies fail explicitly, never falling back to the old runtime. Synchronous failure SHALL clean this setup's owned AI/Hub effects and permit retry; repeated setup MUST NOT duplicate commands/autocmds/Hub instances.

Hub owns async `in_progress`/`completed`/`failed` readiness/failure and retryable cleanup: synchronous AI setup success is not Hub readiness, and Hub failure MUST NOT appear successful. Former patches SHALL live in direct adapter/Chat/tool/response/lifecycle/session owners, not post-setup monkey patches.

#### Requirement: First-party Agent primitives are Chat-owned

Normal Chat SHALL default to exactly 17 first-party bare builtins executing through its tool lifecycle. Retired first-party MCP server/group/prefix and separate Skill/MCP loaders SHALL NOT be exposed. [Chat builtins](./chat-builtins.md) solely owns identities, schemas, deterministic serialization and behavior; no duplicate inventory here.

#### Requirement: Existing Chat messages survive adapter and model switches

Adapter/model changes SHALL preserve the `chat.messages` table, contents and order without removal/recomposition/insertion; request settings/UI/non-message state may update as needed. Wire mapping is not stored history. Unknown/removed adapters remain unavailable without identity translation. Restored Chats retain their HTTP adapter; current defaults apply only to new Chats.

#### Requirement: Main Chat keeps one replaceable Soul message

New default Chats SHALL store host Runtime and exactly one effective Soul as distinct, tagged, contiguous initial `system` messages before lower-priority project context. `/souls` SHALL replace only the tagged Soul in place, preserving Runtime, project context, dialogue and initial system ordering.

#### Requirement: Fixed project rule source

New default Chats SHALL read only `<project_root>/.maxa/AGENTS.md` as project-rule context, at most once in active messages. Missing optional files add no rule/alternate source; present unreadable files fail visibly. Text, including literal `## System Prompt`, SHALL remain ordinary non-system context. Saved legacy Rules messages MAY remain history but SHALL NOT enable a new loader.

#### Requirement: Tool and Rules context never elevate to system messages

Individual tool registration SHALL preserve schema/callback without a system message, even with legacy `system_prompt`. Tool summaries/main-prompt replacement/groups are retired: group names SHALL NOT register/expand tools; individual names remain available. Persisted messages SHALL NOT be rewritten. Fixed project rule source above is the sole Rules loader; arbitrary Rules groups/files/parsers SHALL NOT add Chat context/system messages. MCPHub server/tool grouping is unaffected.

#### Requirement: Maxa consumes MCPHub without a registration bridge

Atomic setup's direct MCPHub initialization SHALL NOT load `maxa.integrations.mcphub`, consume `extensions.mcphub`, maintain registration-bridge retry/status or dynamically attach MCP tools/resources/prompts. Internal MCPHub owns Hub protocol/Server lifecycle. Chat integration is limited to exact-cwd side-effect-free Ability discovery, provenance-bound `load` authorization/cataloging and authorized project-keyed `@ability:tool` / `#ability:resource` dispatch. Hub ready, completion, history restore and dispatch SHALL NOT implicitly load/authorize. Unavailable MCPHub, workspace-provenance mismatch or unauthorized targets return bounded errors, never bridge fallback/process-global authorization.

#### Requirement: `@` and `#` are side-effect-free literal completion prefixes

For exact `maxa_ai` Chats, completion SHALL expose:

| Eligible source | `@` | `#` |
| --- | --- | --- |
| Ordinary discovery | Canonical bare builtins; available Ability identifiers for explicit `load` | Publicly disclosed Markdown references of visible Abilities before load |
| Provenance-valid ready committed revision | Cataloged `@ability:/script`, `@ability:tool` | Cataloged `#ability[/file]`, `#ability[resource]` |
| Allowed visible MCP-backed Ability, effective exact-cwd Native source, before load | Already-registered `@ability:tool` | Original concrete `#ability[resource]` identifiers |

Native pre-load candidates are independent of connection/Chat authorization and use only registered names/static string descriptions, never metadata callbacks. Missing registered definitions/effective catalog yields none. Omit hidden/disabled sources and effectively disabled Native tools/resources. Other unloaded/stale/unauthorized entries retain existing revision/disclosure rules. Pre-load MUST NOT expose package scripts/non-Markdown files, External capabilities, resource templates or prompts.

Default omnifunc/cmp/blink/native completion share one exact-Chat catalog/token parser with deterministic inserted-literal deduplication, preserved hyphens/slash paths/resource suffix punctuation and committed descriptions preferred over pre-load Native ones. Coc is not supported. Blink SHALL replace adjacent auto-paired `]` on active `#ability[` rather than duplicate it.

Discovery SHALL be read-only: no load, transport start, Hub switch, config/cache creation, context injection, hook registration or authorization. Selection/submission inserts literal bytes only. Neither pre-load candidates nor other Chats/process-global connections grant execution: calls/reads still require explicit load, ready-state/catalog-result/workspace-provenance/membership checks and connected-only transport.

#### Requirement: Mention submission preserves ordinary user text

Submission/history restore SHALL NOT parse, replace, remove, expand or execute literal `@name`, `@ability:target`, `#ability:target`. Mentions never load/call/read, inject context, fire hooks or authorize/start sources. Later actions follow natural-language routing, Ability Gate and explicit `load`/`call`/`multicall`/`read`.

#### Requirement: Removed adapter-owned extras remain absent

Jina `/fetch`/`fetch_webpage`, Tavily-backed `web_search`, Copilot statistics/model-toggle/proxy globals/recovery policies SHALL remain absent. Anthropic/OpenAI Responses native web-search parameters are unaffected. `.github/copilot-instructions.md` is not a project-rule source and does not restore Copilot.

### Message inspection

**Shared inspector invariant**: MUST be read-only, omit the outer message envelope, preserve canonical content and execute nothing. `q`/`Esc` MUST close visible/hidden areas and all format buffers, restoring caller Chat without message changes; hiding a pane MUST NOT destroy the inspector. `gd` keeps its raw editor. Local controls MUST survive format-buffer changes/pane reopening; never override single `m/t/j` or `hjkl`, nor install Tab pane switching.

- **Cursor-local message inspection**: Normal Chat-local `gi` MUST open a popup from cursor-message provenance, not rendered-text parsing. Ordinary messages show output only; tools show invocation input/result matched by `call_id`, batch members their own pair and batch titles the parent invocation. Missing provenance MUST notify without an all-chat view; absent results remain explicitly unavailable.
- **Generic inspection formats**: Input MUST show nested fields/multiline strings. Complete JSON object/array strings MAY decode for display; failed decoding preserves raw text. Output MUST start in Markdown; `<localleader>m`/`<localleader>t`/`<localleader>j` select Markdown/plain text/JSON without tool-specific payload extraction. JSON mode MUST pretty-print valid JSON or encode other content as a JSON string. Footer MUST show effective LocalLeader, not assume Space.
- **Inspector directional pane navigation**: Local `<C-h>`/`<C-l>` MUST focus input/output, never global split/tmux navigation. Missing/already-focused target keeps focus; switching while zoomed retains zoom and restores target state.
- **Inspector input value folds**: Every input field value, including strings/objects/arrays, MUST fold losslessly. Initially close only values longer than 500 Unicode characters; shorter/equal stay open. Measure decoded strings and JSON-serialized objects/arrays; fold summaries show field name/type/count. Input-local `za` MUST toggle current, `zA` expand all if any closed (otherwise close all), `zM`/`zR` close/open all.
- **Inspector horizontal pane controls**: Tool panes MUST start input-left/output-right at equal widths. `<C-w><`/`<C-w>>` shrink/grow focus, adjusting its peer within usable minimum widths. `+` MUST toggle focused pane to inspector bounds, not screen, then restore prior width ratio. Layout changes MUST preserve folds, cursor/view and output format.

#### Requirement: Current-project maxa naming migration

- **Formal maxa name and scoped zero residue**: Formal project name MUST be `maxa` (max agent); display branding and technical PascalCase prefixes use `Maxa`. The agreed current working tree, including relevant hidden/ignored/generated content and paths, MUST have no occurrence of the retired brand in any letter case. Its original spelling and transformation record remain only in the approved project-external migration archive. Exclude `.git` history/objects and OCR/media redraw. Credential checks require authorized name-only handling; opaque formats are rebuilt or recoverably archived rather than byte-replaced, and unverified coverage remains explicit.

- **Deterministic naming migration**: First-party text and path identities MUST use `maxa` for lowercase technical names, `Maxa` for PascalCase/display names and `MAXA` for uppercase environment prefixes. Preserve suffixes/structure, upstream dependency identities and unrelated behavior. Do not add competing `maxA` technical names, permanent retired-name aliases or encoded hidden retired branding. Historical first-party Markdown references may normalize branding while retaining structured IDs, lifecycle and original evidence verdicts.

- **Current-project-only hard cut**: The migration MUST preserve user-owned edits and operate only on this working tree plus the host registrations/services/launchers directly needed by it. Other projects, Vaults and device registrations MUST remain untouched. Original history/scratch archival and the fresh-session cutover follow [Session history](./session-history.md); Git history is not rewritten.

### Validation

#### Evidence

The following dated checks retain their original scope and historical human extension/implementation review `not-run`. Native pre-load completion also retained the prior stable-spec human pass.

| Behavior group | Passed evidence and coverage |
| --- | --- |
| Retained plugin surfaces | Coc and management service removed; retained completion/core/Native/setup checks and fresh actual panel/navigation/Help/refresh observation plus `misc:echo` passed. Human implementation review not-run; nonfatal slash-check discovery warning remains recorded. |
| Mother runtime version | 16 focused version/schema/setup checks and fresh-Neovim API/source/schema observation passed. Supplementary legacy smoke is blocked by its unrelated unsupported adapter fixture; no full-smoke or human-review pass is claimed. |
| Native MCP completion | Existing focused check, syntax/diff; fresh-Neovim actual @/# menu/selection, disable-policy filtering and explicit-load deduplication. |
| Content completion | Existing focused completion/syntax/diff; fresh-Neovim actual unloaded Markdown # selection. `/load` Native browsing/confirmation shares the resource candidates. |
| Message inspector | Bounded syntax/format; fresh-Neovim actual ordinary/tool/member/parent inspection, nested input, Markdown/text/JSON switching, paired close/focus and buffer cleanup. |
| Inspector fold/layout | Scoped syntax/format; fresh-runtime actual long-value/current/all folding, left/right resize, either-pane zoom/ratio/format/view restoration, hidden-buffer cleanup and ordinary output-only path. |
| Inspector navigation | Focused syntax/format; fresh actual hjkl movement, LocalLeader formats, Ctrl+h/l directional/boundary/zoom switching and closing. |

Other recorded evidence retains its original scope:

- Repository-owned runtime convergence: active Lua parse/setup/adapter/default-adapter/Chat/completion/lifecycle/session checks passed. Historical runtime smoke observed exactly three core commands, canonical `:Maxa` Chat, retained HTTP adapters, session tools and removed-command absence.
- Final first-party inventory validation established exactly 17 tools; older 19/20/21-tool evidence is superseded history, not current acceptance.
- 2026-09-16: programmatic approval, edit tracking, accept/reject/revert UI, Diff providers/config/keymaps and `mini.diff` dependency removed; focused Chat/MCPHub tests, Lua/JSON/static checks, two fresh-process restart-resume validations and live `misc__echo` passed.
- 2026-09-20: dynamic MCP bridge and submit-time marker semantics removed. Project-keyed transport, provenance authorization/restore, literal provider parity, Skill/resource filtering and data minimization passed focused automation, independent repair review, two fresh restart-resume cycles, live authorized/unauthorized/restored calls and completion-catalog smoke; human acceptance passed.
- 2026-09-20: explicit Server activation hid administrator-disabled MCP candidates while retaining ordinary typed text; focused completion/session/load/call suites, fresh-runtime live checks and human acceptance passed.
- 2026-09-22: unified Ability inventory, literal `@`/`#` completion, zero-side-effect discovery, protected catalog association and fresh-runtime Ability loads/calls passed; human acceptance passed.
- 2026-09-24: passed observations cover direct Maxa AI setup/error-retry checks, fresh-Neovim Hub `completed`/ready and explicit `mcphub` and `misc:echo` Ability calls. Human runtime review of this change was not run.
- Historical user specification review passed for earlier scopes.

#### Permanent validation limits

Live provider calls, paid media calls and GUI interaction remain `not-run` for this contract. Recorded full Neovim restart-resume and focused runtime evidence remains `passed` only for its stated scope; no unrun/failed platform validation is upgraded.

### Source trace

- Composition: `lua/plugins/ai.lua`; runtime: `lua/maxa/`; Session Native adapter: `lua/maxa/mcphub/native_servers/session/`.
- Parent: [Runtime overview](./overview.md). Peers: [Plugin entrypoints](./plugin-entrypoints.md), [Lifecycle and message injection](./lifecycle-and-message-injection.md), [Session history](./session-history.md).
