# WinGUI Bridge — 环境配置

源码由当前仓库的 `tools/wingui/` 管理，Windows 直接读取 WSL UNC 源码，不需要 Windows 源码副本或源码目录内的 Windows 虚拟环境。

## 前置条件

- WSL2：`uv`、`wslpath`、Windows interop 可用。
- Windows：Python >=3.10，`pythonw.exe` 在 Windows PATH 可解析；处于已登录的交互桌面会话。
- 两侧能访问 `127.0.0.1:19527`，Windows 能读取 `wslpath -w` 返回的源码路径。

## WSL 安装入口

在 Maxa monorepo 根目录执行：

```bash
uv sync --project tools/wingui
mkdir -p ~/.local/bin
ln -s "$(pwd)/tools/wingui/runwingui" ~/.local/bin/runwingui
```

若该入口已经存在，先检查其所有者和目标，再有意识地切换；不要覆盖无关程序。跨项目使用保持同一 PATH 入口，不依赖当前 Chat 的工作目录。

## Windows 启动

```bash
runwingui --start-server
runwingui --health
```

启动器从自身目录推导 UNC 源码路径，在 `%LOCALAPPDATA%\Maxa\wingui\start-server.bat` 生成本地启动入口，再通过 Explorer 启动本地 Python。该文件是可再生成的机器运行数据，不是第二份源码；不需要修改 Windows 信任区域或关闭安全提示。

源码更新后运行 `runwingui --restart-server`。WSL 必须保持运行、源码路径必须可访问；当前方案不创建开机服务或 keepalive。使用/验证边界见 [README.md](./README.md)。
