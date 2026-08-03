---
title: CodeCompanion HTTP transport 模块索引
created: 2026-08-01
updated: 2026-08-01
type: index
tags: [codecompanion, reverse-spec, http-transport, v18.7.0]
sources:
  - ../../baseline.md
  - ../../evidence-map.md
  - spec.md
confidence: medium
authority: draft
status: partial
---

> **TLDR**: 本目录保存 CodeCompanion.nvim `558518f8d78a44198cd428f6bf8bf48bfa38d76d` (`v18.7.0`) 的 HTTP adapter resolution、provider request/response mapping 与 curl transport 反推；不是目标运行时规范。

- [[spec|HTTP transport reverse specification]] — `authority: draft`, `status: partial`。
- Baseline: [[../../baseline|反推基线]]。
- Evidence map: [[../../evidence-map|证据地图]]。

## Boundary

仅记录 pinned baseline 的 upstream source/tests/docs。不得把 SuperMax 的 `lua/util/**`、local extensions、downstream patches、latest-upstream commit 或独立运行时设计当作本模块行为。Provider-specific facts are separated from generic transport facts.

## Coverage

- 已覆盖：配置/解析、schema/mapping、handler compatibility、generic async/sync transport、curl options、events、stream error gate、adapter/provider inventory、tests/docs inventory、失败配置、并发、碎片化流边界、callback race/异常边界、retry/proxy/TLS 静态边界与验证缺口。

- 仍为 `partial`：全部 provider 的逐字段行为链、真实 upstream test execution、cancellation/cleanup races、少数 provider-specific error/usage contracts。
- 本轮收束了高价值静态缺口：碎片化流边界、callback race/异常边界、retry/proxy/TLS 时序边界及代表性 fixture 的静态覆盖；上述未执行部分仍明确标记为 source-only unknown。
