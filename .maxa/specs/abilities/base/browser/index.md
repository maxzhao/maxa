---
title: Browser 基础能力规格入口
created: 2026-09-15
updated: 2026-10-11
type: index
doc_role: index
status: active
sources: [specs/abilities/base/browser/browser.md]
---

> **TLDR**: Browser 是同名复合 Ability/MCP；本模块拥有连接与实际观察/交互，不合并独立 QA/E2E 工作流。

- [Browser MCP](./browser.md) — Chromium/CDP/Tauri/managed-browser connection modes、snapshot refs、diff、IPC 与 disconnect/ownership。

Request Dump Proxy 是独立诊断服务，不是 MCP server；其协议与状态由服务 owner 拥有。browser-dogfood 与 browser-e2e 分别拥有探索式 QA 和授权测试编写。
