---
title: Session 基础能力规格入口
created: 2026-10-11
updated: 2026-10-14
type: index
status: active
---

> **TLDR**: Session 拥有会话查询、显式 transfer、trace export 与压缩工具；宿主 history/storage 和全局压缩授权仍是 Runtime owner。

1. [Session tools](./session-tools.md) — composite load、bounded query/probe/summary/stats、transfer、trace 和可视化导出。
2. [Session compression](./session-compression.md) — instructions-only self、增量 `/collapse`、precise/range、planner/apply、兼容前缀、持久化及 trace archives。

压缩前的显式信号、单次授权和禁止自主压缩仍按 Runtime 生效；目录归类不弱化门禁。历史存储/UI、token 决策/预算和 Vault visibility 保留各自既有 owner。
