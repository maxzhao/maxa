---
title: Request Dump Proxy Service 稳定规格
created: 2026-06-28
updated: 2026-09-15
type: source
doc_role: spec
authority: stable
status: stable
capability: request-dump-proxy-service
validation:
  specification: passed
  automated: partial
  live: not-run
  human: passed
sources:
  - tools/request-dump-proxy/pyproject.toml
  - tools/request-dump-proxy/src/request_dump_proxy/__main__.py
  - tools/request-dump-proxy/src/request_dump_proxy/main.py
confidence: medium
---

# Request Dump Proxy Service

## Purpose And Ownership

`tools/request-dump-proxy/` owns a uv-managed local HTTP/SSE debugging service forwarding to one configured upstream and storing bounded, redacted per-request comparison artifacts; raw payloads stay out of Agent context. It is not an MCP server, production reverse proxy, durable knowledge store or shared Chat state. HTTPS CONNECT tunneling, browser-wide proxy semantics, retention/rotation and production availability are out of scope.

## Public Behavior

### Requirement: Service runs through its uv project

The service SHALL use the `tools/request-dump-proxy` uv project and package entrypoint. CLI configuration SHALL include listen address, upstream URL, output directory (default `logs` relative to service cwd) and request preview limit. Invalid `--listen` syntax fails with an explicit `host:port` requirement; startup SHALL create a `ThreadingHTTPServer` listener.

### Requirement: Common HTTP methods are forwarded

The proxy SHALL accept GET, POST, PUT, PATCH, DELETE and OPTIONS, preserving method, body, relevant headers and upstream path while streaming the upstream response to the caller. Chunked request bodies follow the implementation's bounded forwarding/logging behavior.

### Requirement: Each request has an isolated local dump directory

Each handled request SHALL create a sanitized, isolated directory containing applicable `request.raw`, `response.raw`, summary metadata and the header/JSON/error artifacts below. Raw bodies can contain secrets: directories must remain local, access-controlled and uncommitted. Diagnostic output SHALL NOT be promoted automatically into prompts, specs, source control or shared knowledge.

### Requirement: Sensitive headers are redacted before JSON diagnostics

Before writing `request.headers.json` or `response.headers.json`, known sensitive header values, including authorization and proxy authorization, SHALL be replaced. Header-name redaction SHALL NOT be represented as body-secret sanitization; callers remain responsible for avoiding secrets in captured bodies.

### Requirement: JSON bodies receive bounded inspection artifacts

For request bodies decoding as JSON, the service SHALL write parsed/normalized diagnostics and a bounded request shape/key summary. Non-JSON bodies MAY produce raw bytes and bounded preview text but SHALL NOT produce fabricated parsed JSON.

### Requirement: Forwarding failures are observable

Upstream connection or forwarding exceptions SHALL write `proxy_error.json` and return a JSON error response with an error status, not a successful upstream response.

## Validation

Historical CLI help and package-local Python compilation passed after an initial root-relative compile command resolved the wrong `src`. Corrected commands, also rerun successfully on 2026-09-15 (`REQUEST_DUMP_PROXY_STATIC_OK`):

```bash
cd tools/request-dump-proxy
uv run --project . request-dump-proxy --help
uv run --project . python -m compileall src
```

Permanent coverage: CLI help and package-local Python compilation `passed`; automated request/response behavior `partial`; local upstream fixture and live service validation `not-run`; human specification review `passed`.

## Source Trace

Frontmatter `sources` lists the package, entrypoint and implementation, respectively.
