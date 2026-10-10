---
title: 基础能力规格与覆盖边界
created: 2026-10-11
updated: 2026-10-11
type: index
status: active
confidence: high
---

> **TLDR**: 18 项基础能力中，11 项有独立规格目录；其余 7 项标注现有相关 owner 或覆盖空白，不推导新的行为契约。

## 1. 执行环境与内容工具

| 能力 | 当前规格/覆盖 |
| --- | --- |
| `neovim` | 尚无独立规格；Lua 执行/只读 LSP 查询相关条款在运行时 `chat-builtins.md`。Godot 编辑器集成不是此能力本身。 |
| `wsl-windows` | 尚无独立规格；Windows command backend 相关条款在运行时 `chat-builtins.md`，不替代完整跨系统环境指导。 |
| `winctl` | 尚无独立规格；不补造桌面控制契约。 |
| [browser](./browser/index.md) | 同名复合 Ability/MCP；浏览器/CDP/Tauri 连接、观察、交互、reference/diff、IPC 与所有权清理。 |
| [web-fetch](./web-fetch/index.md) | 搜索、抓取、提取、失败决策树与条件 browser 升级；其 browser CLI mode 不等于加载 browser Ability。 |
| [genai](./genai/index.md) | 四个媒体接口及 image/audio/video wire；不拥有 Chat Responses 或 analyze hidden-child。 |

## 2. 能力工程

| 能力 | 当前规格/覆盖 |
| --- | --- |
| `prompt-engineering` | 尚无独立规格；共享 Prompt 文件 grammar/library 属于独立 Prompt 产物 owner，不等同提示工程方法。 |
| `ability-creator` | 尚无独立规格；当前包为 `abilities/ability-creator/`，通用 package/authoring 契约在运行时 `package-and-authoring.md`，现行能力标识为 ability-creator。 |
| [resource-scout](./resource-scout/index.md) | 采用前发现、评估与 ability-creator/mcp-creator handoff；不授予安装权限。 |
| [mcp-creator](./mcp-creator/index.md) | Native/External 维护、LLM-facing 契约、验证与 reload 边界。 |

## 3. 项目治理与执行

| 能力 | 当前规格/覆盖 |
| --- | --- |
| [project-admin](./project-admin/index.md) | 项目 Vault、知识治理、index/log、checkout 外部资格与分发。 |
| [git-workspace](./git-workspace/index.md) | 可选本地 worktree、未跟踪文件同步及 TaskAdmin binding preflight。 |
| [task-admin](./task-admin/index.md) | 单层任务状态/依赖/生命周期与只读 Browser UI。 |
| `spec-admin` | 尚无独立规格；TaskAdmin `core.md` 含单向 SpecAdmin 集成边界，不代表完整 SpecAdmin 契约。 |

## 4. 会话协作与反馈

| 能力 | 当前规格/覆盖 |
| --- | --- |
| [session](./session/index.md) | bounded query/transfer/trace 与显式授权压缩；Chat 存储与恢复属于运行时。 |
| [subagent](./subagent/index.md) | 有界委派、run/fork/resume/discussion/handoff 与取消。 |
| `agency-nexus` | 尚无独立规格；现有集成契约在 SubAgent `subagent-runtime.md`，角色与编排指导属于 `abilities/agency-nexus/`。不复制角色/讨论规则。 |
| [self-improvement](./self-improvement/index.md) | 项目 inbox 经验候选捕获及可选生命周期 hook。 |

分组是建议理解顺序，不建立额外加载、依赖或接受门槛。browser 的按需连接、Agency 的场景前置、原有 experimental/partial/failed/not-run 及不确定性保持不变。
