---
title: SuperMax CodeCompanion 目标范围与删除项
created: 2026-08-02
updated: 2026-08-02
doc_role: target-scope
authority: draft
status: partial
baseline: ../../baseline.md
---

# Scope

This reverse-spec is being upgraded from an upstream CodeCompanion fact record into a SuperMax target contract. The target retains and strengthens Chat, Message, Provider, Tool, Action, Command, Session and Event concepts, but does not require CodeCompanion implementation compatibility.

## Supported protocols

Only these protocols are normative:

1. OpenAI Chat Completions.
2. OpenAI Responses.
3. Anthropic Messages.
4. Gemini native API.

Each provider is configured through a compact gateway/provider record equivalent to `make_llm_gateway_adapter` in `lua/plugins/ai.lua`. Provider-specific payloads remain inside protocol adapters.

## Interaction surfaces

- Chat window is the only conversational surface.
- Actions and Commands remain supported runtime capabilities. They may register, dispatch, transform context, manipulate session state, and inject messages through the Chat runtime.
- The standalone Neovim command-input Chat mode (`CodeCompanionCmd`-style command mode that opens/operates a separate command interaction) is out of scope and MUST NOT be a second conversational surface.
- Inline assistant/editor diff flow is out of scope.
- Workflow runtime and workflow prompt surface are out of scope.

## Removed behavior

The following are deliberately removed from the target scope and must not be reintroduced as hidden requirements:

- ACP protocol, ACP adapters and ACP process/session lifecycle.
- Standalone Neovim command-input Chat interaction mode; this does not remove the Command abstraction or Chat-owned commands.
- Inline assistant and editor diff/application flow.
- Workflow runtime and workflow prompt surface.
- User authorization, approval and permission gates for tool execution.
- Provider protocols outside the four listed above.

## Actions and Commands

The target MUST retain an Action/Command registry and dispatch contract. A Command is an executable named operation with declared input, context, output/effect and failure behavior. An Action is a user/runtime-discoverable operation that may invoke a Command or a Chat intent. Both are executed inside the runtime lifecycle and emit events; neither requires a separate conversational UI.

## Host and project-state boundary

The first implementation is developed and validated inside this LazyVim-based Neovim mother repository. This describes the development/host harness, not a runtime dependency on the repository's `.supermax/` directory. The delivered runtime's project-local contract is `<target-project>/.maxa/`; it MUST start and operate when the development mother repository's `.supermax/` is absent or inaccessible. It is a project implementation, not a general-purpose Neovim plugin contract.

## Evidence and migration

Deleted upstream-only module files are historical scope decisions, not claims that the upstream source never contained those features. Migration behavior is recorded by the replacement target modules in this directory.
