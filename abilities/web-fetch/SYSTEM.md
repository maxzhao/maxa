---
slot: tool_usage
priority: 80
---

#### Web Search And Extraction Protocol

Purpose: route web search, fetch, and content extraction through supported `web-fetch` workflow.

Rules:

- When a task requires web search, URL fetch, or content extraction, load `web-fetch` before choosing a fetch mode.
- Use `run` with a nonblank `title`, `scope="tool"`, `command="@web-fetch:/bin/web-fetch"`, and literal array `args`, not a shell command. For a known URL, start with `["auto", "<url>", "--format", "markdown"]`; if it fails, follow the Ability decision tree.
- For search, use args `["search", "<query>", "--json"]`, then fetch selected candidate URLs through the same cataloged entrypoint. Substitute actual URLs/queries before calling.
- Use the Ability decision tree to select browser escalation from fetch results; keep simple web fetch or extraction on `web-fetch`.
- Do not call deprecated Web MCP servers directly: `fetch`, `scrapling-fetch`, or `open-websearch`.
