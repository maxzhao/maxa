#!/usr/bin/env python3
"""Unit checks for web-fetch auto router and fallback orchestration."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from auto_router import AutoFetchError, detect_special_route, fetch_auto  # noqa: E402
from fetch_core import FetchCoreError, FetchCoreResult  # noqa: E402


def test_detect_special_routes() -> None:
    cases = {
        "https://github.com/owner/repo": "github-readme",
        "https://blog.csdn.net/example/article/details/123": "csdn",
        "https://juejin.cn/post/123": "juejin",
        "https://linux.do/t/topic/123": "linuxdo",
        "https://example.com/page": None,
    }
    for url, expected in cases.items():
        route = detect_special_route(url)
        actual = route.name if route else None
        if actual != expected:
            raise AssertionError(f"{url}: expected {expected!r}, got {actual!r}")


def test_special_route_pattern_rejected() -> None:
    try:
        fetch_auto(url="https://github.com/owner/repo", pattern="README")
    except AutoFetchError as exc:
        if exc.code != "pattern_not_supported" or exc.exit_code != 2:
            raise AssertionError(f"unexpected special-route pattern error: {exc.code} {exc.exit_code}")
        if "--no-special-route" not in exc.message or "web-fetch readable" not in exc.message:
            raise AssertionError(f"missing suggestion in message: {exc.message}")
    else:  # pragma: no cover - assertion helper
        raise AssertionError("special route + pattern should fail")


def test_no_special_route_uses_generic_fallback() -> None:
    calls: list[str] = []

    def fake_fetcher(mode: str, **_kwargs: object) -> FetchCoreResult:
        calls.append(mode)
        return FetchCoreResult(mode=mode, content=b"Generic fallback content that is long enough", content_type="text/plain", final_url="https://github.com/owner/repo", status_code=200, metadata={"source": "fake"})

    result = fetch_auto(url="https://github.com/owner/repo", no_special_route=True, fetcher=fake_fetcher)
    if calls != ["direct"]:
        raise AssertionError(f"expected direct only, got {calls}")
    if result.route != "generic-fallback" or result.mode != "direct":
        raise AssertionError(f"unexpected result route/mode: {result}")


def test_fallback_sequence_and_stop_condition() -> None:
    calls: list[str] = []

    def fake_fetcher(mode: str, **_kwargs: object) -> FetchCoreResult:
        calls.append(mode)
        if mode == "direct":
            return FetchCoreResult(mode=mode, content=b"\x00\x01binary", content_type="application/octet-stream", final_url="https://example.test/file", status_code=200, metadata={"source": "fake"})
        if mode == "readable":
            raise FetchCoreError("extraction_failed", "readable had no main content")
        return FetchCoreResult(mode=mode, content=b"<html><body>Browser fallback produced useful article text for auto routing.</body></html>", content_type="text/html", final_url="https://example.test/file", status_code=200, metadata={"source": "fake"})

    result = fetch_auto(url="https://example.test/file", fetcher=fake_fetcher)
    if calls != ["direct", "readable", "browser"]:
        raise AssertionError(f"unexpected fallback calls: {calls}")
    if result.mode != "browser":
        raise AssertionError(f"expected browser selection, got {result.mode}")
    chain = result.metadata.get("attempt_chain")
    if not isinstance(chain, list) or chain[-1].get("selected") is not True:
        raise AssertionError(f"attempt chain missing selection: {chain}")


def test_fallback_failure_keeps_chain_and_last_error() -> None:
    def fake_fetcher(mode: str, **_kwargs: object) -> FetchCoreResult:
        raise FetchCoreError("network_error", f"{mode} failed with details", retryable=True)

    try:
        fetch_auto(url="https://example.test/fail", fetcher=fake_fetcher)
    except AutoFetchError as exc:
        if "direct -> readable -> browser -> stealth" not in exc.message:
            raise AssertionError(f"missing attempt chain: {exc.message}")
        if "stealth failed with details" not in exc.message:
            raise AssertionError(f"missing last error: {exc.message}")
        chain = exc.metadata.get("attempt_chain")
        if not isinstance(chain, list) or [item.get("mode") for item in chain] != ["direct", "readable", "browser", "stealth"]:
            raise AssertionError(f"bad metadata chain: {chain}")
    else:  # pragma: no cover - assertion helper
        raise AssertionError("fallback failure should raise")


def main() -> int:
    tests = [
        test_detect_special_routes,
        test_special_route_pattern_rejected,
        test_no_special_route_uses_generic_fallback,
        test_fallback_sequence_and_stop_condition,
        test_fallback_failure_keeps_chain_and_last_error,
    ]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
