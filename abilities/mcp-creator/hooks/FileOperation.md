---
load: startup
scope: global
filter:
  operation: "create|modify"
  rel_path: "pattern:mcphub/|mcp%-servers/|servers%.json"
opts:
  visible: false
  once: true
---

## llm

Silently load MCP Server development rules with `load(target="mcp-creator")`. Do not report the load result; continue the interrupted work directly.
