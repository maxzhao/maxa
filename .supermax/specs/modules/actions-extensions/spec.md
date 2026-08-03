---
title: CodeCompanion actions、prompt library、extensions、parsers、UI customization 反推规格
created: 2026-08-01
updated: 2026-08-01
type: spec
doc_role: reverse-spec
authority: draft
status: partial
target_disposition: retained-and-redefined-by-actions-commands-target-chat-ui
baseline_commit: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
baseline_version: v18.7.0
scope: upstream-only
validation:
  identity: passed
  static_trace: partial
  automated: blocked
  human: not-run
tags: [specs/codecompanion-reverse-spec, actions, prompt-library, extensions, parsers, ui]
---

> **Target disposition:** Actions, Commands, palette/history entrypoints and extension registration are retained through `actions-commands-target` and `chat-ui`. Workflow execution and standalone command-input Chat are removed; occurrences below are baseline evidence only.

> **TLDR**：在 pinned `558518f8d78a44198cd428f6bf8bf48bfa38d76d` / `v18.7.0` 中，action palette 把静态 action、内置 Markdown prompts、Lua prompt library、用户 Markdown prompts 汇总到缓存，按 context 条件筛选后交给可配置 picker；选中项深拷贝、解析 placeholders，再启动 named interaction。Extensions 通过 runtimepath、字符串/函数/表 callback 或直接 register resolve，要求 table + `setup`，调用 setup 并暴露 exports。Rules parsers 是返回 `{content, meta?}` 的函数；UI customization 主要依赖 `User` autocmd 的请求事件。

## 1. Evidence and Boundary

- Primary checkout: `~/.local/share/nvim/lazy/codecompanion.nvim`。
- Identity evidence: `git show -s --format='%H%n%cI%n%s' 558518f8d...` → exact commit, `2026-02-18T08:00:51Z`, `chore(main): release 18.7.0 (#2744)`；`git show ...:version.txt` → `18.7.0`；`git status --short --branch` → `## HEAD (no branch)`。
- Source files inspected at baseline: `lua/codecompanion/actions/init.lua`, `actions/markdown.lua`, `actions/prompt_library.lua`, `actions/static.lua`, `actions/builtins/{commit,lsp}.lua`, `_extensions/init.lua`, `interactions/chat/rules/*`, `providers/actions/*`.
- Tests/docs inspected: `tests/actions/test_markdown.lua`, `tests/actions/test_prompt_library.lua`, `tests/test_extensions.lua`, `doc/usage/action-palette.md`, `doc/usage/prompt-library.md`, `doc/extending/extensions.md`, `doc/extending/parsers.md`, `doc/extending/ui.md`, `Makefile`, `scripts/minimal_init.lua`。
- Explicit exclusion: SuperMax `lua/plugins/ai.lua`, hooks, local extensions, latest-upstream commit and any target-runtime design.

## 2. State Model and Operation Inventory

| Operation | State / output | Failure or isolation |
| --- | --- | --- |
| discover actions | module-local `_cached_actions` initially empty; aggregate source definitions | missing prompt dirs produce empty list; individual Markdown parse is `pcall`-isolated |
| validate visibility | returned filtered list; mode lowercased | condition truthy includes item; otherwise `opts.modes` must contain mode; no condition/modes includes |
| launch palette | picker provider receives items + `validate`/`resolve` callbacks | zero items logs warning and returns; invalid provider require errors (not locally isolated) |
| resolve selected | deep-copied item, placeholders replaced, interaction started | unresolved placeholders remain and warn; helper function failure logs error per placeholder |
| refresh | cache reset and repopulated | no persistence beyond module lifetime |
| parse Markdown | prompt record with frontmatter and role prompts | absent/invalid frontmatter, name, interaction/legacy strategy or empty prompts rejected/warned |
| load extension | extension setup side effects; optional `_exports[name]` | invalid type/setup is an error; disabled config prevents load upstream setup path |
| parser | processed file `{content, meta?}` | rules caller owns execution/error behavior; exact failure isolation needs deeper rules trace |

## 3. Requirements and Scenarios

### R-ACT-001 Aggregate and cache action sources

**GIVEN** action cache is empty and `context` exists **WHEN** `Actions.set_items(context)` runs **THEN** it conditionally appends static actions, built-in Markdown prompts, Lua prompt-library entries, and configured Markdown directories in that order; each prompt receives `opts.type="prompt"`, Markdown prompts additionally `opts.is_markdown=true`; subsequent calls reuse the module cache.

**Config:** `display.action_palette.opts.show_preset_actions`, `show_preset_prompts`, `show_prompt_library_builtins`, `prompt_library`, `prompt_library.markdown.dirs` (directory may be a function of context).

**Trace:** `lua/codecompanion/actions/init.lua:39-101`; `actions/static.lua`; `actions/markdown.lua:189-227`; `actions/prompt_library.lua:537-586`.

### R-ACT-002 Validate item visibility

**GIVEN** an item list and buffer context **WHEN** `Actions.validate` runs **THEN** function `condition(context)` is authoritative when present; otherwise `opts.modes` is checked against lowercase `context.mode`; otherwise item remains visible.

**Trace:** `actions/init.lua:11-34`. **Gap:** condition return type/error handling is not source-confirmed beyond ordinary Lua propagation.

### R-ACT-003 Launch through configured picker

**GIVEN** validated items **WHEN** `Actions.launch(context,args?)` runs **THEN** empty items produce warning `No prompts available...` and return; otherwise provider defaults to `config.display.action_palette.provider`, with optional `args.provider.name/opts`, and provider receives context, validate, resolve before `picker(items, provider_opts)`.

**Trace:** `actions/init.lua:142-164`; `doc/usage/action-palette.md` (command `:CodeCompanionActions`, refresh argument). **Gap:** provider implementations and command dispatch were not fully read.

### R-ACT-004 Resolve selected item into interaction

**GIVEN** a selected item **WHEN** `Actions.resolve` runs **THEN** it deep-copies the item, resolves Markdown placeholders, constructs `interactions.new({buffer_context=context, selected=item})`, and starts `item.interaction`.

**Trace:** `actions/init.lua:126-140`.

### R-ACT-005 Resolve aliases and refresh cache

**GIVEN** cached items **WHEN** `resolve_from_alias(alias,context)` runs **THEN** it returns the first item whose `item.opts.alias == alias`, or nil; `refresh_cache` clears and rebuilds cache. **Trace:** `actions/init.lua:104-124,166-172`.

### R-PL-001 Parse Markdown prompt files

**GIVEN** a readable non-empty `.md` file **WHEN** `parse_file` runs **THEN** YAML frontmatter supplies `name`, `interaction` (or legacy `strategy` translated to interaction), description/context/opts; Markdown role sections create prompts only for configured system/user roles. Missing required fields warns and returns nil.

**Trace:** `actions/markdown.lua:230-259,261-323,345-452`; tests `tests/actions/test_markdown.lua` frontmatter, CRLF and role cases. Workflow-specific baseline behavior is removed from the SuperMax target.

### R-PL-002 Parse frontmatter without workflow execution

**GIVEN** `---` YAML frontmatter **WHEN** Tree-sitter YAML parsing succeeds **THEN** scalar/nested/sequence values are decoded; YAML errors warn and reject; `yaml opts` fenced blocks attach per-prompt options. `opts.is_workflow` and sequential prompt-group semantics are upstream-only behavior and MUST be rejected or ignored by the SuperMax target; a prompt resolves to one Action/Command/Chat interaction.

**Trace:** `actions/markdown.lua:265-323,326-343,386-452`; workflow parsing is retained only as baseline evidence, not target behavior.

### R-PL-003 Expand placeholders with context and sibling Lua

**GIVEN** prompt content contains `${...}` **WHEN** selected item resolves **THEN** nested values are read from `{context,item}`; dotted roots attempt `<prompt-dir>/<root>.lua`, cached per resolution, and table values stringify while functions receive `{context,item,...loaded}` via `pcall`. Successful replacements mutate prompt contents; unresolved values warn and remain unchanged.

**Trace:** `actions/markdown.lua:454-528`; tests `resolve_placeholders` cases lines 1236-1361.

### R-PL-004 Isolate directory loading failures

**GIVEN** configured directory is absent/unreadable or a file is malformed **WHEN** `load_from_dir` scans **THEN** it returns available prompts/empty list; each file parse is `pcall`-isolated and valid files still load. Only regular files/symlinks ending `.md` are considered.

**Trace:** `actions/markdown.lua:193-227`; malformed frontmatter behavior in `parse_file`.

### R-PL-005 Resolve Lua prompt library configuration

**GIVEN** `config.prompt_library` **WHEN** `prompt_library.resolve(context,config)` runs **THEN** entries with dynamic name/description functions are evaluated, interaction accepts `interaction` or legacy `strategy`, and metadata/context/picker/prompts/condition are copied; when every entry has `opts.index`, entries sort ascending; builtins can be disabled by `show_prompt_library_builtins=false`.

**Trace:** `actions/prompt_library.lua:537-586`; tests `tests/actions/test_prompt_library.lua` for alias, adapter/model, context, rules and ignore-system-prompt observable effects.

### R-EXT-001 Resolve and validate extensions

**GIVEN** extension name and optional callback **WHEN** `Extensions.resolve` runs **THEN** callback string uses `require`, function is invoked, table is used; without callback it requires `codecompanion._extensions.<name>`. Result must be table with function `setup`, else raises an error.

**Trace:** `_extensions/init.lua:732-764`; `doc/extending/extensions.md:1814-1962`.

### R-EXT-002 Load/register extension and exports

**GIVEN** valid extension schema **WHEN** `load_extension` or `register_extension` runs **THEN** `setup(schema.opts or {})` executes; `exports` is stored under `codecompanion.extensions.<name>` via manager; missing names return nil through manager. `register_extension` delegates to load with callback.

**Trace:** `_extensions/init.lua:767-792`; tests `tests/test_extensions.lua:1600-1742`.

### R-PARSER-001 Rules parser output contract

**GIVEN** a rules processed file **WHEN** a configured parser is executed **THEN** parser is a function receiving file and returns a table containing `content`; optional `meta.included_files` requests additional files to be shared with the LLM.

**Trace:** `doc/extending/parsers.md:2001-2043`; `lua/codecompanion/interactions/chat/rules` parser call chain requires deeper inspection. Status partial.

### R-UI-001 Customize UI from request events

**GIVEN** external UI integration registers `User` autocmds **WHEN** `CodeCompanionRequestStarted` / `CodeCompanionRequestFinished` fire **THEN** integration may toggle processing/spinner/status widgets and redraw status; examples also react to `CodeCompanionContextChanged`, `CodeCompanionChatOpened` and finished events for context/token/cycle displays.

**Trace:** `doc/extending/ui.md:2078-2250`. This is documented integration behavior, not a built-in UI implementation; event payload/timing chain remains gap.

## 4. Built-ins and Configuration

- Static actions evidenced: `Chat`, `Open chats ...`, `Chat with rules ...` in `actions/static.lua`; their conditions/pickers invoke chat/rules APIs.
- Built-in prompt docs list `Commit message`, `Explain code`, `Explain LSP diagnostics`, `Fix code`, `Unit tests`, plus upstream workflow examples. The target retains the single-interaction built-ins and removes workflow examples. Built-in helper files inspected include `actions/builtins/commit.lua` (`git diff --no-ext-diff --staged`) and `lsp.lua` (diagnostic formatting).
- Configuration gates include preset actions/prompts, prompt-library builtins, provider name/options, prompt aliases, modes, conditions, auto-submit, adapter/model, context, rules and system-prompt options. Exact normalized schema/defaults require config chain follow-up.

## 5. External Dependencies and Failure Isolation

- Neovim APIs: `vim.fs`, `vim.uv.fs_scandir`, Tree-sitter YAML/Markdown parsers and queries, `vim.deepcopy`, `vim.system`, `vim.api`.
- CodeCompanion boundaries: `config`, `utils.files`, `utils.yaml`, `utils.log`, `interactions`, action providers, chat/rules and public API.
- Per-file Markdown parse is isolated by `pcall`; placeholder helper load/function execution is isolated and logs; invalid extension contracts raise errors (not silently isolated); missing dirs yield empty results. Provider require and parser caller error semantics remain gaps.

## 6. Validation Evidence

### Passed

- Identity/static checkout checks passed: exact baseline HEAD/commit metadata/version; detached checkout is clean; lock entry was previously recorded in `baseline.md` and current checkout identity re-confirmed.
- Static source/doc/test trace completed for listed paths; references use baseline paths and line ranges from inspected snapshot.

### Blocked

Command attempted:
`make test_file FILE=tests/actions/test_markdown.lua && make test_file FILE=tests/actions/test_prompt_library.lua && make test_file FILE=tests/test_extensions.lua`

Exact blocker: `scripts/minimal_init.lua:7: module 'mini.test' not found`; follow-on `MiniTest` nil; command timed out after 180s and was terminated (`Exit Code: 143`). Therefore automated validation is `blocked`, not passed.

## 7. Coverage Audit and Gaps

- **Source coverage:** action core, Markdown parser/expansion, Lua library, extension manager, docs and named tests inspected; rules parser runtime and action provider/command routing only partial.
- **Behavior coverage:** normal discovery/selection/expansion/registration covered; failure/edge coverage partial; external dependency and UI event timing partial; concurrency/idempotency not established (cache behavior observed, invalidation semantics only direct refresh).
- Missing deep traces: `plugin/codecompanion.lua` or command implementation for `:CodeCompanionActions` and refresh; all `providers/actions/*` picker behavior; complete `rules` parser invocation and included-files handling; config normalization/defaults; all built-in prompt files and their interaction effects; full UI event emission source; successful test run with dependency setup.
- No latest-upstream or SuperMax downstream material was used as authority.

## 8. Review Status

`partial / draft`: artifact records evidence and explicit gaps; it must not be promoted or treated as target design until missing chains and validation are completed.
