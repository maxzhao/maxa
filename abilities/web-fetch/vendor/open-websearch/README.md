# Vendored open-websearch

This directory contains a vendored snapshot of the `open-websearch` npm package used by the `web-fetch` skill.

- Package: `open-websearch`
- Version: `2.1.8`
- Source: npm registry package tarball fetched via `npm pack open-websearch@latest` during TaskAdmin 19.4
- Purpose: provide search, general web fetch, GitHub README fetch, CSDN/Juejin/Linux.do article fetch behind the unified `abilities/web-fetch/bin/web-fetch` CLI

The unified CLI does **not** expose this package as an MCP server and does **not** start a stdio MCP lifecycle. Instead:

1. `abilities/web-fetch/scripts/web_fetch_cli.py` parses the public `web-fetch` command.
2. `abilities/web-fetch/scripts/open_websearch_adapter.py` invokes the Node bridge.
3. `abilities/web-fetch/scripts/open_websearch_bridge.mjs` imports this vendored runtime and calls `createOpenWebSearchRuntime().services.*` directly.
4. The result is wrapped into the stable `web-fetch` JSON envelope.

Dependency note: the published npm package includes compiled `build/` files but not `node_modules`. Runtime Node dependencies must be installed in this directory (`npm install --omit=dev`) in the local environment, or the adapter returns a `dependency_missing` envelope. `node_modules/` is local runtime state and is intentionally excluded from Git.
