---
title: CodeCompanion.nvim v18.7.0 tools and agent loop reverse-spec index
created: 2026-08-01
updated: 2026-08-01
type: index
doc_role: reverse-spec-module-index
authority: draft
status: partial
baseline_commit: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
version: v18.7.0
scope: upstream-only
---

# Scope

This isolated downstream reverse-spec module under `specs/modules/tools-agent-loop/` records evidence-backed behavior of the pinned upstream checkout only. It does not define SuperMax downstream behavior, latest-upstream behavior, or a target design.

## Reading order and evidence

- Baseline entry: `../../baseline.md` (locked commit, evidence priority, separation rules).
- Module plan: `../../extraction-plan.md` (behavior-chain and completion gates).
- Behavior contract: `spec.md`.
- Baseline checkout verified at `~/.local/share/nvim/lazy/codecompanion.nvim`: detached `HEAD`, commit `558518f8d78a44198cd428f6bf8bf48bfa38d76d`, tag `v18.7.0`, commit time `2026-02-18T08:00:51Z`, `version.txt` `18.7.0`.

## Coverage status

`partial`: source chain was inspected for registration/schema, response normalization, chat completion handoff, authorization, execution, insertion, continuation, queue and cancellation. Tests and docs were inventoried and key docs headings inspected. Full upstream test execution is blocked because the checkout's `deps/mini.nvim` is absent; exact command/error is recorded in `spec.md`. More adapter-specific parser tests and all built-in tool contracts remain evidence gaps, so this is not a completion claim.

## Source trace index

- Registration/context/schema: `lua/codecompanion/interactions/chat/tool_registry.lua:22-184`; `lua/codecompanion/interactions/chat/tools/filter.lua:643-698`.
- Tool parse/resolve/execute/reset: `lua/codecompanion/interactions/chat/tools/init.lua:49-475`.
- Approval cache: `lua/codecompanion/interactions/chat/tools/approvals.lua:471-638`.
- Queue/runner: `lua/codecompanion/interactions/chat/tools/runtime/queue.lua:267-351`; `runtime/runner.lua:352-468`.
- Orchestration/approval/cancel/error/success: `lua/codecompanion/interactions/chat/tools/orchestrator.lua:337-673`.
- Chat payload, completion and tool handoff: `lua/codecompanion/interactions/chat/init.lua:1120-1265`.
- Tool-result insertion: `lua/codecompanion/interactions/chat/init.lua:1549-1585`.
- Adapter normalization/output schemas: `lua/codecompanion/adapters/http/openai.lua`, `anthropic.lua`, `gemini.lua`, `ollama/init.lua`, `openai_responses.lua`, `mistral.lua`, `copilot/init.lua`.
- User behavior: `doc/usage/chat-buffer/tools.md`; extension contract: `doc/extending/tools.md`.
- Tests: `tests/interactions/chat/tools/`, `tests/interactions/chat/tools/runtime/`, `tests/adapters/http/test_tools_in_chat_buffer.lua`, adapter tool stubs under `tests/adapters/http/stubs/`.
