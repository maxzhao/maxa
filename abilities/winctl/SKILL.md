---
name: winctl
description: "作用：指导 Agent 从 WSL 控制 Windows 桌面并维护 winctl-server 自动化能力，适合截图观察、窗口管理、鼠标键盘、剪贴板、虚拟桌面操作、坐标验证和新增/调试 winctl 动作。"
compatibility: Requires Maxa Ability runtime.
---
# WinCtl - Windows 桌面控制

Windows 桌面自动化：截图、窗口管理、鼠标键盘、虚拟桌面、剪贴板。

> **信息分层**: 本文档提供**坐标系、决策树和关键约束**。
> 参数签名通过已编目脚本的 `--help` 查看。
> 操作模式用 `read(path="#winctl[/references/patterns.md]")` 读取。

**调用方式**：先 `load(target="winctl")`，再通过有非空 title 的 `run(scope="tool", command="@winctl:/scripts/winctl.py")` 调用脚本；executor 负责 Python/uv。数组 `args` 为字面 argv，action 的 JSON 参数必须作为一个字符串传入，不拼接 Shell 命令。

```yaml
# 帮助 / action 列表
- run: {title: "查看桌面工具帮助", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["--help"]}
- run: {title: "列出桌面动作", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["--list"]}
# 独立示例；点击坐标必须来自实际截图
- run: {title: "观察桌面", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["screenshot_desktop", '{"format":"jpeg","quality":70}']}
- run: {title: "点击已核实坐标", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["mouse_click", '{"x":800,"y":400}']}
- run: {title: "列出窗口", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["list_windows"]}
- run: {title: "查找 Chrome 窗口", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["list_windows", '{"filter":"Chrome"}']}
```

**常用场景模板**（每个场景内按顺序调用，观察结果后再执行依赖步骤）：

```yaml
# 场景 1：找窗口 → 聚焦 → 截图验证
- run: {title: "查找目标窗口", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["list_windows", '{"filter":"Chrome"}']}
- run: {title: "聚焦目标窗口", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["focus_window", '{"title":"Chrome"}']}
- run: {title: "验证窗口截图", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["screenshot_window", '{"title":"Chrome","format":"jpeg","quality":70}']}
# 场景 2：截图后按已核实的桌面坐标点击
- run: {title: "观察桌面坐标", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["screenshot_desktop", '{"format":"jpeg","quality":70}']}
- run: {title: "点击已核实坐标", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["mouse_click", '{"x":800,"y":400}']}
# 场景 3：向已聚焦窗口粘贴中文
- run: {title: "设置粘贴文本", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["set_clipboard", '{"text":"你好，世界"}']}
- run: {title: "粘贴文本", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["key_hotkey", '{"keys":["ctrl","v"]}']}
```

**环境**: WSL2 → Windows（TCP Socket 127.0.0.1:9527）。若 Server 未运行，脚本会尝试自动启动；自动启动需配置 `WINCTL_SERVER_START_CMD`，或配置 `WINCTL_SERVER_CWD` 后由脚本生成 `runwingui --detach --cwd <WINCTL_SERVER_CWD> python server.py`。

## 工具分类速查

| 分类 | 工具 | 用途 |
|------|------|------|
| **截图** | `screenshot_desktop`, `screenshot_window` | 桌面/窗口截图 |
| **窗口** | `list_windows`, `get_window_info`, `focus_window`, `resize_window`, `find_child_window` | 查找/聚焦/调整窗口 |
| **鼠标（桌面）** | `mouse_move`, `mouse_click`, `mouse_drag`, `mouse_scroll` | 桌面坐标操作 |
| **鼠标（窗口）** | `click_in_window`, `drag_in_window`, `window_drag` | 窗口相对坐标操作 |
| **键盘** | `key_type`, `key_press`, `key_hotkey` | 文本输入/按键/组合键 |
| **剪贴板** | `get_clipboard`, `set_clipboard` | 读写剪贴板 |
| **虚拟桌面** | `list_desktops`, `switch_desktop`, `move_window_to_desktop` | 桌面切换/窗口移动 |
| **其他** | `get_cursor_position`, `get_dpi_info`, `post_message` | 光标/DPI/Win32 消息 |

## 坐标系

**所有坐标使用物理像素**（与截图像素一一对应），Server 内部自动处理 DPI 缩放。

| 类型 | 原点 | 工具 | 坐标来源 |
|------|------|------|---------|
| 桌面坐标 | 屏幕左上角 | `mouse_move/click/drag/scroll` | `screenshot_desktop` |
| 窗口坐标 | 窗口左上角 | `click_in_window/drag_in_window/window_drag` | `screenshot_window` |

## 决策树

### 观察

| 需求 | 工具 |
|------|------|
| 看整个桌面 | `screenshot_desktop` |
| 看特定窗口 | `screenshot_window` |
| 找某个窗口 | `list_windows` |
| 确认鼠标位置 | `get_cursor_position` |
| 确认剪贴板 | `get_clipboard` |

### 窗口操作

| 需求 | 工具 |
|------|------|
| 调到前台 | `focus_window` |
| 调整大小/位置 | `resize_window` |
| 查找子窗口 | `find_child_window` |
| 移到其他桌面 | `move_window_to_desktop` |
| 查看 DPI | `get_dpi_info` |

### 交互操作

| 需求 | 工具 |
|------|------|
| 点击（桌面坐标） | `mouse_click` |
| 点击（窗口坐标） | `click_in_window` |
| 悬停 | `mouse_move` |
| 拖拽（桌面坐标） | `mouse_drag` |
| 拖拽（窗口坐标） | `drag_in_window` 或 `window_drag` |
| 滚动 | `mouse_scroll` |
| 按键 | `key_press` |
| 组合键 | `key_hotkey` |
| 输入文字 | `key_type` |
| 粘贴内容 | `set_clipboard` → `key_hotkey(['ctrl','v'])` |
| Win32 消息 | `post_message` |

## 截图分析

截图工具**不返回 base64**，只返回文件路径。分析截图内容时，默认分析返回的 `saved_to` 路径，并让报告包含可操作控件、文本和截图坐标：

```yaml
analyze:
  images:
    - path: "<saved_to>"
      detail: "original"
  analysis_prompt: "Identify task-relevant controls and text, report their screenshot-relative coordinates, and state any uncertainty."
  max_steps: 1
```

直接使用 `analyze` 返回的报告结果；图片分析结果不使用 TTL/`keep` 管理。

如果截图分析是独立子问题、适合委托给子代理，先加载 `subagent`，再按该 Ability 的说明使用子代理并传入截图路径；不要在本 Ability 中硬编码子代理工具参数。

## 操作约束

- 从 `list_windows` 的实际结果获取 hwnd。
- 对被遮挡窗口进行键盘操作前，先调用 `focus_window`。
- 操作后截图验证结果。
- 中文输入使用 `set_clipboard` + `Ctrl+V`。

## 错误处理

| 错误 | 原因 | 解决 |
|------|------|------|
| `Server not running` | winctl-server 未启动 | 配置 `WINCTL_SERVER_START_CMD` 或 `WINCTL_SERVER_CWD` 后重试；也可先手动启动 Server |
| `Invalid window handle` | hwnd 已失效 | 重新 `list_windows` 获取 |
| `Window not found: xxx` | 标题不匹配 | 用 `list_windows` + `filter` 查找 |
| `SetForegroundWindow` 失败 | 极少数 workaround 不生效 | 先 `mouse_click` 窗口区域再操作 |
| `Connection refused` | Server 进程崩溃 | 重新调用任意工具（自动重启） |

## References

| Reference | When to read |
|-----------|-------------|
| [references/patterns.md](references/patterns.md) | 9 个使用模式（截图→分析→操作→验证、剪贴板粘贴、窗口相对坐标等）+ 常用按键名 |
| [references/development/server-dev.md](references/development/server-dev.md) | Windows 端 Server 开发指导：协议规范、新增 action 步骤、DPI/截图/PostMessage 等实现模式；仅在维护或扩展 winctl-server 时读取 |

