---
title: Markdown Prompt Format 行为规格
created: 2026-09-17
updated: 2026-10-09
type: source
doc_role: spec
authority: accepted
status: active
capability: markdown-prompt-format
sources:
  - lua/maxa/prompts/markdown.lua
  - lua/maxa/providers/completion/
  - lua/maxa/interactions/chat/
  - lua/maxa/prompts/sources.lua
  - prompts/commands/
confidence: high
review:
  human: passed
  evidence: user-declared-change-review-2026-10-07
validation:
  focused_automated: passed
  fresh_configured_runtime: passed
  live_provider: not-run
---

### Scope

Owns Chat Markdown metadata, role grammar, scalar placeholders and slash insertion. Initial system prompts, adapter wire mapping, AbilityHook Markdown and Lua callback/session command mutations have separate owners. Standalone Actions/Lua Prompt creation is removed.

### Requirements

- **Chat-only Markdown metadata**: Require prompt `name`; allow only optional `description`, `insert`, `context` and boolean `snip`. Defaults: `insert: inline`, `snip: false`. `snip: true` requires user-only; reject llm content. Before completion registration/token deletion, reject entire files with unknown/removed fields (including interaction/strategy/opts/alias/short_name), wrong types or invalid command names. Invalid user-only placement metadata must fail before token deletion. All sources use the same `name` validation; retain raw frontmatter `name`, `${item.name}` and bodies. Ability namespacing changes only the derived slash command identifier under [Chat command identity](../runtime/chat-commands.md#requirement-slash-command-identities-are-deterministic), not prompt metadata; ordinary slash names remain unchanged.
- **Prompt placeholders are scalar data only**: `${context.…}` / `${item.…}` may read existing string/number/boolean values by raw table traversal on invocation copies. Keep missing/non-scalar values literal with bounded warnings. Do not treat LuaSnip placeholders as context variables or interpret substituted data as snippet nodes. Never discover/load sibling Lua, call functions/metatables or evaluate expressions. Shared substitution code still used by tools is unaffected.

#### Requirement: Markdown roles are user and llm only

Accept only non-empty `## user`/`## llm` sections. Reject the entire Prompt for `## system` or unknown/missing/malformed roles with a bounded source/reason error; never partially register/insert. `llm` requires preceding user and `insert: inline`; reject other placements before completion/token deletion.

Preserve Chat/adapter system-role support; [OpenAI Responses adapter](../runtime/openai-responses-adapter.md) owns initial system-prefix behavior.

#### Requirement: User-only slash prompts expand at invocation

For plain/snippet expansion, delete only the accepted token, combine user bodies in source order, preserve surrounding text/whitespace and cached definitions, and never auto-send:

| `insert` | Body placement |
| --- | --- |
| `inline` | At the token |
| `split` | Break at the token; separate non-empty preceding/following text from the body by line breaks; add no empty boundary line on an empty side |
| `next_line` | Below invocation line; preceding/following text stays on that line |
| `append` | New line at editable draft end; reuse an empty final line |

Without snip, retain the plain-text path and place the cursor at body end; otherwise LuaSnip controls the first input position. Metadata owns placement validity; the next rule owns llm history.

#### Requirement: llm slash prompts become visible history

For role-valid `llm` commands, perform in order:

1. Add Markdown user/llm messages to the real Chat stack in source order, then render those same messages as visible committed role history.
2. Remove the slash token from the current draft; retain that draft as the final editable user section.
3. If empty, use the existing blank-user submit path so the next request is user-terminated.

Map `llm` through the selected adapter to its assistant role; never copy it into editable user text. Render failure must restore the prior message stack, draft and buffer, leaving no half-inserted role pair.

### Optional LuaSnip

- **Opt-in LuaSnip expansion**: `snip: true` uses user-only placement and passes the combined body to LuaSnip's full LSP/VS Code parser/native interaction. Preserve placeholder/mirror/nesting/choice/variable/transform (transforms require jsregexp); never execute Markdown Lua/SnipMate or reference Lua node definitions.
- **Chat snippet interaction**: Support LuaSnip forward/backward jumps, choice switching, exit and existing send keys in Chat Insert/Select modes without replacing other buffers' global snippet backend. Defaults: Tab/Shift-Tab jump, Ctrl-l switch choice, Ctrl-e exit (close visible completion menu first), Ctrl-s send. Restore temporary snippet mappings on exit. End Chat snippet state before submit, content rewrite or destruction; history retains only final text.
- **Snippet failure preserves input**: Missing LuaSnip, invalid expansion or no editable target must explicitly fail, preserving token/draft; never silently insert unexpanded syntax or leave partial insertion.

Invalid slash anchors use [Chat commands](../runtime/chat-commands.md) insertion fallback; the rules above own role rejection and snippet failure.

### Validation

Focused tests must cover user/llm parsing, system/unknown/missing rejection, active command prompts, user-only insertion, visible-history/message-stack synchronization, draft preservation and blank-user termination.

Recorded evidence:

- 2026-10-07: Ability namespace change preserved raw `${item.name}` in actual post-restart Chat/Blink expansion using a user-authorized temporary Ability prompt, subsequently removed; ordinary `/ask` remained functional and neither path auto-sent. Existing parser/slash assertions passed with an isolated headless Ability-discovery warning. Human review of this change is not-run.

- 2026-09-17: focused parser, insertion and visible-history tests passed.
- Workflow retirement reran Markdown parsing/generated-system-prompt validation after staged-grouping removal; fresh Neovim restart confirmed the reduced runtime. An earlier configured restart-resume smoke confirmed UTF-8 slash-prefix replacement, user/llm parsing and system rejection.
- Live external-provider validation: `not-run`; static adapter mappings confirm `llm` serialization as assistant/model history.

Dated checks below retain their original scope and historical human-review limits:

| Date / behavior | Passed checks |
| --- | --- |
| 2026-10-04 / Markdown prompt insertion | Focused parser/slash/setup; 28 name/body comparisons; fresh Neovim actual Blink acceptance of four modes, user/llm draft preservation and no Lua execution |
| 2026-10-05 / LuaSnip expansion | Existing parser/slash/insertion, Lua syntax and actual fresh Chat/Blink: four placements; fields/mirrors/transforms/choices/variables/nesting; literal context; failure rollback; Select send; exit/redraw cleanup |

### Source Trace

- Parser: `lua/maxa/prompts/markdown.lua`; slash execution: `lua/maxa/providers/completion/init.lua`; Chat history/UI: `lua/maxa/interactions/chat/init.lua`.
- Discovery: `lua/maxa/prompts/sources.lua`. [Runtime plugin entrypoints](../runtime/plugin-entrypoints.md) and [Ability packages](../runtime/package-and-authoring.md) own fixed roots/Ability publication. Runtime builtin prompts and Actions are removed without migration.
