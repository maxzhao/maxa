# vendored scrapling-fetch-mcp

This directory contains the local vendored source for `scrapling-fetch-mcp` used by the
`web-fetch dynamic` and `web-fetch pattern` CLI subcommands.

Source snapshot:
- Package: `scrapling-fetch-mcp`
- Version: see `METADATA` (currently 0.2.0)
- Local source: uvx tool cache at `~/.local/share/uv/tools/scrapling-fetch-mcp/...`

The unified `web-fetch` CLI does **not** start the MCP server and does **not** speak
stdio JSON-RPC. It imports/calls equivalent functions directly through the adapter in
`abilities/web-fetch/scripts/dynamic_fetch_adapter.py`.

Runtime dependencies for real dynamic browsing are still external Python packages such
as `scrapling`, `beautifulsoup4`, `lxml`, and `markdownify`. When they are unavailable,
the adapter returns a stable JSON error envelope with `dependency_missing` instead of
printing logs into stdout.
