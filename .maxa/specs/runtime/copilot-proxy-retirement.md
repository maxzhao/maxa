---
title: Copilot Proxy 退役边界
created: 2026-06-28
updated: 2026-10-09
type: source
doc_role: tombstone
authority: accepted
status: superseded
superseded_by: runtime/plugin-entrypoints.md
removed_at: 2026-09-12
capability: copilot-proxy-and-quota-control
sources:
  - lua/plugins/ai.lua
  - lua/util/newapi-quota/
  - lua/util/sub2api-quota/
confidence: high
review:
  human: passed
  evidence: user-declared-stable-spec-review
---

### Removed behavior

These Neovim-local capabilities are permanently retired: SHALL NOT restore, register, compatibility-map or expose as current downstream capabilities. This tombstone grants no availability:

- `lua/util/copilot-proxy/` local HTTP reverse proxy；
- Copilot account-file scanning/pooling、individual/business routing、round-robin/failover；
- BYPASS/CHARGE/REJECT request transformation 和 Premium Request local accounting；
- `:CopilotProxy` commands、lualine status、`vim.g.copilot_proxy`；
- LiteLLM、localllm、Copilot-name recovery、Agent Loop、`pause_loop`；
- 旧 `/v1/*` local Copilot forwarding/auth surface。

### Current owners

- HTTP gateway construction、`backend.provider|protocol|api_root`、Anthropic/OpenAI protocol dispatch、quota normalization and adapter-owned proxy metadata：[Plugin entrypoints](./plugin-entrypoints.md)。
- Repository-owned HTTP runtime and removed adapter boundaries：[Maxa AI](./maxa-ai.md)。
- Active provider quota/status helpers：`lua/util/newapi-quota/`、`lua/util/sub2api-quota/` and `maxa.session.status.billing`。

Active quota helpers SHALL expose bounded status only and SHALL never leak credentials。Gateway `proxy=true|false` is explicit adapter metadata；old Copilot adapter names/account types SHALL not influence routing。

### Validation

- Recorded evidence：removed source/runtime/plugin/lock identities absent and active gateway/quota owners present。Retirement source/runtime identity checks：`passed` for the recorded scope；removed endpoint/account functionality is not an active validation surface。
- User specification review：passed。
