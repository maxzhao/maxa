# tauri-playwright: 历史设计文档 v2

> **状态：历史资料，非当前执行契约。** 本文保留更名前的设计、代码示例、包名及 CI 路径，用于追溯；不得据此恢复旧 Ability/MCP 标识或直接执行旧路径命令。
>
> 当前公开标识为 `browser`、`browser-dogfood`、`browser-e2e`，不提供旧名称别名。当前实现入口为 [`../index.js`](../index.js)；连接／操作指导见 [`../../../abilities/browser/SKILL.md`](../../../abilities/browser/SKILL.md)，服务维护见 [`../../../abilities/browser/references/development/server-dev.md`](../../../abilities/browser/references/development/server-dev.md)，稳定行为见 [`../../../.maxa/specs/abilities/base/browser/browser.md`](../../../.maxa/specs/abilities/base/browser/browser.md)。后续维护以上述当前所有者为准，不在本文更新运行指导。

## 概述

基于 agent-browser 核心模块 + MCP 协议的 Tauri 应用测试 MCP Server。

### 核心思路

agent-browser 是一个成熟的浏览器自动化 CLI 工具（Rust CLI + Node.js Daemon），内部通过 Playwright 操控 Chromium。它的 **所有浏览器操作逻辑都在 Node.js 层**（`actions.ts`、`browser.ts`、`snapshot.ts` 等），Rust 只做 CLI 解析。

本项目直接引用 agent-browser 的 Node.js 核心模块作为库，在其上层封装 MCP 协议接口，并追加 Tauri 专用能力。

```
agent-browser 原架构:
  Rust CLI → Unix Socket → Node.js Daemon → Playwright → CDP → Chromium

tauri-playwright 架构:
  MCP 协议 (stdio) → Node.js MCP Server → agent-browser 核心模块 → Playwright → CDP → WebView2
```

去掉了 Rust CLI、Unix Socket、Daemon 进程管理三层，MCP Server 直接在同进程调用 `BrowserManager` 和 `executeCommand`。

### 为什么基于 agent-browser 而非 Playwright MCP

| | Playwright MCP (官方) | agent-browser 核心 |
|--|----------------------|-------------------|
| 工具数 | 22 | 120+ |
| snapshot | 基础可访问性树 | 增强版（interactive 模式、cursor、selector 过滤、ref 体系） |
| 截图 | 基础 | annotate 标注、ref overlay |
| CDP 输入注入 | ❌ | ✅ input_mouse/keyboard/touch |
| Diff | ❌ | ✅ snapshot diff + screenshot diff |
| 状态持久化 | ❌ | ✅ state_save/load |
| 录制/追踪 | ❌ | ✅ trace/profiler/har/recording |
| 语义化定位 | 有限 (ref) | getByRole/Text/Label/Placeholder/TestId |
| 网络控制 | 基础 | route/unroute/requests/responsebody |
| 错误处理 | 基础 | AI 友好的错误消息 (toAIFriendlyError) |
| Zod Schema | 自定义 | 完整的 120+ schema (protocol.ts) |

---

## 平台限制

**仅 Windows**。Tauri 在 Windows 上使用 WebView2 (Chromium)，支持 CDP。

```
WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9222
```

---

## 架构设计

### 依赖关系

```
tauri-playwright (本项目)
    ├── agent-browser (本地路径依赖，使用其 dist/ 模块)
    │   ├── dist/browser.js    → BrowserManager 类
    │   ├── dist/actions.js    → executeCommand() 函数
    │   ├── dist/protocol.js   → parseCommand(), Zod schemas
    │   ├── dist/snapshot.js   → getEnhancedSnapshot(), RefMap
    │   ├── dist/diff.js       → diffSnapshots(), diffScreenshots()
    │   ├── dist/types.js      → Command, Response 类型
    │   └── dist/state-utils.js → 状态持久化工具
    │
    └── @modelcontextprotocol/sdk → MCP Server SDK
```

agent-browser 需要先构建 (`pnpm build`) 产出 `dist/` 目录。

### 项目结构

```
tauri-playwright/
├── index.js                    # MCP Server 入口
├── package.json
├── docs/
│   └── design.md               # 本文档
├── lib/
│   ├── session.js              # Tauri 应用生命周期 (启动进程 + CDP 连接)
│   ├── bridge.js               # MCP 工具调用 → agent-browser Command 转换层
│   ├── tool-registry.js        # 从 agent-browser Zod schema 自动生成 MCP 工具注册
│   ├── test-helper.js          # E2E 测试 Helper — 导出 TauriTest 类
│   ├── errors.js               # 错误格式化
│   └── tools/
│       └── tauri.js            # Tauri 专用工具 (invoke/emit/listen/app_info)
└── e2e/
    ├── vitest.config.js        # Vitest E2E 配置
    ├── global-setup.js         # 全局 Setup/Teardown (启动/关闭 Tauri 应用)
    ├── baselines/              # 视觉回归基线图片
    ├── basic-interaction.test.js
    ├── tauri-backend.test.js
    ├── visual-regression.test.js
    └── network-mock.test.js
```

### 关键设计：bridge.js — 桥接层

MCP 工具调用与 agent-browser Command 之间的转换是本项目的核心逻辑。

```
MCP 工具调用                          agent-browser Command
┌─────────────────┐                  ┌─────────────────────┐
│ tool: "click"   │                  │ {                   │
│ params: {       │    bridge.js     │   id: "uuid",       │
│   selector: "@e1" ──────────────►  │   action: "click",  │
│   button: "left"│                  │   selector: "@e1",  │
│ }               │                  │   button: "left"    │
└─────────────────┘                  │ }                   │
                                     └─────────────────────┘
                                              │
                                              ▼
                                     executeCommand(cmd, browser)
                                              │
                                              ▼
                                     ┌─────────────────────┐
                                     │ Response {           │
                                     │   id, success, data  │
                                     │ }                    │
                                     └─────────────────────┘
                                              │
                                     bridge.js│
                                              ▼
                                     MCP 工具返回
                                     { content: [{ type: "text", text: JSON.stringify(data) }] }
```

bridge.js 的核心函数：

```javascript
// lib/bridge.js
import { executeCommand } from 'agent-browser/dist/actions.js';
import { randomUUID } from 'crypto';

/**
 * 将 MCP 工具参数转换为 agent-browser Command，执行后转换回 MCP 响应
 * @param {string} action - agent-browser action 名称
 * @param {object} params - MCP 工具调用参数 (不含 id 和 action)
 * @param {BrowserManager} browser - BrowserManager 实例
 */
export async function dispatch(action, params, browser) {
  const command = {
    id: randomUUID(),
    action,
    ...params,
  };

  const response = await executeCommand(command, browser);

  if (!response.success) {
    return {
      content: [{ type: "text", text: JSON.stringify({ error: true, message: response.error }) }],
      isError: true,
    };
  }

  return {
    content: [{ type: "text", text: JSON.stringify(response.data, null, 2) }],
  };
}
```

### 关键设计：tool-registry.js — 自动工具注册

agent-browser 的 `protocol.ts` 中有完整的 Zod schema 定义。但这些 schema 不是公共导出的（只有 `parseCommand`、`successResponse`、`errorResponse` 是 export 的）。

因此工具注册需要**手动定义 MCP inputSchema**，但参数定义直接参照 protocol.ts 中的 Zod schema（作为权威来源）。

```javascript
// lib/tool-registry.js
import { z } from 'zod';
import { dispatch } from './bridge.js';

/**
 * 工具定义格式
 * 每个工具 = { name, description, inputSchema (Zod shape), action (agent-browser action name) }
 *
 * inputSchema 中不含 id 和 action 字段（由 bridge 自动添加）
 */

export const TOOLS = [
  {
    name: "snapshot",
    action: "snapshot",
    description: "Capture accessibility tree snapshot with element refs",
    inputSchema: {
      interactive: z.boolean().optional().describe("Only show interactive elements"),
      cursor: z.boolean().optional().describe("Include cursor-interactive elements"),
      maxDepth: z.number().optional().describe("Maximum tree depth"),
      compact: z.boolean().optional().describe("Compact output format"),
      selector: z.string().optional().describe("CSS selector to scope snapshot"),
    },
  },
  {
    name: "click",
    action: "click",
    description: "Click an element by ref or selector",
    inputSchema: {
      selector: z.string().describe("Element ref (@e1) or CSS selector"),
      button: z.enum(["left", "right", "middle"]).optional().describe("Mouse button"),
      clickCount: z.number().optional().describe("Number of clicks"),
      delay: z.number().optional().describe("Delay between mousedown and mouseup in ms"),
      newTab: z.boolean().optional().describe("Open link in new tab instead of clicking"),
    },
  },
  // ... 其余工具定义
];

/**
 * 注册所有工具到 MCP Server
 */
export function registerAllTools(server, browser) {
  for (const tool of TOOLS) {
    server.registerTool(
      tool.name,
      { description: tool.description, inputSchema: tool.inputSchema },
      async (params) => dispatch(tool.action, params, browser)
    );
  }
}
```

### 关键设计：session.js — Tauri 应用生命周期

```javascript
// lib/session.js
import { spawn } from 'child_process';
import { BrowserManager } from 'agent-browser/dist/browser.js';
import { initActionPolicy } from 'agent-browser/dist/actions.js';

export class TauriSession {
  constructor() {
    this.browser = new BrowserManager();
    this.childProcess = null;
  }

  /**
   * 启动 Tauri 应用并通过 CDP 连接
   * 1. spawn Tauri 可执行文件，注入 CDP 环境变量
   * 2. 等待 CDP 端口就绪
   * 3. 调用 BrowserManager.launch({ cdpPort }) 连接
   */
  async connect({ app_path, port = 9222, args = [], timeout = 30000 }) {
    // 启动 Tauri 应用
    this.childProcess = spawn(app_path, args, {
      env: {
        ...process.env,
        WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${port}`,
      },
      stdio: 'ignore',
    });

    // 等待 CDP 端口就绪
    await this._waitForCDP(port, timeout);

    // BrowserManager 连接
    initActionPolicy();
    await this.browser.launch({
      id: 'tauri-connect',
      action: 'launch',
      cdpPort: port,
      headless: false,
    });
  }

  /**
   * 断开连接并关闭应用
   */
  async disconnect() {
    await this.browser.close();
    if (this.childProcess) {
      this.childProcess.kill();
      this.childProcess = null;
    }
  }

  /**
   * 轮询等待 CDP 端口就绪
   */
  async _waitForCDP(port, timeout) {
    const start = Date.now();
    while (Date.now() - start < timeout) {
      try {
        const res = await fetch(`http://localhost:${port}/json/version`);
        if (res.ok) return;
      } catch {}
      await new Promise(r => setTimeout(r, 200));
    }
    throw new Error(`CDP port ${port} not ready after ${timeout}ms`);
  }
}
```

---

## 完整工具列表

### 工具总览

共 **约 100 个 MCP 工具**，分为以下类别：

| 分组 | 工具数 | 来源 |
|------|--------|------|
| Tauri 连接 | 2 | 本项目自定义 |
| 快照与截图 | 4 | agent-browser |
| 基础交互 | 10 | agent-browser |
| 鼠标操作 | 5 | agent-browser |
| 键盘操作 | 5 | agent-browser |
| 语义化定位 | 8 | agent-browser |
| 元素查询 | 12 | agent-browser |
| 等待 | 4 | agent-browser |
| 导航 | 5 | agent-browser |
| 页面内容 | 4 | agent-browser |
| 标签页/窗口 | 6 | agent-browser |
| Frame | 2 | agent-browser |
| 网络控制 | 6 | agent-browser |
| Cookie/Storage | 6 | agent-browser |
| 对话框 | 1 | agent-browser |
| 环境模拟 | 8 | agent-browser |
| 脚本注入 | 5 | agent-browser |
| CDP 输入注入 | 3 | agent-browser |
| 调试录制 | 8 | agent-browser |
| 录屏 | 5 | agent-browser |
| Diff | 3 | agent-browser |
| 状态持久化 | 7 | agent-browser |
| Tauri 专用 | 4 | 本项目自定义 |
| 其他 | 3 | agent-browser |

以下每个工具列出：工具名、描述、参数（参照 agent-browser protocol.ts Zod schema）、对应的 agent-browser action。

---

### Tauri 连接 (2) — 本项目自定义

#### tauri_connect

启动 Tauri 应用并通过 CDP 连接。

| 参数 | 类型 | 必需 | 说明 |
|------|------|:----:|------|
| app_path | string | ✅ | Tauri 可执行文件路径 |
| port | number | | CDP 端口，默认 9222 |
| args | string[] | | 应用启动参数 |
| timeout | number | | 等待启动超时 ms，默认 30000 |

**实现**: TauriSession.connect() — spawn 进程 + 等待 CDP + BrowserManager.launch({ cdpPort })

#### tauri_disconnect

断开连接并关闭 Tauri 应用。

**无参数。**

**实现**: TauriSession.disconnect() — BrowserManager.close() + kill 子进程

---

### 快照与截图 (4) — agent-browser

#### snapshot

> action: `snapshot` | schema: snapshotSchema

获取可访问性树快照，返回 ref 标识（如 @e1, @e2）供后续操作使用。

| 参数 | 类型 | 说明 |
|------|------|------|
| interactive | boolean? | 仅显示可交互元素 |
| cursor | boolean? | 包含 cursor 可交互元素（div onclick, cursor:pointer） |
| maxDepth | number? | 最大树深度 |
| compact | boolean? | 紧凑输出 |
| selector | string? | CSS 选择器范围限定 |

#### screenshot

> action: `screenshot` | schema: screenshotSchema

截取页面或元素截图。

| 参数 | 类型 | 说明 |
|------|------|------|
| path | string? | 保存路径，默认自动生成 |
| fullPage | boolean? | 全页截图 |
| selector | string? | 元素截图 |
| format | "png" \| "jpeg" | 格式 |
| quality | number? | 质量 0-100，仅 jpeg |
| annotate | boolean? | 在截图上标注 ref 编号 |

#### highlight

> action: `highlight` | schema: highlightSchema

高亮显示元素。

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或 CSS 选择器 |

#### diff_snapshot

> action: `diff_snapshot` | schema: diffSnapshotSchema

对比当前快照与上一次/基线快照的差异。

| 参数 | 类型 | 说明 |
|------|------|------|
| baseline | string? | 基线文件路径，默认用上一次快照 |
| selector | string? | 范围限定 |
| compact | boolean? | 紧凑 |
| maxDepth | number? | 最大深度 |

#### diff_screenshot

> action: `diff_screenshot` | schema: diffScreenshotSchema

对比当前截图与基线截图的像素差异。

| 参数 | 类型 | 说明 |
|------|------|------|
| baseline | string | 基线图片路径 |
| output | string? | 差异图输出路径 |
| threshold | number? | 差异阈值 0-1 |
| selector | string? | 元素截图 |
| fullPage | boolean? | 全页截图 |

#### diff_url

> action: `diff_url` | schema: diffUrlSchema

对比两个 URL 的快照/截图差异。

| 参数 | 类型 | 说明 |
|------|------|------|
| url1 | string | 第一个 URL |
| url2 | string | 第二个 URL |
| screenshot | boolean? | 同时对比截图 |
| fullPage | boolean? | 全页 |
| waitUntil | string? | 等待策略 |
| selector | string? | 范围限定 |
| compact | boolean? | 紧凑 |
| maxDepth | number? | 最大深度 |

---

### 基础交互 (10) — agent-browser

#### click

> action: `click` | schema: clickSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref (@e1) 或 CSS 选择器 |
| button | "left" \| "right" \| "middle" | 鼠标按钮 |
| clickCount | number? | 点击次数 |
| delay | number? | mousedown/mouseup 间延迟 ms |
| newTab | boolean? | 在新标签页打开链接 |

#### dblclick

> action: `dblclick` | schema: dblclickSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

#### fill

> action: `fill` | schema: fillSchema

清空后填入值。

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |
| value | string | 要填入的值 |

#### type

> action: `type` | schema: typeSchema

逐字输入（触发 key handler）。

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |
| text | string | 要输入的文本 |
| delay | number? | 每个字符间的延迟 ms |
| clear | boolean? | 先清空 |

#### check

> action: `check` | schema: checkSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

#### uncheck

> action: `uncheck` | schema: uncheckSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

#### select

> action: `select` | schema: selectSchema

选择下拉框选项。

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |
| values | string \| string[] | 选项值 |

#### multiselect

> action: `multiselect` | schema: multiSelectSchema

多选。

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |
| values | string[] | 选项值 |

#### clear

> action: `clear` | schema: clearSchema

清空输入框。

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

#### upload

> action: `upload` | schema: uploadSchema

上传文件。

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | 文件输入元素 |
| files | string \| string[] | 文件路径 |

---

### 鼠标操作 (5) — agent-browser

#### hover

> action: `hover` | schema: hoverSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

#### drag

> action: `drag` | schema: dragSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| source | string | 源元素 |
| target | string | 目标元素 |

#### mousemove

> action: `mousemove` | schema: mouseMoveSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| x | number | X 坐标 |
| y | number | Y 坐标 |

#### mousedown

> action: `mousedown` | schema: mouseDownSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| button | "left" \| "right" \| "middle" | 鼠标按钮 |

#### mouseup

> action: `mouseup` | schema: mouseUpSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| button | "left" \| "right" \| "middle" | 鼠标按钮 |

---

### 键盘操作 (5) — agent-browser

#### press

> action: `press` | schema: pressSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| key | string | 按键名 (如 "Enter", "ArrowLeft") |
| selector | string? | 可选目标元素 |

#### keyboard

> action: `keyboard` | schema: keyboardSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| subaction | "type" \| "press" \| "insertText" | 子操作 |
| keys | string? | press 时的按键 |
| text | string? | type/insertText 时的文本 |
| delay | number? | 延迟 |

#### keydown

> action: `keydown` | schema: keyDownSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| key | string | 按键名 |

#### keyup

> action: `keyup` | schema: keyUpSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| key | string | 按键名 |

#### inserttext

> action: `inserttext` | schema: insertTextSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| text | string | 文本 |

---

### 语义化定位 (8) — agent-browser

这些工具使用 Playwright 的 getByRole/getByText 等语义化定位方式，比 CSS 选择器更 AI 友好。

#### getbyrole

> action: `getbyrole` | schema: getByRoleSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| role | string | ARIA role (如 "button", "textbox") |
| name | string? | 可访问名称 |
| exact | boolean? | 精确匹配 |
| subaction | "click" \| "fill" \| "check" \| "hover" | 要执行的操作 |
| value | string? | fill 时的值 |

#### getbytext

> action: `getbytext` | schema: getByTextSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| text | string | 文本内容 |
| exact | boolean? | 精确匹配 |
| subaction | "click" \| "hover" | 操作 |

#### getbylabel

> action: `getbylabel` | schema: getByLabelSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| label | string | label 文本 |
| exact | boolean? | 精确匹配 |
| subaction | "click" \| "fill" \| "check" | 操作 |
| value | string? | fill 时的值 |

#### getbyplaceholder

> action: `getbyplaceholder` | schema: getByPlaceholderSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| placeholder | string | placeholder 文本 |
| exact | boolean? | 精确匹配 |
| subaction | "click" \| "fill" | 操作 |
| value | string? | fill 时的值 |

#### getbyalttext

> action: `getbyalttext` | schema: getByAltTextSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| text | string | alt 文本 |
| exact | boolean? | 精确匹配 |
| subaction | "click" \| "hover" | 操作 |

#### getbytitle

> action: `getbytitle` | schema: getByTitleSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| text | string | title 属性 |
| exact | boolean? | 精确匹配 |
| subaction | "click" \| "hover" | 操作 |

#### getbytestid

> action: `getbytestid` | schema: getByTestIdSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| testId | string | data-testid 值 |
| subaction | "click" \| "fill" \| "check" \| "hover" | 操作 |
| value | string? | fill 时的值 |

#### nth

> action: `nth` | schema: nthSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | CSS 选择器 |
| index | number | 索引（-1 = 最后一个） |
| subaction | "click" \| "fill" \| "check" \| "hover" \| "text" | 操作 |
| value | string? | fill 时的值 |

---

### 元素查询 (12) — agent-browser

#### getattribute

> action: `getattribute`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |
| attribute | string | 属性名 |

#### gettext

> action: `gettext`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

#### innertext

> action: `innertext`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

#### innerhtml

> action: `innerhtml`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

#### inputvalue

> action: `inputvalue`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

#### setvalue

> action: `setvalue`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |
| value | string | 值 |

#### isvisible

> action: `isvisible`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

#### isenabled

> action: `isenabled`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

#### ischecked

> action: `ischecked`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

#### count

> action: `count`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | CSS 选择器 |

#### boundingbox

> action: `boundingbox`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

#### styles

> action: `styles`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

---

### 等待 (4) — agent-browser

#### wait

> action: `wait` | schema: waitSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string? | 等待元素 |
| timeout | number? | 超时 ms |
| state | "attached" \| "detached" \| "visible" \| "hidden" | 状态 |

#### waitforurl

> action: `waitforurl`

| 参数 | 类型 | 说明 |
|------|------|------|
| url | string | URL 模式 |
| timeout | number? | 超时 ms |

#### waitforloadstate

> action: `waitforloadstate`

| 参数 | 类型 | 说明 |
|------|------|------|
| state | "load" \| "domcontentloaded" \| "networkidle" | 状态 |
| timeout | number? | 超时 ms |

#### waitforfunction

> action: `waitforfunction`

| 参数 | 类型 | 说明 |
|------|------|------|
| expression | string | JS 表达式 |
| timeout | number? | 超时 ms |

---

### 导航 (5) — agent-browser

#### navigate

> action: `navigate`

| 参数 | 类型 | 说明 |
|------|------|------|
| url | string | 目标 URL |
| waitUntil | "load" \| "domcontentloaded" \| "networkidle" | 等待策略 |
| headers | object? | 请求头 |

#### back

> action: `back` | 无参数

#### forward

> action: `forward` | 无参数

#### reload

> action: `reload` | 无参数

#### url

> action: `url` | 无参数。返回当前 URL。

#### title

> action: `title` | 无参数。返回当前标题。

---

### 页面内容 (4) — agent-browser

#### evaluate

> action: `evaluate`

| 参数 | 类型 | 说明 |
|------|------|------|
| script | string | JS 代码 |
| args | any[]? | 参数 |

#### evalhandle

> action: `evalhandle`

| 参数 | 类型 | 说明 |
|------|------|------|
| script | string | JS 代码 |

#### content

> action: `content`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string? | 可选，获取元素 innerHTML |

#### setcontent

> action: `setcontent`

| 参数 | 类型 | 说明 |
|------|------|------|
| html | string | HTML 内容 |

---

### 标签页/窗口 (6) — agent-browser

#### tab_list

> action: `tab_list` | 无参数

#### tab_new

> action: `tab_new`

| 参数 | 类型 | 说明 |
|------|------|------|
| url | string? | 新标签页 URL |

#### tab_switch

> action: `tab_switch`

| 参数 | 类型 | 说明 |
|------|------|------|
| index | number | 标签页索引 |

#### tab_close

> action: `tab_close`

| 参数 | 类型 | 说明 |
|------|------|------|
| index | number? | 标签页索引，默认当前 |

#### window_new

> action: `window_new`

| 参数 | 类型 | 说明 |
|------|------|------|
| viewport | {width, height}? | 窗口尺寸 |

#### bringtofront

> action: `bringtofront` | 无参数

---

### Frame (2) — agent-browser

#### frame

> action: `frame`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string? | iframe 选择器 |
| name | string? | frame name |
| url | string? | frame URL |

#### mainframe

> action: `mainframe` | 无参数

---

### 网络控制 (6) — agent-browser

#### route

> action: `route`

| 参数 | 类型 | 说明 |
|------|------|------|
| url | string | URL 模式 |
| response | {status?, body?, contentType?, headers?}? | Mock 响应 |
| abort | boolean? | 阻断请求 |

#### unroute

> action: `unroute`

| 参数 | 类型 | 说明 |
|------|------|------|
| url | string? | URL 模式，空则清除全部 |

#### requests

> action: `requests`

| 参数 | 类型 | 说明 |
|------|------|------|
| filter | string? | URL 过滤 |
| clear | boolean? | 清除记录 |

#### download

> action: `download`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | 触发下载的元素 |
| path | string | 保存路径 |

#### waitfordownload

> action: `waitfordownload`

| 参数 | 类型 | 说明 |
|------|------|------|
| path | string? | 保存路径 |
| timeout | number? | 超时 |

#### responsebody

> action: `responsebody`

| 参数 | 类型 | 说明 |
|------|------|------|
| url | string | 匹配 URL |
| timeout | number? | 超时 |

---

### Cookie/Storage (6) — agent-browser

#### cookies_get

> action: `cookies_get`

| 参数 | 类型 | 说明 |
|------|------|------|
| urls | string[]? | 过滤 URL |

#### cookies_set

> action: `cookies_set`

| 参数 | 类型 | 说明 |
|------|------|------|
| cookies | array | Cookie 数组 [{name, value, url?, domain?, path?, expires?, httpOnly?, secure?, sameSite?}] |

#### cookies_clear

> action: `cookies_clear` | 无参数

#### storage_get

> action: `storage_get`

| 参数 | 类型 | 说明 |
|------|------|------|
| type | "local" \| "session" | 存储类型 |
| key | string? | 键名，空则返回全部 |

#### storage_set

> action: `storage_set`

| 参数 | 类型 | 说明 |
|------|------|------|
| type | "local" \| "session" | 存储类型 |
| key | string | 键名 |
| value | string | 值 |

#### storage_clear

> action: `storage_clear`

| 参数 | 类型 | 说明 |
|------|------|------|
| type | "local" \| "session" | 存储类型 |

---

### 对话框 (1) — agent-browser

#### dialog

> action: `dialog`

| 参数 | 类型 | 说明 |
|------|------|------|
| response | "accept" \| "dismiss" | 接受或拒绝 |
| promptText | string? | prompt 输入文本 |

---

### 环境模拟 (8) — agent-browser

#### viewport

> action: `viewport`

| 参数 | 类型 | 说明 |
|------|------|------|
| width | number | 宽度 |
| height | number | 高度 |
| deviceScaleFactor | number? | DPI 缩放 |

#### device

> action: `device`

| 参数 | 类型 | 说明 |
|------|------|------|
| device | string | 设备名称 (如 "iPhone 14") |

#### emulatemedia

> action: `emulatemedia`

| 参数 | 类型 | 说明 |
|------|------|------|
| media | "screen" \| "print" \| null | 媒体类型 |
| colorScheme | "light" \| "dark" \| "no-preference" \| null | 配色方案 |
| reducedMotion | "reduce" \| "no-preference" \| null | 减少动画 |
| forcedColors | "active" \| "none" \| null | 强制颜色 |

#### offline

> action: `offline`

| 参数 | 类型 | 说明 |
|------|------|------|
| offline | boolean | 是否离线 |

#### headers

> action: `headers`

| 参数 | 类型 | 说明 |
|------|------|------|
| headers | object | 额外请求头 |

#### geolocation

> action: `geolocation`

| 参数 | 类型 | 说明 |
|------|------|------|
| latitude | number | 纬度 |
| longitude | number | 经度 |
| accuracy | number? | 精度 |

#### permissions

> action: `permissions`

| 参数 | 类型 | 说明 |
|------|------|------|
| permissions | string[] | 权限列表 |
| grant | boolean | 授予或拒绝 |

#### credentials

> action: `credentials`

| 参数 | 类型 | 说明 |
|------|------|------|
| username | string | 用户名 |
| password | string | 密码 |

---

### 脚本注入 (5) — agent-browser

#### addscript

> action: `addscript`

| 参数 | 类型 | 说明 |
|------|------|------|
| content | string? | JS 代码 |
| url | string? | 脚本 URL |

#### addstyle

> action: `addstyle`

| 参数 | 类型 | 说明 |
|------|------|------|
| content | string? | CSS 代码 |
| url | string? | 样式 URL |

#### addinitscript

> action: `addinitscript`

| 参数 | 类型 | 说明 |
|------|------|------|
| script | string | 初始化脚本 |

#### expose

> action: `expose`

| 参数 | 类型 | 说明 |
|------|------|------|
| name | string | 暴露的函数名 |

#### dispatch

> action: `dispatch`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | 目标元素 |
| event | string | 事件名 |
| eventInit | object? | 事件初始化参数 |

---

### CDP 输入注入 (3) — agent-browser

通过 CDP 协议直接注入输入事件，绕过 JS 线程。

#### input_mouse

> action: `input_mouse` | schema: inputMouseSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| type | "mousePressed" \| "mouseReleased" \| "mouseMoved" \| "mouseWheel" | 事件类型 |
| x | number | X 坐标 |
| y | number | Y 坐标 |
| button | "left" \| "right" \| "middle" \| "none" | 按钮 |
| clickCount | number? | 点击次数 |
| deltaX | number? | 滚轮 X |
| deltaY | number? | 滚轮 Y |
| modifiers | number? | 修饰键位掩码 |

#### input_keyboard

> action: `input_keyboard` | schema: inputKeyboardSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| type | "keyDown" \| "keyUp" \| "char" | 事件类型 |
| key | string? | 按键名 |
| code | string? | 按键代码 |
| text | string? | 字符 |
| modifiers | number? | 修饰键位掩码 |

#### input_touch

> action: `input_touch` | schema: inputTouchSchema

| 参数 | 类型 | 说明 |
|------|------|------|
| type | "touchStart" \| "touchEnd" \| "touchMove" \| "touchCancel" | 事件类型 |
| touchPoints | [{x, y, id?}] | 触摸点 |
| modifiers | number? | 修饰键位掩码 |

---

### 调试录制 (8) — agent-browser

#### console

> action: `console`

| 参数 | 类型 | 说明 |
|------|------|------|
| clear | boolean? | 清除日志 |

#### errors

> action: `errors`

| 参数 | 类型 | 说明 |
|------|------|------|
| clear | boolean? | 清除错误 |

#### trace_start

> action: `trace_start`

| 参数 | 类型 | 说明 |
|------|------|------|
| screenshots | boolean? | 包含截图 |
| snapshots | boolean? | 包含快照 |

#### trace_stop

> action: `trace_stop`

| 参数 | 类型 | 说明 |
|------|------|------|
| path | string? | 输出路径 |

#### profiler_start

> action: `profiler_start`

| 参数 | 类型 | 说明 |
|------|------|------|
| categories | string[]? | 分类 |

#### profiler_stop

> action: `profiler_stop`

| 参数 | 类型 | 说明 |
|------|------|------|
| path | string? | 输出路径 |

#### har_start

> action: `har_start` | 无参数

#### har_stop

> action: `har_stop`

| 参数 | 类型 | 说明 |
|------|------|------|
| path | string | 输出路径 |

---

### 录屏 (5) — agent-browser

#### screencast_start

> action: `screencast_start`

| 参数 | 类型 | 说明 |
|------|------|------|
| format | "jpeg" \| "png" | 格式 |
| quality | number? | 质量 0-100 |
| maxWidth | number? | 最大宽度 |
| maxHeight | number? | 最大高度 |
| everyNthFrame | number? | 每 N 帧取一帧 |

#### screencast_stop

> action: `screencast_stop` | 无参数

#### recording_start

> action: `recording_start`

| 参数 | 类型 | 说明 |
|------|------|------|
| path | string | 输出路径 |
| url | string? | 导航 URL |

#### recording_stop

> action: `recording_stop` | 无参数

#### recording_restart

> action: `recording_restart`

| 参数 | 类型 | 说明 |
|------|------|------|
| path | string | 新输出路径 |
| url | string? | 导航 URL |

---

### 状态持久化 (7) — agent-browser

#### state_save

> action: `state_save`

| 参数 | 类型 | 说明 |
|------|------|------|
| path | string | 保存路径 |

#### state_load

> action: `state_load`

| 参数 | 类型 | 说明 |
|------|------|------|
| path | string | 加载路径 |

#### state_list

> action: `state_list` | 无参数

#### state_clear

> action: `state_clear`

| 参数 | 类型 | 说明 |
|------|------|------|
| sessionName | string? | 会话名 |
| all | boolean? | 清除全部 |

#### state_show

> action: `state_show`

| 参数 | 类型 | 说明 |
|------|------|------|
| filename | string | 文件名 |

#### state_clean

> action: `state_clean`

| 参数 | 类型 | 说明 |
|------|------|------|
| days | number | 过期天数 |

#### state_rename

> action: `state_rename`

| 参数 | 类型 | 说明 |
|------|------|------|
| oldName | string | 旧名 |
| newName | string | 新名 |

---

### Tauri 专用 (4) — 本项目自定义

这些工具通过 BrowserManager 的 page 对象调用 `page.evaluate()` 执行 Tauri JS API。

#### tauri_invoke

调用 Tauri Rust 后端命令。

| 参数 | 类型 | 必需 | 说明 |
|------|------|:----:|------|
| command | string | ✅ | Tauri Command 名称 |
| args | object | | 命令参数，默认 {} |
| timeout | number | | 超时 ms，默认 10000 |

**实现**:
```javascript
const page = session.browser.getPage();
const result = await page.evaluate(async ({ cmd, args }) => {
  const invoke = window.__TAURI__?.core?.invoke;
  if (!invoke) throw new Error('Tauri invoke API not available');
  return await invoke(cmd, args);
}, { cmd: params.command, args: params.args || {} });
```

#### tauri_emit

向 Tauri 后端发送事件。

| 参数 | 类型 | 必需 | 说明 |
|------|------|:----:|------|
| event | string | ✅ | 事件名称 |
| payload | any | | 事件数据 |

#### tauri_listen

监听 Tauri 后端事件（一次性）。

| 参数 | 类型 | 必需 | 说明 |
|------|------|:----:|------|
| event | string | ✅ | 事件名称 |
| timeout | number | | 超时 ms，默认 5000 |

#### tauri_app_info

获取 Tauri 应用信息。

**无参数。**

---

### 其他 (3) — agent-browser

#### focus

> action: `focus`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

#### selectall

> action: `selectall`

| 参数 | 类型 | 说明 |
|------|------|------|
| selector | string | ref 或选择器 |

#### clipboard

> action: `clipboard`

| 参数 | 类型 | 说明 |
|------|------|------|
| operation | "copy" \| "paste" \| "read" | 操作 |
| text | string? | 写入文本 |

---

### 不纳入的 agent-browser action

| action | 原因 |
|--------|------|
| `launch` | 由 `tauri_connect` 替代（封装了 Tauri 进程管理 + launch） |
| `close` | 由 `tauri_disconnect` 替代（封装了进程清理） |
| `confirm` / `deny` | 安全策略确认流程，MCP 场景不需要 |
| `auth_save` / `auth_login` / `auth_list` / `auth_delete` / `auth_show` | 认证管理，Tauri 应用登录方式不同，暂不纳入 |
| `useragent` | 需在 launch 时设置，CDP 连接后无法更改 |
| `timezone` / `locale` | 同上，需在 context 创建时设置 |
| `pdf` | Tauri 应用场景不需要 |
| `pause` (Playwright inspector) | MCP 场景不需要 |
| `video_start` / `video_stop` | 需 context 级别配置，CDP 连接不支持 |
| `swipe` / `device_list` | iOS 专用 |

---

## 依赖

```json
{
  "name": "tauri-playwright-mcp",
  "version": "1.0.0",
  "type": "module",
  "main": "index.js",
  "scripts": {
    "start": "node index.js"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.0.0",
    "agent-browser": "file:../../devtools/agent-browser",
    "zod": "^3.23.0"
  }
}
```

**注意**: agent-browser 需要先执行 `pnpm build` 产出 `dist/` 目录。本项目通过 `file:` 路径引用本地 agent-browser。

agent-browser 的依赖（`playwright-core`、`ws`、`zod` 等）会被间接引入，不需要重复声明。

---

## 实施计划

### 前置准备
- [ ] 构建 agent-browser: `cd ~/devtools/agent-browser && pnpm build`
- [ ] 验证 dist/ 输出: `ls dist/browser.js dist/actions.js dist/protocol.js dist/snapshot.js`
- [ ] 验证模块可 import: `node -e "import('agent-browser/dist/browser.js').then(m => console.log(Object.keys(m)))"`

### Phase 1: 基础骨架
- [ ] `package.json` (依赖 agent-browser + @modelcontextprotocol/sdk)
- [ ] `index.js` (MCP Server 入口)
- [ ] `lib/session.js` (TauriSession: spawn + waitForCDP + BrowserManager.launch)
- [ ] `lib/bridge.js` (dispatch: MCP 调用 → Command → executeCommand → MCP 响应)
- [ ] `lib/errors.js` (错误格式化)
- [ ] 注册 `tauri_connect` + `tauri_disconnect` 工具
- [ ] **验证**: 启动 MCP Server → tauri_connect → 成功连接 Tauri 应用

### Phase 2: 核心工具 — 快照/截图/交互
- [ ] `lib/tool-registry.js` (工具定义数组 + 批量注册函数)
- [ ] 注册快照工具: `snapshot`, `screenshot`, `highlight`
- [ ] 注册基础交互: `click`, `dblclick`, `fill`, `type`, `check`, `uncheck`, `select`, `clear`, `upload`
- [ ] 注册鼠标: `hover`, `drag`, `mousemove`, `mousedown`, `mouseup`
- [ ] 注册键盘: `press`, `keyboard`, `keydown`, `keyup`, `inserttext`
- [ ] **验证**: snapshot → 获取 ref → click @e1 → 验证交互成功

### Phase 3: 查询与等待
- [ ] 注册元素查询: `getattribute`, `gettext`, `innertext`, `innerhtml`, `inputvalue`, `setvalue`, `isvisible`, `isenabled`, `ischecked`, `count`, `boundingbox`, `styles`
- [ ] 注册语义化定位: `getbyrole`, `getbytext`, `getbylabel`, `getbyplaceholder`, `getbyalttext`, `getbytitle`, `getbytestid`, `nth`
- [ ] 注册等待: `wait`, `waitforurl`, `waitforloadstate`, `waitforfunction`
- [ ] **验证**: 使用语义化定位操作 Tauri UI 元素

### Phase 4: 页面/窗口/导航
- [ ] 注册导航: `navigate`, `back`, `forward`, `reload`, `url`, `title`
- [ ] 注册页面: `evaluate`, `evalhandle`, `content`, `setcontent`
- [ ] 注册标签页: `tab_list`, `tab_new`, `tab_switch`, `tab_close`, `window_new`, `bringtofront`
- [ ] 注册 Frame: `frame`, `mainframe`
- [ ] **验证**: Tauri 多窗口切换

### Phase 5: 网络/存储/环境
- [ ] 注册网络: `route`, `unroute`, `requests`, `download`, `waitfordownload`, `responsebody`
- [ ] 注册 Cookie/Storage: `cookies_get`, `cookies_set`, `cookies_clear`, `storage_get`, `storage_set`, `storage_clear`
- [ ] 注册对话框: `dialog`
- [ ] 注册环境模拟: `viewport`, `device`, `emulatemedia`, `offline`, `headers`, `geolocation`, `permissions`, `credentials`
- [ ] 注册脚本注入: `addscript`, `addstyle`, `addinitscript`, `expose`, `dispatch`
- [ ] **验证**: Mock Tauri 应用的 API 请求

### Phase 6: 高级功能
- [ ] 注册 CDP 输入注入: `input_mouse`, `input_keyboard`, `input_touch`
- [ ] 注册 Diff: `diff_snapshot`, `diff_screenshot`, `diff_url`
- [ ] 注册调试录制: `console`, `errors`, `trace_start`, `trace_stop`, `profiler_start`, `profiler_stop`, `har_start`, `har_stop`
- [ ] 注册录屏: `screencast_start`, `screencast_stop`, `recording_start`, `recording_stop`, `recording_restart`
- [ ] 注册状态持久化: `state_save`, `state_load`, `state_list`, `state_clear`, `state_show`, `state_clean`, `state_rename`
- [ ] 注册其他: `focus`, `selectall`, `clipboard`, `multiselect`
- [ ] **验证**: 视觉回归测试 (diff_snapshot + diff_screenshot)

### Phase 7: Tauri 专用工具
- [ ] `lib/tools/tauri.js` (4 个工具实现)
- [ ] `tauri_invoke` — page.evaluate → __TAURI__.core.invoke
- [ ] `tauri_emit` — page.evaluate → __TAURI__.event.emit
- [ ] `tauri_listen` — page.evaluate → __TAURI__.event.once
- [ ] `tauri_app_info` — page.evaluate → __TAURI__.app.*
- [ ] **验证**: 调用 Tauri 后端命令并获取返回值

### Phase 8: 集成测试
- [ ] 用真实 Tauri 应用端到端测试全部工具
- [ ] 压力测试: JS 主线程忙时的响应表现
- [ ] 文档: 用法示例、MCPHub 配置

### Phase 9: E2E Test Helper
- [ ] `lib/test-helper.js` — 导出 `TauriTest` 类
- [ ] 便捷方法封装（snapshot/click/fill/getText/invoke 等）
- [ ] 生命周期方法（start/stop）
- [ ] **验证**: 用 Vitest 编写一个完整的登录流程测试

### Phase 10: E2E 示例套件
- [ ] `e2e/` 目录结构 + Vitest 配置
- [ ] 示例: 基础交互测试（导航、表单填写、按钮点击）
- [ ] 示例: Tauri 后端命令测试（tauri_invoke 验证）
- [ ] 示例: 视觉回归测试（diff_snapshot + diff_screenshot）
- [ ] 示例: 网络 Mock 测试（route + 验证 UI 响应）
- [ ] CI 集成指南（GitHub Actions Windows runner）

---

## E2E 测试架构

### 能力矩阵

tauri-playwright 的工具集天然覆盖 E2E 测试的全部标准需求：

| E2E 测试需求 | 工具 | 说明 |
|---|---|---|
| 启动/关闭被测应用 | `tauri_connect` / `tauri_disconnect` | 管理 Tauri 进程 + CDP 连接 |
| 页面导航与等待 | `navigate`, `waitforurl`, `waitforloadstate` | 支持 load/domcontentloaded/networkidle |
| 元素定位 (CSS) | `snapshot` ref (@e1) + 所有 selector 参数 | 增强版可访问性树 |
| 元素定位 (语义) | `getbyrole/text/label/placeholder/testid` | AI 友好的定位方式 |
| 交互操作 | `click`, `fill`, `type`, `drag`, `select` 等 | 完整的用户操作模拟 |
| 断言 (元素状态) | `isvisible`, `isenabled`, `ischecked`, `gettext`, `count` | 直接查询元素状态 |
| 截图对比 (视觉回归) | `screenshot` + `diff_screenshot` | 像素级差异检测 |
| DOM 快照对比 | `snapshot` + `diff_snapshot` | 结构化差异 |
| 网络 Mock | `route` / `unroute` | 拦截请求并返回 mock 数据 |
| Cookie/Storage | `cookies_*` / `storage_*` | 完整的状态操作 |
| Console/Error 收集 | `console`, `errors` | 捕获前端日志和错误 |
| 调试追踪 | `trace_*`, `har_*`, `profiler_*` | CI 调试、性能分析 |
| Tauri 后端测试 | `tauri_invoke` | 直接调用 Rust Command |
| Tauri 事件测试 | `tauri_emit` / `tauri_listen` | 前后端事件通信 |
| 多窗口 | `tab_list`, `tab_switch`, `window_new` | 多 WebView 切换 |
| 录屏 (CI 回放) | `recording_start/stop` | 失败时回放 |

### 使用模式

#### 模式 A: AI Agent 驱动 (MCP 工具调用)

LLM 通过 MCP 协议直接执行测试流程，无需编写测试脚本。

```
LLM Agent → MCP 工具调用 → tauri-playwright MCP Server → Tauri 应用
```

**特点**:
- 零测试代码，自然语言描述测试场景
- Agent 根据 snapshot 自适应定位元素（ref 体系）
- 适合探索性测试、快速回归验证、开发阶段验证

**示例对话**:
```
用户: 测试登录功能，用户名 admin，密码 secret
Agent: → tauri_connect → snapshot → fill @e1 "admin" → fill @e2 "secret" → click @e3 → waitforurl → gettext → 验证成功
```

#### 模式 B: 脚本化测试 (Test Helper + Vitest)

通过 `lib/test-helper.js` 导出的 `TauriTest` 类，在传统测试框架中编写 E2E 测试。

```
Vitest → TauriTest (test-helper.js) → session.js + bridge.js → agent-browser 核心 → CDP → Tauri
```

**TauriTest** 直接调用 `TauriSession` 和 `dispatch`（同进程），跳过 MCP 协议层，零开销。

### test-helper.js 设计

```javascript
// lib/test-helper.js
import { TauriSession } from './session.js';
import { dispatch } from './bridge.js';

export class TauriTest {
  constructor() {
    this.session = new TauriSession();
  }

  // === 生命周期 ===

  async start(appPath, opts = {}) {
    await this.session.connect({ app_path: appPath, ...opts });
  }

  async stop() {
    await this.session.disconnect();
  }

  // === 快照 ===

  async snapshot(opts = {}) {
    const res = await this._dispatch('snapshot', opts);
    return res;  // 返回可访问性树文本 (含 ref)
  }

  async screenshot(opts = {}) {
    return this._dispatch('screenshot', opts);
  }

  // === 交互 ===

  async click(selector, opts = {}) {
    return this._dispatch('click', { selector, ...opts });
  }

  async dblclick(selector) {
    return this._dispatch('dblclick', { selector });
  }

  async fill(selector, value) {
    return this._dispatch('fill', { selector, value });
  }

  async type(selector, text, opts = {}) {
    return this._dispatch('type', { selector, text, ...opts });
  }

  async check(selector) {
    return this._dispatch('check', { selector });
  }

  async uncheck(selector) {
    return this._dispatch('uncheck', { selector });
  }

  async select(selector, values) {
    return this._dispatch('select', { selector, values });
  }

  async hover(selector) {
    return this._dispatch('hover', { selector });
  }

  async drag(source, target) {
    return this._dispatch('drag', { source, target });
  }

  async press(key, selector) {
    return this._dispatch('press', { key, ...(selector ? { selector } : {}) });
  }

  async upload(selector, files) {
    return this._dispatch('upload', { selector, files });
  }

  // === 语义化定位 ===

  async getByRole(role, name, subaction, value) {
    return this._dispatch('getbyrole', { role, name, subaction, ...(value ? { value } : {}) });
  }

  async getByText(text, subaction, opts = {}) {
    return this._dispatch('getbytext', { text, subaction, ...opts });
  }

  async getByLabel(label, subaction, opts = {}) {
    return this._dispatch('getbylabel', { label, subaction, ...opts });
  }

  async getByTestId(testId, subaction, opts = {}) {
    return this._dispatch('getbytestid', { testId, subaction, ...opts });
  }

  // === 查询 (断言用) ===

  async getText(selector) {
    return this._dispatch('gettext', { selector });
  }

  async getAttribute(selector, attribute) {
    return this._dispatch('getattribute', { selector, attribute });
  }

  async isVisible(selector) {
    return this._dispatch('isvisible', { selector });
  }

  async isEnabled(selector) {
    return this._dispatch('isenabled', { selector });
  }

  async isChecked(selector) {
    return this._dispatch('ischecked', { selector });
  }

  async count(selector) {
    return this._dispatch('count', { selector });
  }

  async inputValue(selector) {
    return this._dispatch('inputvalue', { selector });
  }

  // === 等待 ===

  async wait(selector, opts = {}) {
    return this._dispatch('wait', { selector, ...opts });
  }

  async waitForUrl(url, timeout) {
    return this._dispatch('waitforurl', { url, ...(timeout ? { timeout } : {}) });
  }

  async waitForLoadState(state, timeout) {
    return this._dispatch('waitforloadstate', { state, ...(timeout ? { timeout } : {}) });
  }

  async waitForFunction(expression, timeout) {
    return this._dispatch('waitforfunction', { expression, ...(timeout ? { timeout } : {}) });
  }

  // === 导航 ===

  async navigate(url, opts = {}) {
    return this._dispatch('navigate', { url, ...opts });
  }

  async back() { return this._dispatch('back', {}); }
  async forward() { return this._dispatch('forward', {}); }
  async reload() { return this._dispatch('reload', {}); }
  async url() { return this._dispatch('url', {}); }
  async title() { return this._dispatch('title', {}); }

  // === 页面内容 ===

  async evaluate(script, args) {
    return this._dispatch('evaluate', { script, ...(args ? { args } : {}) });
  }

  async content(selector) {
    return this._dispatch('content', selector ? { selector } : {});
  }

  // === 网络 ===

  async route(url, response, abort) {
    return this._dispatch('route', { url, ...(response ? { response } : {}), ...(abort ? { abort } : {}) });
  }

  async unroute(url) {
    return this._dispatch('unroute', url ? { url } : {});
  }

  async requests(filter) {
    return this._dispatch('requests', filter ? { filter } : {});
  }

  // === Diff (视觉回归) ===

  async diffSnapshot(opts = {}) {
    return this._dispatch('diff_snapshot', opts);
  }

  async diffScreenshot(baseline, opts = {}) {
    return this._dispatch('diff_screenshot', { baseline, ...opts });
  }

  // === Cookie/Storage ===

  async getCookies(urls) {
    return this._dispatch('cookies_get', urls ? { urls } : {});
  }

  async setCookies(cookies) {
    return this._dispatch('cookies_set', { cookies });
  }

  async clearCookies() {
    return this._dispatch('cookies_clear', {});
  }

  async getStorage(type, key) {
    return this._dispatch('storage_get', { type, ...(key ? { key } : {}) });
  }

  async setStorage(type, key, value) {
    return this._dispatch('storage_set', { type, key, value });
  }

  async clearStorage(type) {
    return this._dispatch('storage_clear', { type });
  }

  // === Tauri 专用 ===

  async invoke(command, args = {}) {
    return this._dispatch('tauri_invoke', { command, args });
  }

  async emit(event, payload) {
    return this._dispatch('tauri_emit', { event, ...(payload !== undefined ? { payload } : {}) });
  }

  async listen(event, timeout) {
    return this._dispatch('tauri_listen', { event, ...(timeout ? { timeout } : {}) });
  }

  async appInfo() {
    return this._dispatch('tauri_app_info', {});
  }

  // === 调试 ===

  async console(clear) {
    return this._dispatch('console', clear ? { clear } : {});
  }

  async errors(clear) {
    return this._dispatch('errors', clear ? { clear } : {});
  }

  // === 内部 ===

  async _dispatch(action, params) {
    const result = await dispatch(action, params, this.session.browser);
    if (result.isError) {
      const errData = JSON.parse(result.content[0].text);
      throw new Error(`[${action}] ${errData.message}`);
    }
    return JSON.parse(result.content[0].text);
  }
}
```

### E2E 测试示例

#### Vitest 配置

```javascript
// e2e/vitest.config.js
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    testTimeout: 60000,          // E2E 测试需要更长超时
    hookTimeout: 30000,
    pool: 'forks',               // 进程隔离
    poolOptions: { forks: { singleFork: true } },  // 串行执行 (共享一个 Tauri 实例)
    include: ['e2e/**/*.test.js'],
    globalSetup: ['e2e/global-setup.js'],
  },
});
```

#### 全局 Setup

```javascript
// e2e/global-setup.js
import { TauriTest } from '../lib/test-helper.js';

let app;

export async function setup() {
  app = new TauriTest();
  await app.start('./target/release/my-app.exe', { port: 9222 });
  globalThis.__TAURI_TEST__ = app;
}

export async function teardown() {
  await globalThis.__TAURI_TEST__?.stop();
}
```

#### 示例 1: 基础交互

```javascript
// e2e/basic-interaction.test.js
import { describe, test, expect, beforeAll } from 'vitest';

const app = () => globalThis.__TAURI_TEST__;

describe('基础交互', () => {
  test('导航到首页', async () => {
    await app().navigate('tauri://localhost/');
    await app().waitForLoadState('networkidle');
    const t = await app().title();
    expect(t).toBe('My Tauri App');
  });

  test('表单填写与提交', async () => {
    // 使用语义化定位
    await app().getByRole('textbox', 'Username', 'fill', 'admin');
    await app().getByRole('textbox', 'Password', 'fill', 'secret123');
    await app().getByRole('button', 'Submit', 'click');

    // 等待导航
    await app().waitForUrl('**/dashboard');

    // 断言
    const welcome = await app().getText('.welcome-message');
    expect(welcome).toContain('Welcome, admin');
  });

  test('元素状态查询', async () => {
    const visible = await app().isVisible('.sidebar');
    expect(visible).toBe(true);

    const count = await app().count('.menu-item');
    expect(count).toBeGreaterThan(0);
  });
});
```

#### 示例 2: Tauri 后端命令测试

```javascript
// e2e/tauri-backend.test.js
import { describe, test, expect } from 'vitest';

const app = () => globalThis.__TAURI_TEST__;

describe('Tauri 后端命令', () => {
  test('invoke: 获取配置', async () => {
    const config = await app().invoke('get_config');
    expect(config).toHaveProperty('theme');
    expect(config).toHaveProperty('language');
  });

  test('invoke: 保存数据', async () => {
    const result = await app().invoke('save_item', {
      name: 'test-item',
      value: 42,
    });
    expect(result.success).toBe(true);
  });

  test('事件通信', async () => {
    // 监听后端事件 (先注册监听)
    const listenPromise = app().listen('data-updated', 5000);

    // 触发操作
    await app().invoke('trigger_update', { id: 1 });

    // 等待事件
    const event = await listenPromise;
    expect(event.payload).toHaveProperty('id', 1);
  });
});
```

#### 示例 3: 视觉回归测试

```javascript
// e2e/visual-regression.test.js
import { describe, test, expect } from 'vitest';
import { existsSync } from 'fs';

const app = () => globalThis.__TAURI_TEST__;

describe('视觉回归', () => {
  test('首页快照对比', async () => {
    await app().navigate('tauri://localhost/');
    await app().waitForLoadState('networkidle');

    const diff = await app().diffSnapshot({ compact: true });

    if (diff.changes === 0) {
      // 无变化
      return;
    }

    // 有变化时输出 diff 详情供人工审查
    console.log('Snapshot diff:', JSON.stringify(diff, null, 2));
    // 根据策略决定是否 fail
  });

  test('截图像素对比', async () => {
    const baseline = 'e2e/baselines/dashboard.png';

    await app().navigate('tauri://localhost/dashboard');
    await app().waitForLoadState('networkidle');

    if (!existsSync(baseline)) {
      // 首次运行，生成基线
      await app().screenshot({ path: baseline });
      return;
    }

    const diff = await app().diffScreenshot(baseline, {
      threshold: 0.01,     // 1% 容差
      output: 'e2e/diffs/dashboard-diff.png',
    });

    expect(diff.mismatchPercentage).toBeLessThan(1);
  });
});
```

#### 示例 4: 网络 Mock 测试

```javascript
// e2e/network-mock.test.js
import { describe, test, expect, afterEach } from 'vitest';

const app = () => globalThis.__TAURI_TEST__;

describe('网络 Mock', () => {
  afterEach(async () => {
    await app().unroute();  // 清除所有 route
  });

  test('Mock API 响应', async () => {
    // 拦截 API 请求
    await app().route('**/api/users', {
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify([
        { id: 1, name: 'Mock User 1' },
        { id: 2, name: 'Mock User 2' },
      ]),
    });

    // 触发 UI 加载
    await app().navigate('tauri://localhost/users');
    await app().waitForLoadState('networkidle');

    // 验证 UI 显示 mock 数据
    const count = await app().count('.user-card');
    expect(count).toBe(2);

    const name = await app().getText('.user-card:first-child .name');
    expect(name).toBe('Mock User 1');
  });

  test('模拟网络错误', async () => {
    await app().route('**/api/data', { abort: true });

    await app().navigate('tauri://localhost/data');
    await app().waitForLoadState('networkidle');

    const errorVisible = await app().isVisible('.error-message');
    expect(errorVisible).toBe(true);
  });
});
```

### CI 集成 (GitHub Actions)

```yaml
# .github/workflows/e2e.yml
name: E2E Tests (Windows)

on: [push, pull_request]

jobs:
  e2e:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4

      - uses: pnpm/action-setup@v4
        with:
          version: 9

      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: pnpm

      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable

      - name: Build Tauri app
        run: pnpm tauri build

      - name: Install test deps
        run: pnpm install
        working-directory: mcp-servers/tauri-playwright

      - name: Install Playwright browsers
        run: npx playwright install chromium

      - name: Run E2E tests
        run: pnpm vitest run --config e2e/vitest.config.js
        working-directory: mcp-servers/tauri-playwright
        env:
          TAURI_APP_PATH: ../../target/release/my-app.exe

      - name: Upload test artifacts
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: e2e-artifacts
          path: |
            mcp-servers/tauri-playwright/e2e/diffs/
            mcp-servers/tauri-playwright/e2e/recordings/
```

---

## 附录

### A. agent-browser 模块导出清单

本项目使用的 agent-browser 导出：

| 模块 | 导出 | 用途 |
|------|------|------|
| `dist/browser.js` | `BrowserManager` (class) | 浏览器管理核心 |
| `dist/browser.js` | `getDefaultTimeout` (function) | 获取默认超时 |
| `dist/actions.js` | `executeCommand` (function) | 执行命令 |
| `dist/actions.js` | `initActionPolicy` (function) | 初始化安全策略 |
| `dist/actions.js` | `toAIFriendlyError` (function) | 错误格式化 |
| `dist/actions.js` | `setScreencastFrameCallback` (function) | 设置录屏回调 |
| `dist/protocol.js` | `parseCommand` (function) | 命令解析验证 |
| `dist/protocol.js` | `successResponse` (function) | 成功响应构造 |
| `dist/protocol.js` | `errorResponse` (function) | 错误响应构造 |
| `dist/snapshot.js` | `getEnhancedSnapshot` (function) | 增强快照 |
| `dist/snapshot.js` | `parseRef` (function) | 解析 ref |
| `dist/snapshot.js` | `resetRefs` (function) | 重置 ref 计数器 |
| `dist/diff.js` | `diffSnapshots` (function) | 快照差异 |
| `dist/diff.js` | `diffScreenshots` (function) | 截图差异 |
| `dist/types.js` | 所有 Command/Response 类型 | TypeScript 类型 |

### B. BrowserManager.launch() 参数与 tauri_connect 的关系

```javascript
// tauri_connect 内部调用:
await browser.launch({
  id: 'tauri-connect',
  action: 'launch',
  cdpPort: port,      // ← 连接 Tauri WebView2 的 CDP 端口
  headless: false,     // ← Tauri 应用有 GUI
});
```

BrowserManager.launch() 检测到 `cdpPort` 后会调用内部的 `connectViaCDP()` 方法，该方法：
1. 构造 CDP URL: `http://localhost:${port}`
2. 调用 `chromium.connectOverCDP(cdpUrl)`
3. 获取已有的 context 和 page（Tauri 应用的 WebView）

### C. Zod Schema 权威来源

所有工具的参数定义以 `agent-browser/src/protocol.ts` 中的 Zod schema 为权威来源。本文档中的参数表是对这些 schema 的人类可读翻译。实施时应参照 protocol.ts 原文确保一致性。

文件位置: `<agent-browser-root>/src/protocol.ts`（`<agent-browser-root>` 为本地 agent-browser checkout 根目录）
Schema 数量: 约 100 个
Union schema: `commandSchema` (L929-L1072)
