# wsl-windows 用户指南

本技能让 Agent 在 WSL2 + Windows 混合环境中执行 Windows 侧命令、启动 GUI/后台服务、处理路径、排查桥接问题，并协助配置或迁移 Windows + WSL 环境。你只需说明目标、项目位置、要运行的命令或错误现象。

## 什么时候使用

- “项目在 `/mnt/c/Projects/my-app`，请在 Windows 侧安装依赖并构建。”
- “这个命令必须用 Windows 环境运行，不要在 WSL 里跑。”
- “把 `/mnt/c/...` 转成 Windows 路径，并判断应该在哪侧执行。”
- “启动一个 Windows GUI 程序验证结果。”
- “这个命令要长期运行，请在 Windows 后台启动并告诉我怎么停止。”
- “Docker Desktop 在 Windows 正常，但 WSL 没有 `/var/run/docker.sock`，请诊断并修复。”

## Windows 侧 CLI 命令

适合 Windows Node/pnpm、Rust/MSVC、PowerShell、cmd、测试工具或构建工具。

示例：

- “在 Windows 侧执行 `pnpm install && pnpm build`，目录是 `/mnt/c/Projects/my-app`。”
- “用 PowerShell 检查这个 Windows 目录。”
- “在 Windows 侧运行 `cargo test`，因为项目依赖 Windows SDK。”
- “这个构建很慢，把超时设长一点。”
- “npm 脚本只能在 Windows 跑，请不要用 WSL 的 node_modules。”

## GUI 程序

适合打开 Windows 应用、安装器、浏览器、编辑器、测试程序或可视化验证工具。

示例：

- “在 Windows 上打开生成的 exe，让我确认界面。”
- “启动 Notepad 打开这个配置文件。”
- “用 Windows GUI 方式启动 Tauri 应用。”
- “打开资源管理器定位到构建产物目录。”
- “这个程序需要真实 Windows 桌面会话，请用 GUI 启动方式。”

## 后台服务

适合开发服务器、长期测试服务、本地 API、watch 模式等不会立即退出的命令。

示例：

- “在 Windows 后台启动 `pnpm dev`，项目在 `/mnt/c/Projects/my-app`。”
- “启动 Windows 后台 HTTP 服务，并告诉我如何停止。”
- “查看当前通过桥接系统启动的 Windows 进程。”
- “清理已经结束但还留在列表里的后台进程。”
- “终止刚才启动的 Windows 后台进程。”

## 路径和工作目录

Agent 会在 WSL 路径和 Windows 路径之间转换。最好说明项目在 `/mnt/c/...`、WSL 原生目录，还是 `C:\...`。

示例：

- “把 `/mnt/c/Projects/app` 转成 Windows 路径并作为 cwd。”
- “项目在 WSL 的 `/home/...`，判断能不能作为 Windows 命令 cwd。”
- “命令跑到了 `C:\Windows`，检查是不是 UNC 路径导致 cwd 失效。”
- “帮我决定这个命令应该在 WSL 侧还是 Windows 侧跑。”
- “把 `C:\Projects\app` 转成 WSL 可编辑路径。”

## 跨平台依赖、构建和测试

适合 Windows 项目、Tauri/桌面项目、MSVC/Rust 项目，以及 WSL 与 Windows 依赖目录不兼容的项目。

示例：

- “项目之前在 WSL 装过依赖，现在要 Windows 构建，请处理 node_modules 兼容问题。”
- “Windows 侧报 `ENOENT`，怀疑是 WSL pnpm 符号链接导致的。”
- “按‘哪侧运行，哪侧安装’原则重新安装依赖。”
- “在 Windows 侧安装依赖、构建、测试，并汇总结果。”
- “Rust 项目需要 Windows MSVC 工具链，请验证构建流程。”
- “构建很慢，判断是否需要给 Windows Defender 添加项目目录排除。”

## PowerShell、cmd 和编码

适合 Windows shell 特性、系统命令、Defender 设置、管道/重定向和乱码处理。

示例：

- “用 PowerShell 执行这个 Windows 系统配置命令。”
- “命令输出中文乱码，请用合适编码重试。”
- “用 `cmd /c` 运行这串带 `&&` 的命令。”
- “给 `C:\Projects\YourProject` 添加 Defender 排除以提升构建速度。”
- “Windows 命令里有管道和重定向，请按 Windows shell 规则执行。”

## Docker Desktop 与 WSL 集成修复

适合 Docker Desktop Engine、WSL 发行版集成、Linux Docker CLI、Unix socket，以及依赖 Docker 的 Workerd、Wrangler Containers 或项目 Container 测试故障。

示例：

- “Windows 的 Docker 可以用，但 WSL 的 `docker version` 连不上，请修复。”
- “检查 `/var/run/docker.sock` 为什么不存在或没有监听者。”
- “Workerd 报 `npipe`，请恢复 Linux Docker CLI 和 Unix socket，不要使用 Windows fallback。”
- “Docker Desktop 报 `Wsl/Service/0x8007274c` 或 `HCS_E_CONNECTION_TIMEOUT`，请按证据修复。”
- “先区分 WSL 挂载/Interop、Windows Docker Engine、发行版 integration proxy 分别是否正常。”
- “修复后运行项目已有的 Container 构建或测试，不要只跑 hello-world。”

Agent 会先验证 `/mnt/c` 与 Windows Interop，再分别检查 Windows Engine 和 WSL `/var/run/docker.sock`。如果 Windows 盘出现 `Input/output error` 或 Interop `Broken pipe`，会将其识别为 WSL 宿主通道故障，而不是 Docker 权限问题。涉及 `wsl --shutdown` 时会明确说明它会终止当前会话。

正常完成标准是 WSL 内同时满足：Linux Docker client、Linux Engine、`default` context、Unix socket `/_ping` 返回 `OK`，并通过最接近的项目 Docker/Container 验证。Windows `docker.exe` 能连接 Engine 不能单独证明修复完成。

如果 Docker Desktop 官方集成重启仍失败，Agent 可以根据当前安装版本的 Docker Desktop 日志评估临时 integration proxy；这只作为应急恢复，不能冒充持久修复，也不会删除 Docker 数据、重置 Desktop、卸载发行版或执行全局 prune。

## runwingui 桥接排查

适合 Windows 命令无法执行、超时、GUI 无法打开，或需要查看桥接状态。

示例：

- “检查 WSL 到 Windows 的 runwingui 桥接是否健康。”
- “列出当前通过桥接系统运行的 Windows 进程。”
- “重启 runwingui server 后再重试刚才的命令。”
- “停止 runwingui server。”
- “清理 runwingui 中已经完成的进程记录。”
- “runwingui 命令找不到，请检查安装或软链。”

## 全新 Windows + WSL 初始化或迁移

适合在新 Windows 机器复刻 WSL 开机自启/长驻、端口互通、Windows/WSL 双 SSH，或整体迁移现有 WSL。

示例：

- “这是一台全新的 Windows + WSL 环境，请先只读检测哪些条件已满足。”
- “生成管理员 PowerShell 命令，启用 Windows OpenSSH、防火墙、WSL mirrored networking 和可选长驻。”
- “用户侧准备完成并重启 WSL 了，请继续配置 WSL 内 systemd 和 sshd。”
- “只读审计当前 Windows/WSL 的 SSH、端口、防火墙、长驻配置，并给迁移清单。”
- “我要把当前 WSL 整体导出再导入新机器，请说明会迁移什么、Windows 侧还要重做什么。”
- “目标机器默认 Ubuntu 在 Store LocalState 目录，导入时应该放哪里？如何替换默认发行版？”
- “不想用 NSSM，只想手动启动 WSL 后让 tmux/Neovim 在退出 shell 后继续运行，请配置 systemd keepalive。”

Agent 会先只读检测，再拆分为：

1. 用户/管理员步骤：Administrator PowerShell、Windows OpenSSH、防火墙、`.wslconfig`、必要 WSL 重启；迁移时包括 `wsl --export` / `wsl --import`、导入目录、同名替换、`wsl --set-default`；NSSM keepalive 和 WSL systemd keepalive 都需明确确认。
2. Agent 可执行步骤：WSL `/etc/wsl.conf`、OpenSSH Server、`sshd_config`、`ssh.service`、`authorized_keys`、验证；整体导入后只修复检测出的缺口。

## 故障排查

直接描述现象即可，Agent 会选择健康检查、进程列表、server 重启、路径检查或编码处理。

示例：

- “Windows 命令超时了，排查桥接服务是否还活着。”
- “GUI 程序没有窗口弹出，检查 server 启动方式。”
- “命令报 `ConnectionRefused`，帮我恢复桥接服务。”
- “端口 19527 被占用了，判断怎么处理。”
- “`.venv-wsl` 或 `.venv-win` 缺失导致桥接失败，给修复步骤。”
- “Windows 侧 cwd 不对，检查路径转换和 UNC 限制。”

## 维护底层能力

如果要修改 `run(scope="win")` 或 runwingui 桥接系统，可以直接提出维护目标。

示例：

- “给 Windows 命令工具新增一个参数，并说明验证。”
- “检查 `run` 的 Windows 和 Shell scope 输出处理是否一致。”
- “扩展 runwingui，新增一个命令行选项。”
- “给 runwingui server 增加新的 HTTP API 端点。”
- “修改 Windows 侧 server 后，重启桥接服务并验证。”
- “解释 runwingui 的 WSL bash、client.py、Windows server.py 三层链路。”

## 提问时最好提供

- 项目目录：`/mnt/c/Projects/app` 或 `C:\Projects\app`。
- 目标：安装依赖、构建、测试、启动 GUI、后台服务、排查错误等。
- 必须在哪侧执行：Windows、WSL，或让 Agent 判断。
- 模式：普通命令、GUI、后台、长超时。
- 错误现象：超时、乱码、cwd 不对、GUI 不弹窗、连接失败、依赖缺失。
