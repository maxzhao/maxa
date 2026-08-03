---
title: SuperMax Chat View and Input Surface
created: 2026-08-02
updated: 2026-08-02
doc_role: target-module-spec
authority: draft
status: partial
baseline: ../modules/chat-lifecycle/spec.md
---

# Contract

Chat is the only conversational view. It renders normalized messages, tool projections, status, errors, context notices and dynamic project/provider/model introduction. It accepts user text, context attachments and Chat-owned Action/Command invocations.

The runtime MUST NOT require the Neovim command-input Chat mode as an alternative surface. `CodeCompanionCmd`-style separate command interaction is removed; this does not remove the Command abstraction or commands dispatched from Chat/actions.

## View lifecycle

A view can attach, detach, reattach and close independently of its session. Multi-line virtual text, buffer validity, input snapshots and asynchronous render callbacks are guarded by view generation. Dynamic intro content reflects project root, provider and model without becoming session source data.

Rendering failures are isolated from request execution and reported through spine/events. The view consumes snapshots/events; it does not infer orchestration state by reading CodeCompanion object internals.

## View model

A view owns `view_id`, `session_id`, generation, buffer/window handles, layout, cursor/input snapshot, render revision and disposable extmarks/timers/autocmds. Session messages and orchestration state are read-only inputs. One session may have zero or one primary editable Chat view; additional read-only projections require explicit support.

`hide` removes/focus-switches the window but keeps the view attachment. Buffer deletion detaches the view. `close view` disposes view resources but does not close the session. `close session` is a separate explicit Action that closes all views and owned runtime work. Reattach creates a new view generation and full snapshot render; late callbacks from an earlier generation are ignored.

## Rendering

- Render visible normalized user/assistant messages in order; hidden/system/project/provider records never leak unless a debug projection explicitly requests them.
- Reasoning, context and tool details use typed collapsible blocks with stable IDs.
- Streaming deltas append only to the matching render revision/message part. Re-render from snapshot is always possible and yields equivalent visible content.
- Dynamic intro/provider/model/project labels are projection metadata, not persisted conversation messages.
- Tool display Markdown/raw detail cannot mutate provider-facing or durable result content.
- Invalid/deleted buffers cause view detach/cleanup, not request failure.

## Input

The editable user region has one captured revision. Submit atomically captures visible text, selected context IDs, attachments and invoked inline Chat Commands, validates them through `message-context-target`, then marks that revision submitted. Text typed after capture belongs to the next revision.

Completion/pickers insert declared Action/Command/context references; they do not execute from stale view generations. Normal and visual entrypoints create/focus Chat and snapshot visual context. Provider/model selection changes session configuration only at a safe request boundary.

## Host integration

Layouts are `vertical`, `horizontal`, `float`, or current `buffer`. Keymaps/actions are registry entries, not hard-coded orchestration callbacks. Accessibility/plain-text fallback preserves all status/error/tool outcomes without relying solely on highlights/icons. Lualine/spinner consume spine separately; Chat rendering does not own global status.

View/input/render fixtures are normative in `../../runtime-fixture-contract.md`.
