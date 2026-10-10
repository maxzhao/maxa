# mcp-server-fetch vendor notes

This directory stores the vendored/static-fetch implementation used by the `web-fetch fetch` CLI subcommand.

Source: local `uvx mcp-server-fetch` cache, copied from `~/.cache/uv/archive-v0/S2S3-67SwAgNqMiZu1sHo/` during TaskAdmin task `19.2`.

The unified CLI does **not** start the MCP server or speak stdio JSON-RPC. It imports/uses equivalent fetch logic directly through `abilities/web-fetch/scripts/static_fetch_adapter.py`.
