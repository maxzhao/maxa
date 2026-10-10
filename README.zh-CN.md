# Maxa

**Neovim 中的 AI 工作环境。**

[English](README.md) · **简体中文** · [视频](https://www.bilibili.com/video/BV1LXpm6QEDw/)

[![点击在 B 站观看视频](https://i2.hdslb.com/bfs/archive/ac018a410a1352cc57db2eef539a5dbf09769011.jpg@308w_174h)](https://www.bilibili.com/video/BV1LXpm6QEDw/)

_临时占位视频：Rick Astley《Never Gonna Give You Up》官方 MV。点击封面前往 B 站播放。_

Maxa 这个名字来自 _Max's Agent_。Maxa 将 AI 对话、代码补全、功能实施和项目维护整合到同一个 Neovim 环境中。

Agent 可以读代码、改文件、执行命令、使用外部工具、把独立工作交给子代理，并在长任务中保留上下文。点子、规格、进度和知识则通过项目本地文件留在项目里。

Maxa 主要是为习惯在命令行下工作的人准备的，尤其是已经把 Neovim 当作主要开发工具的程序开发人员。它以 LazyVim 作为编辑器基础，自行维护 Agent runtime，并集成 MCP 支持。

## 为什么做这个项目

在 2025 年下半年开始尝试 Vibe Coding 之前，Neovim 就一直是我的主要开发环境。我先后使用过 Copilot、CodeCompanion，从 AI 补全，到对话，再到让 Agent 直接参与项目开发。

随着它越来越多地用于实际工作，我也不断增加自己需要的功能：更好的会话管理、更多工具、更长的工作流程，以及保留项目知识的方法。后来，围绕上游接口维护这些扩展，逐渐占用了太多精力。

最终，我选择把与自己需求一致的部分吸收进来，在 Maxa 中维护核心 runtime，让 Agent 和工作流可以一起发展。Maxa 受益于这些上游工作，也受益于 MCPHub 和整个 Neovim 生态。

对我来说，这也是借助 AI 打造自己 IDE 的过程。我希望在开发项目的同时，也能把工作环境改造成自己喜欢的样子。

## Maxa 的能力

### 在编辑器的 Chat 中工作

Chat 是 Maxa 的主要入口，支持将选中的代码、文件、buffer、终端输出、Quickfix、符号，以及模型支持的图片带入会话。Agent 可以搜索项目、修改文件、执行命令、调用已加载的工具，工作过程直接呈现在编辑器中。

Maxa 分别展示工具输出和推理内容，提供中断请求、在当前操作结束后停止等控制，并支持查看会话状态与上下文使用情况。独立的工具调用可以并行执行，后台工作也可以查询和取消。

例如：

> 找到这个报错的原因，做最小修复，并运行相关检查。

### 会话变长后，仍然能继续工作

Maxa 会保存会话，让长任务能够接着之前的进度继续工作。历史管理提供浏览、搜索、恢复，以及主代理和子代理的会话树。

会话工具支持复制持久会话、创建临时 scratch 分支、保存或合回新增消息，以及回退和重新发送输入。上下文监控、摘要、压缩和恢复机制，帮助会话变长或请求失败后的工作续接。需要时，还可以开启 lineage trace，导出为 Obsidian Canvas 和 Markdown。

回退会话调整的是对话历史，已经发生的文件修改和命令效果会保留在工作环境中。请单独检查这些变化，通过版本控制管理文件修改，并按需处理命令产生的效果。

### 分配独立工作，也听取不同观点

Maxa 可以把独立、有明确交付物的工作委托给子代理，支持启动新子代理、从当前上下文 fork，以及恢复已有子代理会话，并为它们准备任务上下文和工具限制。

多代理讨论可以联合不同模型，或使用 The Agency 中的专家角色，比较设计、评审或点子的不同观点。讨论帮助形成方案，实施与验证再各自推进。

### 扩展 AI，也改造编辑器本身

Maxa 把扩展组织成 **Ability（能力）**。一个 Ability 可以结合指令、参考资料、模板、脚本、MCP 工具和生命周期 Hook。Agent 在需要时加载相应能力，让会话上下文集中在当前工作上。

能力包使用 `SKILL.md`，并可通过 `ABILITY.yaml` 增加 Maxa 元数据。它们既可以是全局能力，也可以是项目本地能力；项目能够控制能力的可用性。每个 Chat 通过显式加载 Ability 获得相应 MCP 工具的调用授权。

Agent 可以寻找已有能力，检查它们，再协助引入和验证，也可以修改 Maxa 和编辑器配置。Neovim 能力支持在当前编辑器中执行 Lua，并通过 LSP 查询符号、定义、引用、悬停信息、诊断和一层调用关系。

标准 Skill 文件提供可移植的指令格式，Maxa runtime 则提供工具执行、Hook 和能力寻址功能。Lua 直接在当前 Neovim 进程中执行，可以访问编辑器状态及当前用户权限范围内的文件和命令。

### 把点子、任务、规格和知识留在项目里

Maxa 使用项目本地的 `.maxa/` 目录，让工作能够恢复，让知识能够被找到：

- **TaskAdmin** 保存实施计划、当前 TODO、标签、依赖和完成证据。
- **SpecAdmin** 将行为规格、变更提案与实施进度分开维护，并在提升正式规格前检查代码与规格是否收敛。
- **ProjectAdmin** 初始化、维护项目结构和项目自己的知识 Vault。
- **Weave** 为 Agent 提供紧凑的主题与概念导航，同时保留原始来源。
- **Self Improvement** 捕获经过确认、可复用的经验，留待后续 review。
- **Git Workspace** 提供可选的本地 Git worktree 开发方式，以及任务与工作区检查。每个 worktree 拥有独立的文件和分支，共用同一用户环境。

Maxa 的 Obsidian 集成为阅读和维护项目知识提供了另一种方式，包括受保护的 Vault 操作、链接与属性、Bases、Canvas、反馈处理，以及可选的 Syncthing 配置。知识属于各自的项目，通过明确的捕获和 review 流程沉淀。

发布仓库还包含六个 Obsidian 插件，分别用于文档块反馈、语义图谱标签、文档翻译、TODOseq 看板、未解析链接保护，以及可视化 Syncthing 冲突处理。

### 处理媒体、网页和外部应用

配置好相应后端后，Maxa 可以生成和编辑图片、分析本地图片、合成语音，以及生成视频。GenAI 能力也提供参考图、多轮编辑、提示词设计和可复用视觉模板等工作流。

查资料时，`web-fetch` 负责搜索、下载、正文提取和动态页面抓取。Browser 集成可以操作 Chromium/CDP 页面及支持的 Tauri WebView，检查网络与应用状态，并使用 Tauri IPC。视觉检查使用真实渲染的浏览器或 WebView，轻量后端则专注于 JavaScript、DOM 和网络提取。配置的 MarkItDown MCP 服务提供文档转 Markdown 的能力。

Maxa 随附的 WinGUI bridge 支持从 WSL 执行 Windows 命令、启动 GUI 应用。准备好 Windows 侧 WinCtl Server 后，还可以进行桌面截图、鼠标键盘输入、窗口、剪贴板和虚拟桌面操作。

### 离开键盘后，仍然参与工作

当 Agent 需要用户做决定时，Maxa 会在 Chat 中提问；配置好 Telegram 后，也会发送到对应会话的 topic。两边的首个有效答复生效。Telegram 还可以接收完成通知，并在对应 Chat 仍然打开、开启监听且空闲时，继续输入消息。

Maxa 支持通过 Telegram 输入文件或文字，也可以用 `/upload` 打开浏览器上传页面。这个页面支持文件上传、URL 导入，以及浏览器允许的拍照、录音和录屏。提交后，文件会以项目路径插入 Chat。跨设备访问需要配置主机名、TLS 和网络可达性，默认仅支持本机访问。

通过 SSH 可以从多个设备进入同一套工作环境。

## 把它变成自己的工具

我更推荐的使用方式是：**Fork 这个仓库，然后维护你自己的版本。**

Fork 给个人需求留下了生长的空间。你可以把自己的配置和特殊修改留在那里，让 AI 协助理解、修改和验证。

对于 Agent 能力，我更倾向于经过检查、能够在自己仓库里维护的代码。AI 可以协助检查兼容性与安全风险，通过代码审阅和验证来决定如何引入与更新。编辑器本身建立在常规的 Neovim 插件依赖与集成之上。

合入 Maxa 上游更新时，也需要结合本地修改检查。Agent 可以协助解决冲突，并通过相关检查验证合并后的行为。

## 开始使用

### 当前提供的安装路径

随附的安装脚本面向 **WSL2 + Ubuntu 24.04**，要求具有 sudo 权限的普通用户，支持 **x86_64 或 aarch64**。Maxa 要求 **Neovim 0.11+**。

**部署前请备份已有 Neovim 配置，并将仓库克隆到新的目录，保留当前配置。** 安装脚本会下载依赖、通过 sudo 安装系统软件，并在 systemd 可用时配置 Obsidian 和 Syncthing 用户服务。执行前请阅读 [`install.sh`](install.sh)。

1. 在 GitHub Fork 本仓库，将自己的 Fork 克隆到可用的 `~/.config/nvim` 目录。把 `<your-fork-url>` 替换成自己的仓库 URL：

   ```bash
   git clone <your-fork-url> ~/.config/nvim
   ```

2. 在目标 WSL 环境中安装依赖：

   ```bash
   bash ~/.config/nvim/install.sh
   ```

   下载默认直连。如果本次安装需要代理，显式传入 `--proxy http://<host>:<port>`，由这个参数选择安装脚本的下载代理。

3. 对于新克隆的仓库，从公开示例创建启动配置：

   ```bash
   cp ~/.config/nvim/lua/plugins/ai.example ~/.config/nvim/lua/plugins/ai.lua
   ```

   **已有安装应保留当前 `ai.lua`，并按需要调整。** 它是你本地、被 Git 忽略的启动配置，与依赖安装分开维护。

4. 在 `~/.config/nvim/.env` 中配置凭据，并参考 [`lua/plugins/ai.example`](lua/plugins/ai.example) 调整 Provider、模型和 Preset。安装脚本保留已有 `.env`，不存在时从 `.env.example` 初始化。示例使用 DeepSeek，并读取 `DEEPSEEK_API_KEY`。不要把真实凭据提交到仓库。

5. 启动 Neovim，等待编辑器插件安装。用 `:Maxa` 打开 Chat，`:MaxaHistory` 浏览历史会话，`:MaxaConfig` 管理项目设置。可以用 `:checkhealth maxa` 检查核心编辑器依赖。

依赖安装完成后，再配置想使用的集成：通过 ProjectAdmin 初始化项目的 `.maxa/`、注册 Vault 和同步目录、选择媒体 Provider，或设置 Windows 和 Telegram 服务。

如果你已经使用 LazyVim，可以结合现有配置审阅 runtime 和启动示例，整合想使用的部分。

### 几个常用入口

| 入口                           | 用途                               |
| ------------------------------ | ---------------------------------- |
| `:Maxa`                        | 打开 Chat                          |
| `:Maxa Add`                    | 把可视选中的代码加入 Chat          |
| `:MaxaHistory`                 | 浏览保存的会话                     |
| `:MaxaConfig`                  | 管理项目能力、默认服务和 MCP 连接  |
| `:MaxaTranslateBuffer`         | 翻译支持的项目文档，并复用缓存     |
| `/load`、`/pick_ability`       | 加载或选择能力                     |
| `/fork`、`/scratch`、`/rewind` | 创建分支或回退会话                 |
| `/upload`、`/tg_upload`        | 通过已配置的输入方式加入文件或文字 |

## 随附的 Abilities

以下是本次发布的 Skill 能力包。链接指向各自的中文用户指南，其中提供了用自然语言描述目标的示例。

| 类别             | 能力                                                                                                                                                                                                                                                                          |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Agent 与会话     | [SubAgent](abilities/subagent/USER_GUIDE.md)、[Agency NEXUS](abilities/agency-nexus/USER_GUIDE.md)、[Session](abilities/session/USER_GUIDE.md)                                                                                                                                |
| 项目工作流       | [ProjectAdmin](abilities/project-admin/USER_GUIDE.md)、[TaskAdmin](abilities/task-admin/USER_GUIDE.md)、[SpecAdmin](abilities/spec-admin/USER_GUIDE.md)、[Git Workspace](abilities/git-workspace/USER_GUIDE.md)、[Self Improvement](abilities/self-improvement/USER_GUIDE.md) |
| 能力建设         | [Ability Creator](abilities/ability-creator/USER_GUIDE.md)、[MCP Creator](abilities/mcp-creator/USER_GUIDE.md)、[Prompt Engineering](abilities/prompt-engineering/USER_GUIDE.md)、[Resource Scout](abilities/resource-scout/USER_GUIDE.md)                                    |
| 浏览器与外部环境 | [Browser](abilities/browser/USER_GUIDE.md)、[Web Fetch](abilities/web-fetch/USER_GUIDE.md)、[Neovim](abilities/neovim/USER_GUIDE.md)、[WSL Windows](abilities/wsl-windows/USER_GUIDE.md)、[WinCtl](abilities/winctl/USER_GUIDE.md)                                            |
| 生成式媒体       | [GenAI](abilities/genai/USER_GUIDE.md)                                                                                                                                                                                                                                        |

你也可以通过配置纯 MCP 能力继续扩展这份能力集合。

## 发布版与可选服务

Maxa 的发布仓库提供可复用的 runtime 及其集成。你可以参考公开启动示例，在自己的 `ai.lua` 中维护配置。

配置 Bridge、Bot 和授权用户后，即可启用 Telegram。媒体工具需要选择合适的 Provider，浏览器与文档工具需要准备相应依赖。WinCtl 使用另行准备的 Windows 服务端。想使用 Obsidian/Syncthing 或跨设备上传时，再配置项目注册和访问方式。

**Agent 使用当前用户的操作系统权限执行工作**，可以访问文件、执行命令和操作应用。Ability 加载负责会话内的能力授权，工具和 Lua 直接在现有编辑器与用户环境中运行。请检查第三方代码和修改，保护凭据，并为重要工作保留备份与版本控制。遇到登录、付费或交互式验证码时，需要你参与完成相应步骤。

## 许可证与致谢

Maxa 以 [Apache-2.0](LICENSE) 分发。吸收的第三方代码仍适用各自的上游许可证；仓库保留的许可证文本包括 [CodeCompanion.nvim](LICENSES/codecompanion.nvim-Apache-2.0.txt) 和 [MCPHub.nvim](LICENSES/mcphub.nvim-MIT.txt)。

感谢 [LazyVim](https://github.com/LazyVim/LazyVim)、[CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim)、[MCPHub.nvim](https://github.com/ravitemer/mcphub.nvim)，以及各项集成工具背后的项目。他们的工作让 Maxa 成为可能。

---

[English](README.md) · **简体中文** · [视频](https://www.bilibili.com/video/BV1GJ411x7h7/)
