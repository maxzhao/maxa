---
title: Wiki Log
created: 2026-08-03
updated: 2026-08-04
type: log
---

# Wiki Log

## 2026-08-04 — 官方协议参考入库

- 新增 `protocols/` 子目录，抓取并整理 maxa 阶段1 四协议官方参考：
  - Context7 官方来源：OpenAI API reference（developers.openai.com）、openai-openapi（GitHub）、anthropic-sdk-typescript（GitHub）、ai.google.dev Gemini API
  - DeepSeek 官方中文文档三份（chat-completions / responses / anthropic-api），经 `tr -d '\0'` 清理 web-fetch 抓取引入的 NUL 字节
  - 新增 `protocols/index.md`、`protocols/deepseek.md` 概览（端点、模型 deepseek-v4-flash、测试 key 约定 DEEPSEEK_TEST_KEY）
- 更新本索引指向 `protocols/`。

## 2026-08-03 — Vault initialized

- Created `wiki/` as the agent-maintained synthesis layer during ProjectAdmin sync-based `init` of `.supermax/`.
