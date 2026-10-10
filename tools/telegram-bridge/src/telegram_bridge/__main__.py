from __future__ import annotations

import argparse
import asyncio

from .app import run_service
from .bot_state import BotStateError, reconcile_bot_state
from .config import load_config
from .security import redact_mapping


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="maxa-telegram-bridge")
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("run", help="Run the local Telegram bridge service")
    sub.add_parser("config", help="Print redacted resolved config")
    sub.add_parser("reconcile-bot", help="Reconcile Telegram server-side bot state for polling bridge usage")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_help()
        return 0
    config = load_config()
    if args.command == "config":
        redacted = redact_mapping(config.model_dump(mode="json"))
        redacted["owner_user_id_configured"] = config.owner_user_id is not None
        redacted["group_id_configured"] = config.group_id is not None
        redacted.pop("owner_user_id", None)
        redacted.pop("group_id", None)
        print(redacted)
        return 0
    if args.command == "run":
        asyncio.run(run_service(config))
        return 0
    if args.command == "reconcile-bot":
        try:
            result = asyncio.run(reconcile_bot_state(config))
        except BotStateError as exc:
            print(f"telegram-bridge-reconcile-bot: ERROR: {exc}")
            return 2
        print(redact_mapping(result))
        return 0
    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
