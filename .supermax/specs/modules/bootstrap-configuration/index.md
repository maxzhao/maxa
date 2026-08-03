---
module: bootstrap-configuration
authority: draft
status: partial
baseline_commit: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
baseline_version: v18.7.0
---

# Bootstrap / Configuration 模块

- 范围：插件 bootstrap、配置合并与归一化、公开命令/API、health check、入口注册副作用。
- 证据边界：仅使用 baseline `558518f8d78a44198cd428f6bf8bf48bfa38d76d`；未混入 latest-upstream 或 SuperMax downstream。
- 状态：`partial`。已补全 baseline `init.setup` 注册阶段、可观察 defaults 分组、公开 Lua API 参数/返回/失败边界、重复 setup 的静态异常边界及 bootstrap 静态验证；动态 setup/idempotency 测试仍不可用。

## 导航

- [[spec]] — 操作级反推规格
- [[../../index]] — CodeCompanion 反推总索引
