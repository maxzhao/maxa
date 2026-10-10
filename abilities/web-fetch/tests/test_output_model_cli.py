#!/usr/bin/env python3
"""Smoke tests for the new web-fetch URL output model."""

from __future__ import annotations

import contextlib
import http.server
import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parents[1]
PROJECT_ROOT = ROOT.parents[1]
CLI = ROOT / "bin" / "web-fetch"


class QuietHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path.startswith("/binary"):
            body = b"\x00\x01\x02web-fetch-binary\xff"
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            with contextlib.suppress(BrokenPipeError):
                self.wfile.write(body)
            return
        if self.path.startswith("/pattern"):
            body = b"alpha 1234567890 beta 1234567890 gamma 1234567890 delta"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            with contextlib.suppress(BrokenPipeError):
                self.wfile.write(body)
            return
        if self.path.startswith("/json"):
            body = b'{"title":"Web Fetch JSON","body":"Alpha Beta"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            with contextlib.suppress(BrokenPipeError):
                self.wfile.write(body)
            return
        body = b"<html><body><h1>Example Domain</h1><p>Alpha Beta output model.</p></body></html>"
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


def run_cli(args: list[str], *, env: dict[str, str] | None = None, timeout: float = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(CLI), *args], cwd=str(PROJECT_ROOT), text=True, capture_output=True, timeout=timeout, env=env, check=False)


def assert_ok(name: str, condition: bool, detail: str = "") -> None:
    if not condition:
        raise AssertionError(f"{name} failed: {detail}")
    print(f"PASS {name}")


def test_raw_inline_and_binary(base_url: str) -> None:
    result = run_cli(["direct", base_url, "--format", "raw"])
    assert_ok("raw inline text exit", result.returncode == 0, result.stderr)
    assert_ok("raw inline text body", "Example Domain" in result.stdout and not result.stdout.lstrip().startswith("{"), result.stdout[:120])

    binary = run_cli(["direct", base_url + "/binary", "--format", "raw"])
    assert_ok("raw inline binary exit", binary.returncode != 0, binary.stdout + binary.stderr)
    assert_ok("raw inline binary suggestion", "--format markdown" in binary.stderr and "--format raw --output" in binary.stderr, binary.stderr)


def test_raw_output_and_overwrite(base_url: str) -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
        path = Path(tmpdir) / "page.html"
        first = run_cli(["direct", base_url, "--format", "raw", "--output", str(path)])
        assert_ok("raw output exit", first.returncode == 0, first.stderr)
        assert_ok("raw output status", first.stdout.strip() == f"Wrote {path}", first.stdout)
        assert_ok("raw output content", b"Example Domain" in path.read_bytes(), path.read_text(errors="replace"))

        exists = run_cli(["direct", base_url, "--format", "raw", "--output", str(path)])
        assert_ok("output exists exit", exists.returncode != 0, exists.stdout + exists.stderr)
        assert_ok("output exists hint", "--overwrite" in exists.stderr, exists.stderr)

        binary_path = Path(tmpdir) / "file.bin"
        binary = run_cli(["direct", base_url + "/binary", "--format", "raw", "--output", str(binary_path)])
        assert_ok("binary output exit", binary.returncode == 0, binary.stderr)
        assert_ok("binary output bytes", binary_path.read_bytes().startswith(b"\x00\x01\x02"), repr(binary_path.read_bytes()))

        overwrite = run_cli(["direct", base_url, "--format", "raw", "--output", str(path), "--overwrite"])
        assert_ok("overwrite exit", overwrite.returncode == 0, overwrite.stderr)


def make_mock_uvx(tmpdir: Path, *, fail: bool = False) -> dict[str, str]:
    bin_dir = tmpdir / "bin"
    bin_dir.mkdir()
    uvx = bin_dir / "uvx"
    if fail:
        uvx.write_text("#!/usr/bin/env sh\necho markitdown boom >&2\nexit 7\n", encoding="utf-8")
    else:
        uvx.write_text("#!/usr/bin/env sh\nprintf '# Converted Markdown\\n\\n'\ncat \"$2\"\n", encoding="utf-8")
    uvx.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
    return env


def test_pattern_raw_and_output(base_url: str) -> None:
    result = run_cli(["direct", base_url + "/pattern", "--format", "raw", "--pattern", "beta", "--context-chars", "6"])
    assert_ok("pattern raw exit", result.returncode == 0, result.stderr)
    assert_ok("pattern raw context", "7890 beta 1234" in result.stdout and "alpha" not in result.stdout, result.stdout)

    merged = run_cli(["direct", base_url + "/pattern", "--format", "raw", "--pattern", "beta|gamma", "--context-chars", "12"])
    assert_ok("pattern merged exit", merged.returncode == 0, merged.stderr)
    assert_ok("pattern merged context", merged.stdout.count("---") == 0 and "beta" in merged.stdout and "gamma" in merged.stdout, merged.stdout)

    no_match = run_cli(["direct", base_url + "/pattern", "--format", "raw", "--pattern", "zzz"])
    assert_ok("pattern no match exit", no_match.returncode != 0, no_match.stdout + no_match.stderr)
    assert_ok("pattern no match stderr", "[pattern] no matches" in no_match.stderr, no_match.stderr)

    invalid = run_cli(["direct", base_url + "/pattern", "--format", "raw", "--pattern", "("])
    assert_ok("pattern invalid exit", invalid.returncode == 2, invalid.stdout + invalid.stderr)
    assert_ok("pattern invalid stderr", "[pattern] invalid regex" in invalid.stderr, invalid.stderr)

    with tempfile.TemporaryDirectory() as tmpdir:
        path = Path(tmpdir) / "extract.txt"
        out = run_cli(["direct", base_url + "/pattern", "--format", "raw", "--pattern", "delta", "--context-chars", "5", "--output", str(path)])
        assert_ok("pattern output exit", out.returncode == 0, out.stderr)
        assert_ok("pattern output status", out.stdout.strip() == f"Wrote {path}", out.stdout)
        assert_ok("pattern output content", "delta" in path.read_text(), path.read_text())


def test_pattern_markdown(base_url: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        env = make_mock_uvx(Path(tmp), fail=False)
        result = run_cli(["direct", base_url, "--format", "markdown", "--pattern", "Converted Markdown", "--context-chars", "5"], env=env)
        assert_ok("pattern markdown exit", result.returncode == 0, result.stderr)
        assert_ok("pattern markdown body", "Converted Markdown" in result.stdout and "Example Domain" not in result.stdout, result.stdout)


def test_special_route_pattern_cli() -> None:
    result = run_cli(["auto", "https://github.com/owner/repo", "--pattern", "README"])
    assert_ok("special route pattern exit", result.returncode == 2, result.stdout + result.stderr)
    assert_ok("special route pattern suggestion", "[route] This URL uses special route: github-readme" in result.stderr and "--no-special-route" in result.stderr, result.stderr)


def test_legacy_url_commands_removed(base_url: str) -> None:
    for old in ("fetch", "dynamic", "pattern", "fetch-web", "fetch-github-readme", "fetch-csdn", "fetch-juejin", "fetch-linuxdo"):
        result = run_cli([old, base_url])
        assert_ok(f"legacy {old} exit", result.returncode == 2, result.stdout + result.stderr)
        assert_ok(f"legacy {old} invalid choice", "invalid choice" in result.stdout and old in result.stdout, result.stdout)

    help_result = run_cli(["--help"])
    assert_ok("help exit", help_result.returncode == 0, help_result.stderr)
    help_text = help_result.stdout
    assert_ok("help has new commands", "auto" in help_text and "direct" in help_text and "readable" in help_text, help_text)
    assert_ok("help omits old commands", all(old not in help_text for old in ("fetch-web", "fetch-github-readme", "fetch-csdn", "fetch-juejin", "fetch-linuxdo")), help_text)


def test_markdown_success_and_failure(base_url: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        env = make_mock_uvx(Path(tmp), fail=False)
        result = run_cli(["direct", base_url, "--format", "markdown"], env=env)
        assert_ok("markdown inline exit", result.returncode == 0, result.stderr)
        assert_ok("markdown inline body", "# Converted Markdown" in result.stdout and "Example Domain" in result.stdout, result.stdout[:160])

    with tempfile.TemporaryDirectory() as tmp:
        env = make_mock_uvx(Path(tmp), fail=True)
        result = run_cli(["direct", base_url, "--format", "markdown"], env=env)
        assert_ok("markdown failure exit", result.returncode != 0, result.stdout + result.stderr)
        assert_ok("markdown failure stderr", "markitdown boom" in result.stderr and "--format raw --output" in result.stderr, result.stderr)


def main() -> int:
    with local_server() as base_url:
        test_raw_inline_and_binary(base_url)
        test_raw_output_and_overwrite(base_url)
        test_pattern_raw_and_output(base_url)
        test_pattern_markdown(base_url)
        test_special_route_pattern_cli()
        test_legacy_url_commands_removed(base_url)
        test_markdown_success_and_failure(base_url)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
