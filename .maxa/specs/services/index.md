---
title: Services 稳定规格索引
created: 2026-09-15
updated: 2026-09-30
type: index
status: active
tags: [specs/services, status/active]
sources:
  - .maxa/specs/services/telegram-bridge.md
  - .maxa/specs/services/request-dump-proxy.md
confidence: high
---

> **TLDR**: 本模块路由独立本地/外部服务规格；每项服务由自己的 package、协议、状态和验证边界负责。

## Stable Service Specs

- [[specs/services/telegram-bridge|Telegram Bridge Service]] — Telegram single-consumer transport、exact Chat session-topic routing、notify-only idle input、builtin `ask` 与跨渠道终态仲裁；旧会话绑定已退休。
- [[specs/services/request-dump-proxy|Request Dump Proxy Service]] — 本地 HTTP/SSE 诊断代理、脱敏 request/response artifacts 与 forwarding failure 边界。

## Boundary

服务规格拥有协议、持久状态、授权和运行验证。Chat builtin 与 session UI 行为由对应 runtime 稳定规格拥有。
