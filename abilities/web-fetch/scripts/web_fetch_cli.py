#!/usr/bin/env python3
"""Unified CLI entrypoint for the web-fetch Ability."""

from __future__ import annotations

import argparse
import sys
from typing import Any

from schema import emit, failure
from auto_router import AutoFetchError, fetch_auto
from fetch_core import FetchCoreError, FetchCoreResult, fetch_by_mode
from open_websearch_adapter import search
from output_model import OutputModelError, emit_rendered


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        mode = "unknown"
        argv = sys.argv[1:]
        for candidate in (
            "auto",
            "direct",
            "readable",
            "browser",
            "stealth",
            "search",
        ):
            if candidate in argv:
                mode = candidate
                break
        emit(failure(mode, "invalid_arguments", message, retryable=False))
        raise SystemExit(2)


def _add_common_json(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--json", action="store_true", default=True, help="Output JSON envelope (default).")


def _fetch_core_result_from_data(mode: str, data: dict[str, Any], metadata: dict[str, Any]) -> FetchCoreResult:
    content = str(data.get("content") or "").encode("utf-8")
    return FetchCoreResult(
        mode=mode,
        content=content,
        content_type=str(data.get("content_type") or metadata.get("content_type") or "text/plain; charset=utf-8"),
        final_url=str(data.get("final_url") or data.get("url") or metadata.get("final_url") or ""),
        status_code=data.get("status_code") if isinstance(data.get("status_code"), int) else None,
        metadata=metadata,
    )


def _emit_new_url_output(result: FetchCoreResult, args: argparse.Namespace) -> int:
    try:
        rendered = emit_rendered(
            result,
            output_format=args.format,
            output_path=args.output,
            overwrite=args.overwrite,
            pattern=args.pattern,
            context_chars=args.context_chars,
        )
    except OutputModelError as exc:
        print(exc.message, file=sys.stderr)
        return exc.exit_code
    if isinstance(rendered, bytes):
        sys.stdout.buffer.write(rendered)
    else:
        print(rendered)
    return 0


def _add_core_fetch_args(parser: argparse.ArgumentParser, *, timeout_default: float) -> None:
    parser.add_argument("url", help="HTTP(S) URL to fetch")
    parser.add_argument("--format", choices=("raw", "markdown"), default="markdown", help="Output format for URL fetch commands")
    parser.add_argument("--output", default=None, help="Write final content to this file instead of stdout")
    parser.add_argument("--overwrite", action="store_true", help="Overwrite --output if it already exists")
    parser.add_argument("--max-bytes", type=int, default=2 * 1024 * 1024, help="Maximum response/readable bytes")
    parser.add_argument("--proxy-url", default=None, help="Optional HTTP(S) proxy URL for this request")
    parser.add_argument("--timeout", type=float, default=timeout_default, help="Request timeout in seconds")
    parser.add_argument("--pattern", default=None, help="Regex to extract matching context from the final formatted text")
    parser.add_argument("--context-chars", type=int, default=200, help="Characters to include before/after each regex match")


def build_parser() -> argparse.ArgumentParser:
    parser = JsonArgumentParser(prog="web-fetch", description="Unified web-fetch Ability CLI")
    subparsers = parser.add_subparsers(dest="command", required=True, parser_class=JsonArgumentParser)

    auto_parser = subparsers.add_parser("auto", help="Auto-route URL fetch with special site routes and generic fallback")
    _add_core_fetch_args(auto_parser, timeout_default=30)
    auto_parser.add_argument("--no-special-route", action="store_true", help="Disable GitHub/CSDN/Juejin/Linux.do special routes")

    for command, help_text, timeout_default in (
        ("direct", "Direct HTTP(S) fetch without Markdown/readability conversion", 30),
        ("readable", "Readable page text extraction via open-websearch", 30),
        ("browser", "Browser/JS-capable fetch via scrapling", 60),
        ("stealth", "Strong anti-bot fetch via scrapling max-stealth", 60),
    ):
        core_parser = subparsers.add_parser(command, help=help_text)
        _add_core_fetch_args(core_parser, timeout_default=timeout_default)

    search_parser = subparsers.add_parser("search", help="Search the web via vendored open-websearch runtime")
    search_parser.add_argument("query", help="Search query")
    search_parser.add_argument("--engine", default="duckduckgo", help="Single search engine name")
    search_parser.add_argument("--engines", default=None, help="Comma-separated search engines; overrides --engine")
    search_parser.add_argument("--limit", type=int, default=10, help="Maximum number of results (1-50)")
    search_parser.add_argument("--search-mode", choices=("request", "auto", "playwright"), default=None, help="Search mode hint")
    search_parser.add_argument("--proxy-url", default=None, help="Optional HTTP(S) proxy URL for this request")
    search_parser.add_argument("--timeout", type=float, default=60, help="Command timeout in seconds")
    _add_common_json(search_parser)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "auto":
        try:
            auto_result = fetch_auto(
                url=args.url,
                no_special_route=args.no_special_route,
                pattern=args.pattern,
                max_bytes=args.max_bytes,
                timeout=args.timeout,
                proxy_url=args.proxy_url,
            )
            core_result = _fetch_core_result_from_data(auto_result.mode, auto_result.data, auto_result.metadata)
            return _emit_new_url_output(core_result, args)
        except AutoFetchError as exc:
            print(exc.message if exc.code == "pattern_not_supported" else f"[access] {exc.message}", file=sys.stderr)
            return exc.exit_code

    if args.command in {"direct", "readable", "browser", "stealth"}:
        try:
            result = fetch_by_mode(
                args.command,
                url=args.url,
                max_bytes=args.max_bytes,
                timeout=args.timeout,
                proxy_url=args.proxy_url,
            )
            return _emit_new_url_output(result, args)
        except FetchCoreError as exc:
            print(f"[access] {exc.message}", file=sys.stderr)
            return exc.exit_code

    if args.command == "search":
        payload = search(
            query=args.query,
            engine=args.engine,
            engines=args.engines,
            limit=args.limit,
            search_mode=args.search_mode,
            proxy_url=args.proxy_url,
            timeout=args.timeout,
        )
        emit(payload)
        return 0 if payload.get("ok") else 1

    emit(failure(args.command or "unknown", "invalid_arguments", "unsupported command", retryable=False))
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
