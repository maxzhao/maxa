# browser 用户指南

本技能让 Agent 使用 `browser` 连接 Tauri 桌面应用、真实 Chrome/Edge/Chromium CDP 浏览器，或托管浏览器后端，完成页面观察、点击输入、截图、diff 验证、网络/状态检查和 Tauri IPC 调试。你只需说明目标、应用或网页地址、操作步骤和验证方式。

## 场景 1：连接和调试 Tauri 桌面应用

适合连接 Tauri Windows 桌面应用、观察界面、点击控件、填写表单、切换窗口或验证页面状态。

示例：

- “用 browser 连接这个 Tauri 应用，检查主窗口是否正常启动，应用路径是 `C:\...\app.exe`。”
- “连接 Tauri CDP，打开应用后截一张图，并列出当前页面可点击元素。”
- “在 Tauri 应用里点击设置按钮，切到设置窗口后检查标题和表单内容。”
- “这个 Tauri 应用有多个窗口，请列出窗口、切到第二个窗口并操作按钮。”

## 场景 2：连接真实已安装 Browser

适合操作本机常规安装的 Chrome、Edge 或 Chromium，而不是启动托管后端。

示例：

- “连接已经开启 CDP 的 Chrome，端口是 `9222`，然后查看当前页面。”
- “我已经打开 Edge remote debugging，请找到可用 CDP endpoint 并连接。”
- “指导我启动一个带 `--remote-debugging-port` 的 Chrome，然后接管它操作页面。”
- “连接我的真实浏览器 profile，切到当前目标 tab，然后截图并读取标题。”

## 场景 3：使用浏览器后端抓取动态或受保护网页

适合普通抓取拿不到 JS 渲染内容，或目标站有安全检查/反爬提示。

示例：

- “用标准网页访问模式打开这个页面，等待 JS 渲染完成后提取正文和 HTML。”
- “这个网页普通抓取拿不到内容，请用 browser 浏览器后端验证动态内容。”
- “这个页面遇到 Cloudflare 检查，请用受保护网页访问模式，先预热站点首页再抓取目标页。”
- “启动网页访问后端到非默认端口，抓取渲染后的 `article` 内容，完成后清理进程。”

## 场景 4：获取 snapshot / Ref 并交互

适合先理解页面结构，再基于元素操作。

示例：

- “先 snapshot 当前页面，找到提交按钮的 Ref，然后点击它。”
- “查看当前页面有哪些输入框，并填写邮箱和密码。”
- “点击导航后请重新 snapshot，不要复用旧 Ref。”
- “这个弹窗是动态出现的，请等待它出现后重新获取 Ref 再点击确认。”

## 场景 5：变更验证和视觉对比

适合确认某个操作或代码改动是否改变界面。

示例：

- “先记录当前页面快照，点击按钮后用 diff_snapshot 告诉我 DOM 变化。”
- “截一张基线图，操作后做 diff_screenshot，看视觉差异百分比。”
- “修改前后对比 URL、页面结构和截图差异。”
- “用 browser 验证这个 UI bug 是否修复，并给出截图证据。”

## 场景 6：网络、状态、存储和环境

适合检查请求、保存登录状态、查看 storage/cookies 或模拟环境。

示例：

- “登录后保存浏览器状态，下次加载这个状态继续测试。”
- “查看页面发出了哪些 API 请求，并读取某个响应 body。”
- “拦截 `**/api/data` 请求，验证接口失败时页面如何显示。”
- “查看 localStorage、sessionStorage 和 cookies。”
- “模拟离线状态、深色模式或移动设备，再检查页面表现。”

## 场景 7：脚本、底层输入和页面调试

适合普通点击/填写不足以完成任务时。

示例：

- “执行 JavaScript 读取当前页面标题和 localStorage。”
- “滚动到页面底部，再检查懒加载内容是否出现。”
- “用键盘快捷键打开搜索框并输入关键词。”
- “用鼠标坐标或底层输入模拟拖拽这个滑块。”
- “读取剪贴板；如果 Tauri WebView2 权限阻塞，请说明恢复方式。”

## 场景 8：调试 Tauri IPC / command / event

适合验证 Tauri 前后端通信。

示例：

- “连接应用后调用 Tauri command `greet`，参数 `{ name: "World" }`，检查返回值。”
- “监听 Tauri 事件 `download-finished`，触发操作后确认是否收到事件。”
- “向应用发一个 Tauri event，再观察前端是否更新。”
- “先从应用源码或应用已公开的接口确认可调用的 Tauri commands，再验证其中一个命令。”

当前工具目录提供 `tauri_invoke`、`tauri_listen`、`tauri_emit` 和 `tauri_app_info`，不提供通用的 command 枚举工具。

## 场景 9：录制、追踪、HAR、Profiler 和证据

适合保留运行证据或定位性能/网络问题。

示例：

- “开启 trace，复现问题后停止并保存结果。”
- “录制 screencast，操作完成后停止并说明保存位置。”
- “采集 HAR，复现一次接口问题后导出。”
- “收集 console errors、页面错误和性能 profiler 信息。”

Tauri CDP 模式下视频类 `recording_*` 可能不可用，优先使用 trace 或 screencast。

## 场景 10：处理 Tauri CDP 限制和恢复

适合 Tauri WebView2/CDP 行为异常、权限弹窗阻塞或部分浏览器工具不可用。

示例：

- “这个操作在 Tauri CDP 下失败了，请判断是否是 CDP 限制，并给出替代操作。”
- “点击后页面卡在权限弹窗，请恢复连接并说明应用端如何修复。”
- “我需要测试剪贴板读取，请检查 WebView2 权限问题并建议 Rust 端授权方案。”
- “不要用会破坏 CDP 连接的 window_new 或 recording_*，用 Tauri 多窗口/trace 替代。”

## 场景 11：开发或扩展 MCP Server

适合修改 `browser` MCP Server 本身，而不是操作页面。

示例：

- “帮我理解 browser MCP Server 的架构和调用链。”
- “新增一个 MCP 工具，请按现有 tool-registry 模式实现。”
- “这个 agent-browser action 在 Tauri CDP 下需要特殊处理，请在 bridge 层加拦截。”
- “检查 tauri_connect 的启动流程、CDP 端口检测和 runwingui 调用是否正确。”
- “调试 TauriTest helper 或 Vitest 集成，请按现有封装方式修改。”

## 文档分层

高频使用文档按“三个场景手册 + 一个公共操作接口”组织：

- Tauri 程序测试：连接 Tauri WebView2、多窗口、Tauri IPC、CDP 限制。
- 真实已安装 Browser：发现或指导启动带 CDP 的 Chrome/Edge/Chromium。
- 特定 Browser 后端：`standard/protected/auto`、warmup、代理、托管后端生命周期和安全检查判断。
- 公共操作接口：连接成功后的观察、定位、交互、等待、JS、网络、状态、diff 和证据采集。

低频文档：

- 环境配置：只在新机器缺 Obscura、protected 后端、Chrome/ChromeDriver、Xvfb 或 Python 依赖时使用。
- 开发维护：只在修改 `browser` MCP Server、工具 schema、session/bridge 或测试封装时使用。

## 与其他 Tauri 技能的关系

- “系统性探索这个 Tauri 应用并找 UI/功能缺陷。”——适合探索式 QA / dogfood。
- “为这个 Tauri 应用编写可回归的 E2E 测试。”——适合 E2E 测试编写。
- “只需要直接操作应用、截图、点击和验证。”——适合本技能。

## 建议提供的信息

- Tauri 应用路径、端口、启动参数，或网页 URL。
- 目标页面、按钮、表单、窗口名称或可见文本。
- 期望验证结果：URL、文本、截图差异、事件返回值、网络请求、后端 command 返回值等。
- 是否需要保存证据：截图、trace、HAR、screencast、diff 结果。
- 网页访问是否需要代理、预热站点首页、保存站点状态，或使用受保护网页访问。
- Server 开发任务需要新增/修改的工具、预期参数和失败现象。
