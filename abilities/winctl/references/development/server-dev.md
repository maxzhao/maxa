# WinCtl Server 开发指导

Windows 端 Python 服务，运行在 Windows 上，通过 TCP Socket 提供桌面自动化能力。

## 项目信息

| 项 | 值 |
|----|-----|
| Server 根目录 | 由 `WINCTL_SERVER_CWD` 指定；也可用 `WINCTL_SERVER_START_CMD` 完全自定义启动命令 |
| 入口 | `server.py`（具体位置以 `WINCTL_SERVER_CWD` 为准） |
| 启动 | `python server.py`（监听 0.0.0.0:9527） |
| 依赖 | `dxcam`, `pywin32`, `pyvda`, `pyautogui`, `Pillow` |

## 架构

```
WSL (winctl.py)  ──TCP:9527──>  Windows (server.py)
                                    │
                   WinCtlServer 类（单线程，顺序处理）
                   ├── self.handlers: Dict[str, Callable]  ← 方法路由表
                   ├── self.camera: DXCam 实例（懒加载）
                   └── self._scale_x/y: 物理→pyautogui 坐标缩放比
```

**线程模型**: 单线程同步。`server_socket.accept()` → `handle_client()` → 处理完断开 → 下一个连接。每个请求独占连接。

## 协议规范

**传输**: TCP，换行符 `\n` 分隔 JSON 消息。

**请求**:
```json
{"id": 1234, "method": "mouse_click", "params": {"x": 800, "y": 400}}
```

**成功响应**:
```json
{"id": 1234, "result": {"success": true, "button": "left", "clicks": 1}}
```

**错误响应**:
```json
{"id": 1234, "error": {"code": -32603, "message": "Internal error: ...", "data": "traceback..."}}
```

**错误码**: `-32700` 解析错误 | `-32600` 无效请求 | `-32601` 方法不存在 | `-32603` 内部错误

## 新增 Action 步骤

### 1. Server 端：添加 handler 方法

在 `WinCtlServer` 类中添加 `handle_<action>` 方法：

```python
def handle_my_action(self, params: Dict[str, Any]) -> Dict[str, Any]:
    """One-line description"""
    # 1. 提取参数
    value = params.get('value')
    optional = params.get('optional', 'default')

    # 2. 验证
    if value is None:
        raise ValueError("'value' is required")

    # 3. 执行操作
    result = do_something(value, optional)

    # 4. 返回结果 dict（自动包装为 {"id": ..., "result": <这里>}）
    return {'success': True, 'data': result}
```

然后在 `__init__` 的 `self.handlers` 字典中注册：

```python
self.handlers = {
    # ...existing handlers...
    'my_action': self.handle_my_action,
}
```

### 2. 客户端：同步更新 winctl.py

在 `abilities/winctl/scripts/winctl.py` 的 `ACTIONS` 字典中添加条目：

```python
ACTIONS = {
    # ...existing actions...
    "my_action": {
        "description": "One-line description",
        "params": {
            "value": {"type": "string", "required": True, "description": "..."},
            "optional": {"type": "string", "default": "default", "description": "..."},
        },
    },
}
```

如果有特殊验证逻辑（如 one_of），在 `validate_params()` 中添加。
如果需要后处理（如截图的 base64→file），在 `post_process()` 中添加。

## 关键实现模式

### DPI 坐标转换

Server 接收**物理像素坐标**（与截图像素 1:1），内部转换为 pyautogui 逻辑坐标：

```python
# 启动时检测缩放比
self._scale_x = pyautogui.size().width / GetSystemMetrics(SM_CXVIRTUALSCREEN)
self._scale_y = pyautogui.size().height / GetSystemMetrics(SM_CYVIRTUALSCREEN)

# 物理→pyautogui
def _to_pag_coords(self, x, y):
    return int(x * self._scale_x), int(y * self._scale_y)
```

### 截图（DXCam + pyautogui fallback）

```python
# 优先 DXCam（GPU 加速，支持全屏游戏/UE Editor）
self.initialize_camera()  # 懒加载
frame = self.camera.grab()  # 或 grab(region=rect)
img = Image.fromarray(frame)

# 失败时降级到 pyautogui（GDI 截图）
img = pyautogui.screenshot()

# 编码为 base64 返回（客户端负责解码写文件）
img_base64 = base64.b64encode(buffer.getvalue()).decode('utf-8')
return {'image': img_base64, 'width': img.width, 'height': img.height, ...}
```

### 窗口标识：hwnd/title 二选一

多个方法共享此模式（focus_window, get_window_info, resize_window, click_in_window, ...）：

```python
hwnd = params.get('hwnd')
title = params.get('title')
if not hwnd and not title:
    raise ValueError("Either 'hwnd' or 'title' must be provided")
if title and not hwnd:
    hwnd = win32gui.FindWindow(None, title)
    if not hwnd:
        raise ValueError(f"Window not found: {title}")
```

### 窗口聚焦（绕过 SetForegroundWindow 限制）

Windows 阻止后台进程窃取焦点。通过 AttachThreadInput + Alt 键模拟绕过：

```python
# 附加线程输入 → Alt 键按放 → SetForegroundWindow → 分离线程
ctypes.windll.user32.AttachThreadInput(current_thread, target_thread, True)
ctypes.windll.user32.keybd_event(0x12, 0, 0, 0)   # Alt down
ctypes.windll.user32.keybd_event(0x12, 0, 2, 0)   # Alt up
win32gui.SetForegroundWindow(hwnd)
```

### Win32 PostMessage 直发（window_drag / post_message）

绕过系统级输入，直接向窗口发送消息。适用于被遮挡/离屏的窗口，或 Tauri WebView：

```python
def make_lparam(x, y):
    return (int(y) << 16) | (int(x) & 0xFFFF)

post = ctypes.windll.user32.PostMessageW
post(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, make_lparam(x, y))
# ... WM_MOUSEMOVE steps ...
post(hwnd, WM_LBUTTONUP, 0, make_lparam(to_x, to_y))
```

### 窗口相对坐标（click_in_window / drag_in_window）

通过 Win32 `ClientToScreen` 将窗口客户区坐标转为屏幕坐标，再转 pyautogui 坐标：

```python
point = ctypes.wintypes.POINT(int(x), int(y))
ctypes.windll.user32.ClientToScreen(hwnd, ctypes.byref(point))
pag_x, pag_y = self._to_pag_coords(point.x, point.y)
pyautogui.click(pag_x, pag_y)
```

### 懒加载模块

pyvda（虚拟桌面）和 dxcam 都是首次使用时加载，避免启动慢或依赖缺失阻塞其他功能：

```python
global _pyvda
if _pyvda is None:
    from pyvda import AppView, VirtualDesktop, get_virtual_desktops
    _pyvda = {'AppView': AppView, ...}
```

## 注意事项

- **pyautogui.FAILSAFE = False**：已禁用鼠标角落保护，避免自动化中断
- **Lua 空表兼容**：`handle_request` 中将 `params: list` 转为 `{}`（Lua `vim.json.encode({})` 产生 `[]`）
- **重启 Server**：修改 `server.py` 后需在 Windows 端重启进程（关闭旧进程 → `python server.py`）
- **客户端自动启动**：`winctl.py` 检测到 Server 未运行时，优先执行 `WINCTL_SERVER_START_CMD`；未设置时使用 `WINCTL_SERVER_CWD` 生成 `runwingui --detach --cwd <WINCTL_SERVER_CWD> python server.py`
