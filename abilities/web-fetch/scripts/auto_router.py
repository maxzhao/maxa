"""Auto URL routing and fallback orchestration for web-fetch.

The auto layer is intentionally small and deterministic: URL classification is a
pure function, while fallback uses the functional fetch core introduced in task
20.2. Formatting, pattern extraction and inline/file output are handled by later
CLI layers.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable
from urllib.parse import urlparse

from fetch_core import FetchCoreError, FetchCoreResult, fetch_by_mode
from open_websearch_adapter import fetch_site

SPECIAL_ROUTE_TO_COMMAND = {
    "github-readme": "fetch-github-readme",
    "csdn": "fetch-csdn",
    "juejin": "fetch-juejin",
    "linuxdo": "fetch-linuxdo",
}

GENERIC_FALLBACK_CHAIN = ("direct", "readable", "browser", "stealth")
LOW_QUALITY_TEXT_BYTES = 80


@dataclass(slots=True)
class AutoRoute:
    """Classified special route for `web-fetch auto`."""

    name: str
    command: str


@dataclass(slots=True)
class AutoFetchResult:
    """Result returned by the auto orchestrator."""

    route: str
    mode: str
    data: dict[str, Any]
    metadata: dict[str, Any] = field(default_factory=dict)


class AutoFetchError(Exception):
    """Typed error raised by auto route/fallback orchestration."""

    def __init__(self, code: str, message: str, *, retryable: bool = False, exit_code: int = 1, metadata: dict[str, Any] | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.retryable = retryable
        self.exit_code = exit_code
        self.metadata = metadata or {}


def detect_special_route(url: str) -> AutoRoute | None:
    """Return the internal special route for a URL, if one should be used.

    These routes are deliberately not exposed as public `auto --method` values;
    they only map known site URLs to the existing vendored site extractors.
    """

    parsed = urlparse(url)
    host = (parsed.netloc or "").lower().split(":", 1)[0]
    path_parts = [part for part in (parsed.path or "").split("/") if part]

    if host == "github.com" and len(path_parts) >= 2:
        return AutoRoute("github-readme", SPECIAL_ROUTE_TO_COMMAND["github-readme"])
    if host.endswith("csdn.net"):
        return AutoRoute("csdn", SPECIAL_ROUTE_TO_COMMAND["csdn"])
    if host in {"juejin.cn", "www.juejin.cn"}:
        return AutoRoute("juejin", SPECIAL_ROUTE_TO_COMMAND["juejin"])
    if host in {"linux.do", "www.linux.do"}:
        return AutoRoute("linuxdo", SPECIAL_ROUTE_TO_COMMAND["linuxdo"])
    return None


def _site_payload_to_result(route: AutoRoute, payload: dict[str, Any]) -> AutoFetchResult:
    metadata = dict(payload.get("metadata") or {})
    metadata.update({"route": route.name, "route_command": route.command, "strategy": "special-route"})
    if not payload.get("ok"):
        error = payload.get("error") if isinstance(payload.get("error"), dict) else {}
        code = str(error.get("code") or "extraction_failed")
        message = str(error.get("message") or f"special route {route.name} failed")
        raise AutoFetchError(code, f"special route {route.name} failed: {message}", retryable=bool(error.get("retryable")), exit_code=1, metadata=metadata)
    data = payload.get("data") if isinstance(payload.get("data"), dict) else {}
    return AutoFetchResult(route=route.name, mode=route.command, data=data, metadata=metadata)


def _quality_problem(result: FetchCoreResult) -> str | None:
    if not result.is_textual():
        return "non_text_response"
    text = result.text().strip()
    if not text:
        return "empty_text"
    if len(text.encode("utf-8")) < LOW_QUALITY_TEXT_BYTES and "text/html" in (result.content_type or "").lower():
        return "low_quality_html_text"
    return None


def _core_result_to_auto(result: FetchCoreResult, attempts: list[dict[str, Any]]) -> AutoFetchResult:
    metadata = dict(result.metadata)
    metadata.update(
        {
            "route": "generic-fallback",
            "selected_mode": result.mode,
            "attempt_chain": attempts,
            "strategy": "auto-fallback",
        }
    )
    return AutoFetchResult(route="generic-fallback", mode=result.mode, data=result.to_json_data(), metadata=metadata)


def fetch_auto(
    *,
    url: str,
    no_special_route: bool = False,
    pattern: str | None = None,
    max_bytes: int = 2 * 1024 * 1024,
    timeout: float = 30,
    proxy_url: str | None = None,
    fetcher: Callable[..., FetchCoreResult] = fetch_by_mode,
) -> AutoFetchResult:
    """Fetch a URL through special-route dispatch or generic fallback."""

    route = None if no_special_route else detect_special_route(url)
    if route and pattern:
        message = (
            f"[route] This URL uses special route: {route.name}.\n"
            "[pattern] --pattern is not supported for special routes.\n"
            "Suggestion: use --no-special-route or an explicit generic command such as "
            f"`web-fetch readable {url} --pattern ...`."
        )
        raise AutoFetchError("pattern_not_supported", message, retryable=False, exit_code=2, metadata={"route": route.name, "suggestion": "use --no-special-route or an explicit generic command"})

    if route:
        return _site_payload_to_result(route, fetch_site(route.command, url=url, proxy_url=proxy_url, timeout=timeout))

    attempts: list[dict[str, Any]] = []
    last_error: FetchCoreError | None = None
    for mode in GENERIC_FALLBACK_CHAIN:
        try:
            result = fetcher(mode, url=url, max_bytes=max_bytes, timeout=timeout, proxy_url=proxy_url)
        except FetchCoreError as exc:
            last_error = exc
            attempts.append({"mode": mode, "ok": False, "code": exc.code, "message": exc.message, "retryable": exc.retryable})
            continue

        problem = _quality_problem(result)
        if problem is None:
            attempts.append({"mode": mode, "ok": True, "selected": True})
            return _core_result_to_auto(result, attempts)
        attempts.append({"mode": mode, "ok": True, "selected": False, "fallback_reason": problem})

    chain = " -> ".join(item["mode"] for item in attempts) or "direct -> readable -> browser -> stealth"
    if last_error:
        tail = f"last error from {attempts[-1]['mode']}: [{last_error.code}] {last_error.message}"
        retryable = last_error.retryable
        code = last_error.code
    else:
        tail = "all modes returned low-quality or non-text content"
        retryable = False
        code = "extraction_failed"
    raise AutoFetchError(code, f"auto fallback failed after attempts: {chain}; {tail}", retryable=retryable, exit_code=1, metadata={"attempt_chain": attempts, "route": "generic-fallback"})
