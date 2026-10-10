# WinCtl 使用模式

先 `load(target="winctl")`，再通过有非空 title 的 `run(scope="tool")` 调用 `@winctl:/scripts/winctl.py`。以下 YAML 列表表示依次发出的工具调用，不是一次批量执行；观察前一步结果后再执行依赖步骤。数组 `args` 是字面 argv，action 的 JSON 参数占一个字符串。示例 hwnd、坐标必须替换为实际观察值。

## 模式 1: 截图 → 分析 → 操作 → 验证

最常用的调试闭环。

```yaml
# 1. 截图观察
- run: {title: "观察桌面", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["screenshot_desktop", '{"format":"jpeg","quality":70}']}
# 2. 用返回 saved_to 调用 analyze，直接使用其报告确定坐标
- analyze:
    images: [{path: "<saved_to>", detail: "original"}]
    analysis_prompt: "Identify task-relevant controls and report screenshot-relative coordinates with uncertainty."
    max_steps: 1
# 3. 根据已核实坐标执行操作
- run: {title: "点击已核实坐标", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["mouse_click", '{"x":800,"y":400}']}
# 4. 再次截图验证
- run: {title: "验证操作结果", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["screenshot_desktop", '{"format":"jpeg","quality":70}']}
```

## 模式 2: 聚焦窗口 → 截图

```yaml
- run: {title: "查找 Chrome 窗口", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["list_windows", '{"filter":"Chrome"}']}
- run: {title: "聚焦已核实窗口", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["focus_window", '{"hwnd":123456}']}
- run: {title: "观察目标窗口", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["screenshot_window", '{"hwnd":123456,"format":"jpeg"}']}
```

## 模式 3: 剪贴板粘贴

向输入框填入内容（比 key_type 更可靠，支持中文和特殊字符）。先从 `list_windows` 核实目标，再执行：

```yaml
- run: {title: "聚焦记事本", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["focus_window", '{"title":"Notepad"}']}
- run: {title: "定位已核实输入框", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["mouse_click", '{"x":500,"y":300}']}
- run: {title: "设置待粘贴文本", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["set_clipboard", '{"text":"要粘贴的内容，支持中文"}']}
- run: {title: "粘贴文本", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["key_hotkey", '{"keys":["ctrl","v"]}']}
```

## 模式 4: 打开开发者工具

```yaml
- run: {title: "查找浏览器窗口", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["list_windows", '{"filter":"Chrome"}']}
- run: {title: "聚焦浏览器", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["focus_window", '{"hwnd":123456}']}
- run: {title: "打开开发者工具", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["key_hotkey", '{"keys":["ctrl","shift","i"]}']}
- run: {title: "验证开发者工具", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["screenshot_desktop"]}
```

## 模式 5: 调整窗口布局后截图

```yaml
- run: {title: "调整目标窗口布局", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["resize_window", '{"hwnd":123456,"x":0,"y":0,"width":1920,"height":1080}']}
- run: {title: "聚焦调整后的窗口", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["focus_window", '{"hwnd":123456}']}
- run: {title: "验证窗口布局", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["screenshot_window", '{"hwnd":123456}']}
```

## 模式 6: 滚动后截图

```yaml
# 确保焦点
- run: {title: "聚焦已核实区域", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["mouse_click", '{"x":960,"y":540}']}
- run: {title: "滚动目标区域", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["mouse_scroll", '{"amount":-5}']}
- run: {title: "验证滚动结果", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["screenshot_desktop"]}
```

## 模式 7: 窗口相对坐标操作

比桌面坐标更精确，不受窗口位置影响。坐标来源于 `screenshot_window` 截图像素。

```yaml
- run: {title: "观察窗口相对坐标", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["screenshot_window", '{"hwnd":123456,"format":"jpeg"}']}
# 分析截图确定相对坐标后点击
- run: {title: "点击窗口内已核实位置", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["click_in_window", '{"hwnd":123456,"x":200,"y":50}']}
# 或 PostMessage 拖拽（更精确）
- run: {title: "拖拽窗口内已核实区域", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["window_drag", '{"hwnd":123456,"from_x":200,"from_y":50,"to_x":400,"to_y":300,"steps":20}']}
```

## 模式 8: 查找子窗口（WebView2）

Tauri 应用中 WebView2 是子窗口，需要对子窗口操作。

```yaml
- run: {title: "查找 WebView2 子窗口", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["find_child_window", '{"hwnd":123456}']}
# 从返回结果核实 WebView2（class 含 Chrome_）的子窗口 hwnd
- run: {title: "点击已核实子窗口位置", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["click_in_window", '{"hwnd":789012,"x":100,"y":200}']}
```

## 模式 9: 读取页面文本

在已确认并聚焦的目标窗口执行：

```yaml
# 全选、复制、读取
- run: {title: "全选目标页面文本", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["key_hotkey", '{"keys":["ctrl","a"]}']}
- run: {title: "复制页面文本", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["key_hotkey", '{"keys":["ctrl","c"]}']}
- run: {title: "读取页面剪贴板文本", scope: tool, command: "@winctl:/scripts/winctl.py", args: ["get_clipboard"]}
```

## 常用按键名

`key_press` 和 `key_hotkey` 使用 pyautogui 键名：

| 类别 | 键名 |
|------|------|
| 功能键 | `f1` - `f12` |
| 控制键 | `enter`, `escape`, `tab`, `space`, `backspace`, `delete` |
| 方向键 | `up`, `down`, `left`, `right` |
| 导航键 | `home`, `end`, `pageup`, `pagedown` |
| 修饰键 | `ctrl`, `alt`, `shift`, `win` |
| 特殊 | `printscreen`, `capslock`, `numlock` |
