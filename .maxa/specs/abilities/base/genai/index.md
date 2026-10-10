---
title: GenAI 稳定规格入口
created: 2026-09-15
updated: 2026-10-10
type: index
status: stable
sources:
  - specs/abilities/base/genai/native-mcp.md
---

# GenAI

- [[specs/abilities/base/genai/native-mcp|GenAI Native MCP 与媒体工作流规格]] — adapter-owned media capabilities, four Native MCP tools, image/audio/video wire contracts and requested/actual image facts.
- [[specs/runtime/image-analysis|Image Analysis 运行时规格]] — the public `analyze` builtin used for visual inspection; GenAI does not own its hidden-child runtime.
- [[specs/runtime/openai-responses-adapter|OpenAI Responses Chat Adapter 规格]] — the independent Chat/LLM protocol owner; GenAI only owns its separate media `image_generation` driver.
