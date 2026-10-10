"""Adapter for the vendored open-websearch runtime.

This module keeps the Python `web-fetch` CLI as the single user-facing entrypoint
while delegating search/web/article extraction to the vendored Node runtime.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

from schema import failure, success

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "scripts" / "open_websearch_bridge.mjs"
VENDOR = ROOT / "vendor" / "open-websearch"


OPEN_WEBSEARCH_MODES = {
    "search",
    "fetch-web",
    "fetch-github-readme",
    "fetch-csdn",
    "fetch-juejin",
    "fetch-linuxdo",
}


def _base_metadata(extra: dict[str, Any] | None = None) -> dict[str, Any]:
    metadata: dict[str, Any] = {"source": "open-websearch"}
    if extra:
        metadata.update(extra)
    return metadata


def _env(proxy_url: str | None = None, default_search_engine: str | None = None, search_mode: str | None = None) -> dict[str, str]:
    env = os.environ.copy()
    env.setdefault("DEFAULT_SEARCH_ENGINE", default_search_engine or "duckduckgo")
    if default_search_engine:
        env["DEFAULT_SEARCH_ENGINE"] = default_search_engine
    if search_mode:
        env["SEARCH_MODE"] = search_mode
    effective_proxy = proxy_url or env.get("PROXY_URL") or env.get("HTTPS_PROXY") or env.get("HTTP_PROXY")
    if effective_proxy:
        env["USE_PROXY"] = "true"
        env["PROXY_URL"] = effective_proxy
    return env


def _map_error_code(code: str | None, message: str) -> str:
    raw = (code or "").strip()
    if raw in {
        "timeout",
        "network_error",
        "invalid_arguments",
        "unsupported_engine",
        "extraction_failed",
        "dependency_missing",
        "not_found",
    }:
        return raw
    lowered = message.lower()
    if "unsupported search engine" in lowered:
        return "unsupported_engine"
    if any(token in lowered for token in ("invalid", "missing", "required", "must be", "cannot be empty")):
        return "invalid_arguments"
    if "timeout" in lowered or "timed out" in lowered:
        return "timeout"
    if "status code 404" in lowered or "not found" in lowered:
        return "not_found"
    if any(token in lowered for token in ("network", "fetch failed", "econn", "enotfound", "socket")):
        return "network_error"
    if any(token in lowered for token in ("cannot find package", "module not found", "err_module_not_found")):
        return "dependency_missing"
    return "extraction_failed"


def _call_bridge(payload: dict[str, Any], *, timeout: float = 60, proxy_url: str | None = None) -> dict[str, Any]:
    mode = str(payload.get("mode") or "unknown")
    if not BRIDGE.exists() or not VENDOR.exists():
        return failure(
            mode,
            "dependency_missing",
            "Vendored open-websearch runtime is missing",
            retryable=False,
            metadata=_base_metadata(),
        )

    try:
        completed = subprocess.run(
            ["node", str(BRIDGE), json.dumps(payload, ensure_ascii=False, separators=(",", ":"))],
            cwd=str(ROOT),
            env=_env(
                proxy_url=proxy_url,
                default_search_engine=payload.get("defaultSearchEngine"),
                search_mode=payload.get("searchMode"),
            ),
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        return failure(
            mode,
            "dependency_missing",
            "Node.js executable not found; open-websearch requires node",
            retryable=False,
            metadata=_base_metadata(),
        )
    except subprocess.TimeoutExpired:
        return failure(
            mode,
            "timeout",
            f"open-websearch command timed out after {timeout:g}s",
            retryable=True,
            metadata=_base_metadata({"timeout_seconds": timeout}),
        )

    stdout = completed.stdout.strip()
    if not stdout:
        message = completed.stderr.strip() or "open-websearch produced no JSON output"
        return failure(mode, "extraction_failed", message, retryable=False, metadata=_base_metadata({"exit_code": completed.returncode}))

    try:
        raw = json.loads(stdout.splitlines()[-1])
    except json.JSONDecodeError as exc:
        return failure(
            mode,
            "extraction_failed",
            f"Failed to parse open-websearch JSON output: {exc}",
            retryable=False,
            metadata=_base_metadata({"exit_code": completed.returncode, "stderr": completed.stderr.strip()}),
        )

    metadata = _base_metadata(raw.get("metadata") if isinstance(raw.get("metadata"), dict) else {})
    metadata["exit_code"] = completed.returncode
    if completed.stderr.strip():
        metadata["stderr"] = completed.stderr.strip()[-1000:]

    if raw.get("status") == "ok":
        return success(mode, raw.get("data") or {}, metadata)

    error = raw.get("error") if isinstance(raw.get("error"), dict) else {}
    message = str(error.get("message") or "open-websearch failed")
    code = _map_error_code(error.get("code"), message)
    retryable = bool(error.get("retryable")) or code in {"timeout", "network_error"}
    return failure(mode, code, message, retryable=retryable, metadata=metadata)


def search(
    *,
    query: str,
    engine: str | None = None,
    engines: str | None = None,
    limit: int = 10,
    search_mode: str | None = None,
    proxy_url: str | None = None,
    timeout: float = 60,
) -> dict[str, Any]:
    if engines:
        engine_list = [item.strip() for item in engines.split(",") if item.strip()]
    else:
        engine_list = []
    return _call_bridge(
        {
            "mode": "search",
            "query": query,
            "engine": engine,
            "engines": engine_list,
            "limit": limit,
            "searchMode": search_mode,
            "defaultSearchEngine": engine or os.environ.get("DEFAULT_SEARCH_ENGINE") or "duckduckgo",
        },
        timeout=timeout,
        proxy_url=proxy_url,
    )


def fetch_web(
    *,
    url: str,
    max_chars: int = 30000,
    readability: bool = False,
    include_links: bool = False,
    proxy_url: str | None = None,
    timeout: float = 60,
) -> dict[str, Any]:
    return _call_bridge(
        {
            "mode": "fetch-web",
            "url": url,
            "maxChars": max_chars,
            "readability": readability,
            "includeLinks": include_links,
        },
        timeout=timeout,
        proxy_url=proxy_url,
    )


def fetch_site(mode: str, *, url: str, proxy_url: str | None = None, timeout: float = 60) -> dict[str, Any]:
    return _call_bridge({"mode": mode, "url": url}, timeout=timeout, proxy_url=proxy_url)
