# Maxa Telegram Bridge

Agent-facing runtime service for exact-Chat Telegram `ask`, completion notifications, and notify-listener-gated idle Chat input.

## Contract

- Default disabled; an identified Chat's `ask` or completion listener creates/reuses a session topic. Ordinary Telegram text is accepted only from the authorized owner while that exact Chat is open, notify listening is active, and the agent loop is idle. Busy/offline/unlistened messages are rejected immediately, not queued. Local Chat input remains available; builtin `ask` replies still work during a running loop.
- Persistent identity is `project_root + save_id`, never CodeCompanion runtime `chat.id`.
- Builtin `ask` and per-Chat completion notifications share a persisted session topic keyed by `project_root + save_id`. Missing identity, group or usable topic fails session-topic delivery without owner-private fallback; the local Chat remains available.
- Completion listening is runtime-only. Delivered completion notices indicate whether the idle Chat can be replied to; a local user message submitted first asynchronously appends a status to the last delivered notification segment without sending a new TG message. This optional edit is attempted once; all edit errors are silently ignored without warning, retry, fallback delivery or interruption of Chat input. Accepted TG text receives an immediate *receipt*, not a claim that Chat submission has already succeeded; a later nvim-side rejection is reported separately. Notifications are suppressed only for a positively observed foreground Chat (with tmux, a connected client must display its window); suppressed notices are not failures. Safe pre-delivery failures use bounded retries; ambiguous delivery failures are not blindly retried. Legacy human-assist calls without `ask_route: true` retain owner-private delivery. `MAXA_TELEGRAM_OWNER_USER_ID` is required for authorized replies and ordinary TG Chat input. Route and fallback details are not returned to clients.
- Bot commands: `/ping`, read-only `/sessions` (running/listening state), and owner-confirmed `/clean_tracked_topics` for known inactive topics. Legacy binding records are dropped by the Bridge schema migration without deleting Telegram topics or messages; unknown topics remain ineligible for Chat input and are skipped by cleanup.
- The Python service owns Telegram Bot API credentials and destination selection. Neovim clients provide only optional exact caller identity and never Telegram chat/topic IDs.
- Do not store real tokens in this repository. Use environment variables or a local `.env` file.
- `.env` is local-only and git-ignored; do not print or persist its secret values.

## Maintenance guide

Future Agents maintaining this bridge must read `MAINTENANCE.md` before changing code. It records architecture, file responsibilities, config/secret boundaries, validation commands, live smoke procedures, and known manual verification items.

## Local commands

```bash
cd tools/telegram-bridge
uv run python -m compileall src tests
uv run pytest
uv run maxa-telegram-bridge --help
uv run maxa-telegram-bridge run
uv run maxa-telegram-bridge reconcile-bot
```

Project-level just recipes:

```bash
just telegram-bridge-reconcile-bot # reconcile Telegram server-side bot state for polling bridge usage
just telegram-bridge-install   # install/enable/start the WSL user systemd service
just telegram-bridge-status    # inspect service status and log path
just telegram-bridge-log 100   # tail the persistent file log
just telegram-bridge-restart   # restart the service after local config changes
just telegram-bridge-uninstall # stop/disable/remove the service; keeps logs
```

`reconcile-bot` is an explicit, idempotent Telegram server-side state operation. It verifies the bot identity, clears webhook state with `drop_pending_updates=False` for polling compatibility, sets the bridge command menu in the configured group chat scope, and checks bot permissions. It must not create topics, send messages, pin messages, or print secrets.

Normal Chat input may come from Neovim or the exact ask/notify topic when the listener is active and the Chat is idle. TG input preserves an unsent local draft; running-loop TG input is rejected rather than replayed later. `@ask` responses have their own first-valid-response path.

The systemd service is installed as `maxa-telegram-bridge.service` under the current Linux user's systemd user directory. It starts when the WSL distro's systemd user manager starts. Persistent stdout/stderr logs are written to `${XDG_STATE_HOME:-~/.local/state}/maxa/telegram-bridge/service.log` for troubleshooting.

## Config inputs

The service reads Telegram settings from process environment variables and, by default, the nearest `.env` files discovered from the current working directory and this package. Set `MAXA_ENV_FILE=/path/to/.env` to force an explicit local env file for commands or tests.

Supported variables include `MAXA_TELEGRAM_BOT_TOKEN`, `MAXA_TELEGRAM_GROUP_ID`, `MAXA_TELEGRAM_OWNER_USER_ID`, `MAXA_TELEGRAM_BRIDGE_TOKEN`, `MAXA_TELEGRAM_SQLITE_PATH`, `MAXA_TELEGRAM_HEARTBEAT_TTL`, and `MAXA_TELEGRAM_POLL_TIMEOUT`. `MAXA_TELEGRAM_OWNER_USER_ID` is required for human-assist endpoints and ordinary TG Chat input. `MAXA_TELEGRAM_GROUP_ID` is the session-topic group. `MAXA_TELEGRAM_CHAT_ID` remains its legacy alias and is never reinterpreted as the private destination. Telegram network calls reuse project-level proxy variables in order: `ALL_PROXY`, `HTTPS_PROXY`, then `HTTP_PROXY`.

`just telegram-bridge-check` reports only `owner_user_id_configured` and `group_id_configured` booleans for destination identifiers; it does not print their values.
