---
title: CodeCompanion.nvim 反推证据地图
created: 2026-08-01
updated: 2026-08-01
type: source-summary
doc_role: evidence-map
authority: draft
status: experimental
tags: [codecompanion, reverse-engineering, evidence-map]
sources:
  - https://github.com/olimorris/codecompanion.nvim/tree/558518f8d78a44198cd428f6bf8bf48bfa38d76d
  - lua/plugins/ai.lua
confidence: medium
---

> **TLDR**: 这是模块取证入口而非规格正文；每个模块必须继续检查完整行为链并生成独立反推规格。

## Upstream Surface Inventory

- Baseline source inventory contains these top-level concentrations: `interactions` (98 files), `adapters` (34), `providers` (29), `utils` (19), `actions` (13), root modules (8), `helpers` (1), and `_extensions` (1). Baseline tests concentrate in `interactions` (90 files, including 81 chat), `adapters` (87), root tests (10), `utils` (7), `actions` (3), and `providers` (3). ACP and inline are removed from the target inventory; counts establish investigation scale only.

## Candidate Behavior Modules

| Module | Observable surfaces to extract | Primary baseline evidence entrypoints | Required chain before completion |
| --- | --- | --- | --- |
| Bootstrap and configuration | setup, defaults, strategy selection, Action/Command registration, health checks | `lua/codecompanion/init.lua`, `config.lua`, `commands.lua`, `health.lua`, `plugin/`, configuration docs, root tests | setup input → normalization/defaults → registered Actions/Commands/autocmds → visible state/errors |
| Chat lifecycle and UI | create/open/submit/stop/close chat, rendering, navigation, user-visible state | `lua/codecompanion/interactions/chat/`, `doc/usage/chat-buffer/`, `tests/interactions/chat/` | Chat/API entry → chat state → request lifecycle → buffer/UI output → events/errors |
| Message/context model | roles, messages, context insertion, variables, slash commands, rules | chat context/message modules, `doc/usage/chat-buffer/{variables,slash-commands,rules}.md`, corresponding tests | input syntax → parsing/resolution → message mutation → provider payload → displayed/persisted effects |
| Tools and agent loop | tool registration, selection, automatic execution, result insertion, continuation/stop | chat tool modules, `doc/extending/tools.md`, `doc/usage/chat-buffer/tools.md`, tests | tool declaration → model request → call parse → automatic execution → result message → loop termination |
| HTTP adapters/providers | adapter resolution, request formation, streaming parsing, tokens/errors | `lua/codecompanion/adapters/http/`, `providers/`, `http.lua`, adapter/provider tests | config → request schema → transport → stream parse → normalized messages/usage/errors |
| Provider contract | four supported protocol adapters, request/stream/usage normalization | `lua/plugins/ai.lua`, retained `http-transport` evidence, provider fixtures | compact provider config → protocol adapter → normalized stream/message/usage/error |
| Chat-only view and input | Chat buffer/view, input capture, rendering, navigation and lifecycle | retained chat evidence, `lua/util/hooks/chat_ui*.lua` | Chat input → runtime intent → state/event/view output |
| Background interactions | non-chat requests and callbacks such as title generation | `lua/codecompanion/interactions/background/`, tests/background | caller → background request → callback/state effect → error/cancellation behavior |
| Actions, Commands and prompt library | action discovery, command registration, prompt selection, execution, built-ins | `lua/codecompanion/actions/`, `doc/usage/{action-palette,prompt-library}.md`, tests/actions | registration → selection → context/template expansion → dispatch → visible/state result |
| Extensions and parsers | extension registration and parser/customization contracts | `_extensions`, `doc/extending/{extensions,parsers,ui}.md`, tests where present | registration → validation → runtime invocation → failure/isolation behavior |
| Events and public integration | emitted events, callback timing, public Lua/command interfaces | `doc/usage/events.md`, entry modules, tests asserting autocmds/events | triggering transition → payload/timing → listener effects → failure isolation |

## SuperMax Downstream Adaptation Evidence

Treat the following as a separate evidence family, not upstream specification:

- Runtime entry/configuration: `lua/plugins/ai.lua`.
- Compatibility and behavior patches: `lua/util/hooks/`.
- Session/status/Telegram utilities: `lua/util/codecompanion/`.
- Local history extension: `lua/codecompanion/_extensions/history/` and `display_chat_history/`.
- Agent/tool/session capabilities coupled to chat state: `lua/util/mcphub/{cc_history,mcpx,subagent,json_artifact,genai}/`.
- Existing checks: adjacent `*_test.lua`, `*_spec.lua`, and `tests/mcphub/codecompanion/`.

For each upstream module, later record: upstream behavior, SuperMax override/extension, reason inferred from code/tests, coupling risk, and independent-runtime decision status.

## Evidence Capture Contract

Each completed module spec MUST list:

- inspected command/API/UI entrypoints;
- handler and state-transition logic;
- request/provider or persistence boundaries where applicable;
- data/message/config constraints;
- tests and user-visible documentation;
- normal, failure, edge, external-dependency, configuration, concurrency/idempotency, and validation coverage;
- baseline-only evidence and latest-upstream differences in separate sections.

## Current Status

- Evidence inventory: initial/partial.
- Deep behavior modules completed: 0.
- Requirements extracted: 0.
- This file MUST NOT be cited as proof that any module behavior is fully specified.
