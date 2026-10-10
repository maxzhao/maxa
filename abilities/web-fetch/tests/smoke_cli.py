#!/usr/bin/env python3
"""Smoke-test the functional web-fetch URL CLI.

URL fetch commands intentionally return final content on stdout rather than a JSON
envelope; only the separate ``search`` command keeps the JSON output contract.
The default suite avoids live network access by using local HTTP servers and mocks.
Use ``--live`` for opt-in real network checks.
"""

from __future__ import annotations

import argparse
import contextlib
import http.server
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
PROJECT_ROOT = ROOT.parents[1]
CLI = ROOT / "bin" / "web-fetch"
SCRIPTS = ROOT / "scripts"

REQUIRED_TOP_LEVEL = {"ok", "tool", "mode", "data", "error", "metadata"}

URL_MODES = {"auto", "direct", "readable", "browser", "stealth"}

@dataclass
class CheckResult:
    name: str
    ok: bool
    details: str = ""


def _load_json(stdout: str) -> dict[str, Any]:
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError as exc:  # pragma: no cover - assertion helper
        raise AssertionError(f"stdout is not valid JSON: {exc}: {stdout[:500]!r}") from exc
    if not isinstance(payload, dict):
        raise AssertionError("CLI output must be a JSON object")
    missing = REQUIRED_TOP_LEVEL - set(payload)
    if missing:
        raise AssertionError(f"missing envelope keys: {sorted(missing)}")
    if payload.get("tool") != "web-fetch":
        raise AssertionError(f"unexpected tool: {payload.get('tool')!r}")
    if not isinstance(payload.get("metadata"), dict):
        raise AssertionError("metadata must be an object")
    if payload.get("ok") is True:
        if payload.get("error") is not None:
            raise AssertionError("success envelope must use error=null")
        if not isinstance(payload.get("data"), dict):
            raise AssertionError("success envelope data must be an object")
    elif payload.get("ok") is False:
        error = payload.get("error")
        if not isinstance(error, dict):
            raise AssertionError("failure envelope error must be an object")
        for key in ("code", "message", "retryable"):
            if key not in error:
                raise AssertionError(f"failure error missing {key!r}")
    else:
        raise AssertionError("ok must be boolean")
    return payload


def run_cli(args: list[str], *, timeout: float = 30, env: dict[str, str] | None = None) -> tuple[int, dict[str, Any], str]:
    """Run a JSON-envelope command.

    Only ``search`` uses this contract; URL fetch modes write content/status to
    stdout and diagnostics to stderr.
    """

    completed = subprocess.run(
        [str(CLI), *args],
        cwd=str(PROJECT_ROOT),
        text=True,
        capture_output=True,
        timeout=timeout,
        env=env,
        check=False,
    )
    payload = _load_json(completed.stdout)
    return completed.returncode, payload, completed.stderr


def run_url_cli(args: list[str], *, timeout: float = 30, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    if not args or args[0] not in URL_MODES:
        raise AssertionError(f"run_url_cli requires a URL fetch mode, got {args!r}")
    return subprocess.run(
        [str(CLI), *args],
        cwd=str(PROJECT_ROOT),
        text=True,
        capture_output=True,
        timeout=timeout,
        env=env,
        check=False,
    )


class QuietHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - stdlib callback name
        if self.path.startswith("/slow"):
            # Keep the response slow enough for --timeout negative tests while
            # still bounded so the test process can finish quickly.
            import time

            time.sleep(1.0)
        if self.path.startswith("/binary"):
            body = b"\x00\x01\x02web-fetch-binary\xff"
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            with contextlib.suppress(BrokenPipeError):
                self.wfile.write(body)
            return
        body = """
        <html><head><title>Web Fetch Smoke</title></head>
        <body>
          <main>
            <h1>Example Domain</h1>
            <p>Alpha Beta Gamma content for web-fetch smoke tests.</p>
            <a href="/next">Next link</a>
          </main>
        </body></html>
        """.strip().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        with contextlib.suppress(BrokenPipeError):
            self.wfile.write(body)

    def log_message(self, _format: str, *args: Any) -> None:
        return


@contextlib.contextmanager
def local_server() -> Iterable[str]:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), QuietHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address
        yield f"http://{host}:{port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def _assert_success(payload: dict[str, Any], mode: str, source: str) -> None:
    if payload.get("ok") is not True:
        raise AssertionError(f"expected success for {mode}, got {payload}")
    if payload.get("mode") != mode:
        raise AssertionError(f"expected mode {mode!r}, got {payload.get('mode')!r}")
    if payload["metadata"].get("source") != source:
        raise AssertionError(f"expected source {source!r}, got {payload['metadata'].get('source')!r}")


def _assert_failure(payload: dict[str, Any], mode: str, code: str | None = None) -> None:
    if payload.get("ok") is not False:
        raise AssertionError(f"expected failure for {mode}, got {payload}")
    if payload.get("mode") != mode:
        raise AssertionError(f"expected mode {mode!r}, got {payload.get('mode')!r}")
    if code and payload["error"].get("code") != code:
        raise AssertionError(f"expected error code {code!r}, got {payload['error'].get('code')!r}")


def check_core_fetch_modes(base_url: str) -> None:
    auto = run_url_cli(["auto", base_url, "--format", "raw", "--max-bytes", "4096"])
    if auto.returncode != 0:
        raise AssertionError(f"auto exited with {auto.returncode}: stderr={auto.stderr!r}")
    if "Example Domain" not in auto.stdout or auto.stdout.lstrip().startswith("{"):
        raise AssertionError(f"auto should output raw inline content, got {auto.stdout[:200]!r}")

    pattern = run_url_cli(["auto", "https://github.com/owner/repo", "--pattern", "README"])
    if pattern.returncode != 2:
        raise AssertionError(f"auto special-route pattern exited {pattern.returncode}, expected 2: stderr={pattern.stderr!r}")
    if "--no-special-route" not in pattern.stderr or "web-fetch readable" not in pattern.stderr:
        raise AssertionError(f"auto pattern error missing suggestion: stderr={pattern.stderr!r}")

    pattern_generic = run_url_cli(["auto", base_url, "--no-special-route", "--format", "raw", "--pattern", "Beta", "--context-chars", "8"])
    if pattern_generic.returncode != 0:
        raise AssertionError(f"auto generic pattern exited {pattern_generic.returncode}: stderr={pattern_generic.stderr!r}")
    if "Beta" not in pattern_generic.stdout or pattern_generic.stdout.lstrip().startswith("{"):
        raise AssertionError(f"auto generic pattern should output extracted content only: {pattern_generic.stdout[:200]!r}")

    failure = run_url_cli(["auto", base_url, "--format", "raw", "--max-bytes", "10"], timeout=25)
    if failure.returncode != 1:
        raise AssertionError(f"auto fallback failure exited {failure.returncode}, expected 1: stderr={failure.stderr!r}")
    if "direct -> readable -> browser -> stealth" not in failure.stderr or "last error" not in failure.stderr:
        raise AssertionError(f"auto failure should include attempt chain and last error: {failure.stderr}")

    direct = run_url_cli(["direct", base_url, "--format", "raw", "--max-bytes", "4096"])
    if direct.returncode != 0:
        raise AssertionError(f"direct exited with {direct.returncode}: stderr={direct.stderr!r}")
    if "Example Domain" not in direct.stdout or direct.stdout.lstrip().startswith("{"):
        raise AssertionError(f"direct should output raw inline content, got {direct.stdout[:200]!r}")

    binary = run_url_cli(["direct", base_url + "/binary", "--format", "raw", "--max-bytes", "4096"])
    if binary.returncode != 1:
        raise AssertionError(f"direct binary exited {binary.returncode}, expected 1: stderr={binary.stderr!r}")
    if "--format markdown" not in binary.stderr or "--format raw --output" not in binary.stderr:
        raise AssertionError(f"direct binary suggestion missing: stderr={binary.stderr!r}")

    max_bytes = run_url_cli(["direct", base_url, "--format", "raw", "--max-bytes", "10"])
    if max_bytes.returncode != 1:
        raise AssertionError(f"direct max-bytes exited {max_bytes.returncode}, expected 1: stderr={max_bytes.stderr!r}")
    if "max-bytes" not in max_bytes.stderr:
        raise AssertionError(f"direct max-bytes stderr should preserve detail: {max_bytes.stderr!r}")

    browser = run_url_cli(["browser", base_url, "--format", "raw"], timeout=20)
    if browser.returncode != 0 and "scrapling" not in browser.stderr.lower():
        raise AssertionError(f"browser dependency error should mention scrapling: stderr={browser.stderr!r}")

    stealth = run_url_cli(["stealth", base_url, "--format", "raw"], timeout=20)
    if stealth.returncode != 0 and "scrapling" not in stealth.stderr.lower():
        raise AssertionError(f"stealth dependency error should mention scrapling: stderr={stealth.stderr!r}")


def check_output_file_semantics(base_url: str) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
        text_path = Path(tmpdir) / "page.html"
        first = run_url_cli(["direct", base_url, "--format", "raw", "--output", str(text_path)])
        if first.returncode != 0:
            raise AssertionError(f"direct output exited {first.returncode}: stderr={first.stderr!r}")
        if first.stdout.strip() != f"Wrote {text_path}" or "Example Domain" not in text_path.read_text(errors="replace"):
            raise AssertionError(f"direct output should write file and status line: stdout={first.stdout!r}")

        exists = run_url_cli(["direct", base_url, "--format", "raw", "--output", str(text_path)])
        if exists.returncode == 0 or "--overwrite" not in exists.stderr:
            raise AssertionError(f"existing output should fail with overwrite hint: stderr={exists.stderr!r}")

        binary_path = Path(tmpdir) / "file.bin"
        binary = run_url_cli(["direct", base_url + "/binary", "--format", "raw", "--output", str(binary_path)])
        if binary.returncode != 0:
            raise AssertionError(f"direct binary output exited {binary.returncode}: stderr={binary.stderr!r}")
        if binary.stdout.strip() != f"Wrote {binary_path}" or not binary_path.read_bytes().startswith(b"\x00\x01\x02"):
            raise AssertionError(f"direct binary output did not write expected file: stdout={binary.stdout!r}")


def check_readable_with_mock() -> None:
    sys.path.insert(0, str(SCRIPTS))
    import fetch_core  # type: ignore

    fake = {
        "ok": True,
        "data": {"url": "https://example.com/final", "content": "Readable Alpha Beta content"},
        "metadata": {"elapsed_ms": 7, "content_length": 27, "truncated": False},
    }
    with mock.patch.object(fetch_core, "fetch_web", return_value=fake):
        result = fetch_core.fetch_readable(url="https://example.com", max_bytes=1000, timeout=5)
    if result.mode != "readable" or result.metadata.get("strategy") != "readable":
        raise AssertionError(f"unexpected readable result metadata: {result}")
    if result.text() != "Readable Alpha Beta content":
        raise AssertionError(f"unexpected readable content: {result.text()!r}")

    failure_payload = {
        "ok": False,
        "error": {"code": "network_error", "message": "underlying failure", "retryable": True},
        "metadata": {"stderr": "low level stderr"},
    }
    with mock.patch.object(fetch_core, "fetch_web", return_value=failure_payload):
        try:
            fetch_core.fetch_readable(url="https://example.com", max_bytes=1000, timeout=5)
        except fetch_core.FetchCoreError as exc:
            if exc.code != "network_error" or "underlying failure" not in exc.message:
                raise AssertionError(f"readable error did not preserve underlying cause: {exc.code} {exc.message}")
        else:
            raise AssertionError("readable failure payload should raise FetchCoreError")


def check_legacy_url_commands_removed(base_url: str) -> None:
    for old in ("fetch", "dynamic", "pattern", "fetch-web", "fetch-github-readme", "fetch-csdn", "fetch-juejin", "fetch-linuxdo"):
        completed = subprocess.run([str(CLI), old, base_url], cwd=str(PROJECT_ROOT), text=True, capture_output=True, timeout=10, check=False)
        if completed.returncode != 2:
            raise AssertionError(f"legacy command {old} exited {completed.returncode}, expected 2: stdout={completed.stdout!r} stderr={completed.stderr!r}")
        # argparse errors still go through stdout in the compatibility error emitter,
        # but URL fetch success paths must never be JSON envelopes.
        payload = _load_json(completed.stdout)
        _assert_failure(payload, "unknown", "invalid_arguments")
        if "invalid choice" not in payload["error"].get("message", ""):
            raise AssertionError(f"legacy command {old} should report invalid choice: {payload}")

    help_result = subprocess.run([str(CLI), "--help"], cwd=str(PROJECT_ROOT), text=True, capture_output=True, timeout=10, check=False)
    if help_result.returncode != 0:
        raise AssertionError(f"help exited {help_result.returncode}: {help_result.stderr}")
    if any(old in help_result.stdout for old in ("fetch-web", "fetch-github-readme", "fetch-csdn", "fetch-juejin", "fetch-linuxdo")):
        raise AssertionError(f"help still exposes old URL commands: {help_result.stdout}")


def check_internal_readable_adapter_with_mock() -> None:
    sys.path.insert(0, str(SCRIPTS))
    import open_websearch_adapter as adapter  # type: ignore

    fake = {
        "status": "ok",
        "data": {"content": "mock web content", "truncated": False, "links": []},
        "metadata": {"elapsed_ms": 7, "content_length": 16, "truncated": False},
    }
    with mock.patch.object(adapter.subprocess, "run") as run:
        run.return_value = subprocess.CompletedProcess(["node"], 0, json.dumps(fake), "")
        payload = adapter.fetch_web(url="https://example.com", max_chars=1000, readability=True, include_links=True, timeout=5)
    _assert_success(payload, "fetch-web", "open-websearch")
    for key in ("elapsed_ms", "content_length", "truncated", "exit_code"):
        if key not in payload["metadata"]:
            raise AssertionError(f"readable adapter metadata missing {key}")


def check_search_with_mock() -> None:
    sys.path.insert(0, str(SCRIPTS))
    import open_websearch_adapter as adapter  # type: ignore

    fake = {
        "status": "ok",
        "data": {"results": [{"title": "Neovim", "url": "https://neovim.io"}], "partialFailures": []},
        "metadata": {"elapsed_ms": 9, "engine": "duckduckgo", "result_count": 1, "partial_failure_count": 0},
    }
    with mock.patch.object(adapter.subprocess, "run") as run:
        run.return_value = subprocess.CompletedProcess(["node"], 0, json.dumps(fake), "")
        payload = adapter.search(query="neovim", engine="duckduckgo", limit=1, timeout=5)
    _assert_success(payload, "search", "open-websearch")
    for key in ("elapsed_ms", "engine", "result_count", "exit_code"):
        if key not in payload["metadata"]:
            raise AssertionError(f"search metadata missing {key}")

def check_negative_paths(base_url: str) -> None:
    actual_exit, payload, _ = run_cli(["search", "neovim", "--engine", "unsupported-engine", "--json"], timeout=10)
    if actual_exit != 1:
        raise AssertionError(f"search unsupported engine exited {actual_exit}, expected 1: {payload}")
    _assert_failure(payload, "search", "unsupported_engine")

    invalid_number = subprocess.run([str(CLI), "direct", base_url, "--max-bytes", "nope"], cwd=str(PROJECT_ROOT), text=True, capture_output=True, timeout=10, check=False)
    if invalid_number.returncode != 2:
        raise AssertionError(f"invalid --max-bytes exited {invalid_number.returncode}, expected 2: stdout={invalid_number.stdout!r} stderr={invalid_number.stderr!r}")
    payload = _load_json(invalid_number.stdout)
    _assert_failure(payload, "direct", "invalid_arguments")

    invalid_url = run_url_cli(["direct", "notaurl", "--format", "raw"], timeout=10)
    if invalid_url.returncode != 2:
        raise AssertionError(f"invalid direct URL exited {invalid_url.returncode}, expected 2: stderr={invalid_url.stderr!r}")
    if "[access]" not in invalid_url.stderr or "absolute http(s) URL" not in invalid_url.stderr:
        raise AssertionError(f"invalid direct URL should use stderr access error: {invalid_url.stderr!r}")


def check_live_network() -> None:
    live_cases = [
        ("direct", ["direct", "https://example.com", "--format", "raw", "--max-bytes", "4096"], "Example Domain", True),
        ("auto", ["auto", "https://example.com", "--format", "raw", "--max-bytes", "4096"], "Example Domain", True),
        # GitHub special routing is covered as a best-effort live smoke because
        # GitHub/network behavior may be less stable than example.com.
        ("github special route", ["auto", "https://github.com/neovim/neovim", "--format", "raw", "--max-bytes", "65536"], "Neovim", False),
    ]
    soft_failures: list[str] = []
    for mode, args, expected, required in live_cases:
        completed = subprocess.run([str(CLI), *args], cwd=str(PROJECT_ROOT), text=True, capture_output=True, timeout=120, check=False)
        if completed.returncode != 0 or expected not in completed.stdout:
            detail = f"live {mode} failed: exit={completed.returncode}, expected={expected!r}, stderr={completed.stderr!r}, stdout={completed.stdout[:200]!r}"
            if required:
                raise AssertionError(detail)
            soft_failures.append(detail)
    if soft_failures:
        raise AssertionError("soft live failures: " + " | ".join(soft_failures))


def run_check(name: str, fn: Callable[[], None]) -> CheckResult:
    try:
        fn()
        return CheckResult(name, True, "ok")
    except Exception as exc:  # noqa: BLE001 - smoke tool should collect failures
        return CheckResult(name, False, f"{type(exc).__name__}: {exc}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run web-fetch CLI smoke tests")
    parser.add_argument("--live", action="store_true", help="also run real network smoke checks")
    parser.add_argument("--json", action="store_true", help="emit machine-readable smoke report")
    args = parser.parse_args(argv)

    checks: list[tuple[str, Callable[[], None]]] = []
    with local_server() as base_url:
        checks.extend(
            [
                ("core fetch modes local behavior", lambda: check_core_fetch_modes(base_url)),
                ("URL file output semantics", lambda: check_output_file_semantics(base_url)),
                ("negative envelope paths", lambda: check_negative_paths(base_url)),
                ("legacy URL commands removed", lambda: check_legacy_url_commands_removed(base_url)),
            ]
        )
        results = [run_check(name, fn) for name, fn in checks]

    mock_checks = [
        ("internal readable adapter mock success", check_internal_readable_adapter_with_mock),
        ("readable core mock success", check_readable_with_mock),
        ("open-websearch search mock success", check_search_with_mock),
    ]
    results.extend(run_check(name, fn) for name, fn in mock_checks)

    if args.live:
        results.append(run_check("live network smoke", check_live_network))

    report = {
        "ok": all(item.ok for item in results),
        "tool": "web-fetch-smoke",
        "checks": [item.__dict__ for item in results],
    }
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        for item in results:
            marker = "PASS" if item.ok else "FAIL"
            print(f"[{marker}] {item.name}: {item.details}")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
