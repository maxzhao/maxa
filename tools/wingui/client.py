#!/usr/bin/env python3
"""
WinGUI Bridge Client
====================
WSL2 端客户端，发送命令到 Windows 端服务器执行。

用法:
    python client.py <command> [args...]
    python client.py --kill <process_id>
    python client.py --list

示例:
    python client.py notepad.exe
    python client.py cmd /c dir
"""

import sys
import json
import signal
import argparse
import urllib.request
import urllib.error
from typing import Optional

# ============================================================================
# Configuration
# ============================================================================

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 19527

# 全局变量：当前运行的进程 ID（用于信号处理）
_current_process_id: Optional[str] = None
_client: Optional["WinGUIClient"] = None
_cancel_requested = False


# ANSI 颜色
class Colors:
    RESET = "\033[0m"
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"
    GRAY = "\033[90m"


def color(text: str, c: str) -> str:
    """添加颜色"""
    if not sys.stdout.isatty():
        return text
    return f"{c}{text}{Colors.RESET}"


# ============================================================================
# Signal Handler
# ============================================================================


def sigint_handler(signum, frame):
    """Ctrl+C 信号处理：终止远程进程并退出"""
    global _current_process_id, _client, _cancel_requested
    _cancel_requested = True
    # A signal can arrive while POST /run is awaiting its process id. Let the
    # bounded request finish so cmd_run can cancel the process it actually owns.
    if _current_process_id is None:
        return

    print(color("\n[Interrupted] Terminating remote process...", Colors.YELLOW))

    if _current_process_id and _client:
        try:
            # 使用短超时发送 kill 请求，不等待响应
            # 因为信号处理器中的网络请求可能不稳定
            _client.kill_async(_current_process_id)
            print(color(f"Process {_current_process_id} terminated", Colors.YELLOW))
        except Exception as e:
            print(color(f"Failed to terminate: {e}", Colors.RED))

    sys.exit(130)  # 128 + SIGINT(2)


# ============================================================================
# HTTP Client
# ============================================================================


class WinGUIClient:
    """WinGUI 桥接客户端"""

    def __init__(self, host: str = DEFAULT_HOST, port: int = DEFAULT_PORT):
        self.base_url = f"http://{host}:{port}"

    def _request(
        self, method: str, path: str, data: Optional[dict] = None, timeout: float = 3
    ) -> dict:
        """发送 HTTP 请求"""
        url = f"{self.base_url}{path}"

        if data:
            body = json.dumps(data).encode("utf-8")
            headers = {"Content-Type": "application/json"}
        else:
            body = None
            headers = {}

        req = urllib.request.Request(url, data=body, headers=headers, method=method)

        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            error_body = e.read().decode("utf-8")
            try:
                return json.loads(error_body)
            except json.JSONDecodeError:
                return {"error": error_body}
        except urllib.error.URLError as e:
            raise ConnectionError(f"Cannot connect to server: {e.reason}")
        except TimeoutError as e:
            raise ConnectionError(f"Request timed out: {e}")

    def health(self) -> dict:
        """检查服务器健康状态"""
        return self._request("GET", "/health")

    def list_processes(self) -> list[dict]:
        """列出所有进程"""
        result = self._request("GET", "/processes")
        return result.get("processes", [])

    def run(
        self,
        command: list[str] | str,
        cwd: Optional[str] = None,
        env: Optional[dict] = None,
        stdin_data: Optional[str] = None,
        shell: bool = False,
        strict: bool = False,
        detached: bool = False,
        timeout: float = 0,
    ) -> str:
        """启动进程，返回进程 ID

        Args:
            command: 命令和参数列表，或 shell=True 时的命令字符串
            cwd: 工作目录
            env: 环境变量
            stdin_data: 要写入进程 stdin 的数据
            shell: True 时在 Windows shell 中执行 command 字符串
        """
        data = {"command": command}
        if strict:
            data.update(strict=True, detach=detached, timeout=timeout)
        elif detached:
            data["detach"] = True
        if shell:
            data["shell"] = True
        if cwd:
            data["cwd"] = cwd
        if env:
            data["env"] = env
        if stdin_data:
            data["stdin"] = stdin_data

        result = self._request("POST", "/run", data)

        if "error" in result:
            raise RuntimeError(result["error"])

        return result["id"]

    def kill(self, process_id: str) -> bool:
        """终止进程"""
        # 使用更长的超时，因为服务端 taskkill /T 可能需要时间
        result = self._request("POST", "/kill", {"id": process_id}, timeout=10)
        return result.get("success", False)

    def purge(self) -> dict:
        """清理已完成的进程"""
        return self._request("GET", "/purge")

    def kill_async(self, process_id: str) -> None:
        """异步终止进程（发送请求后不等待响应）

        用于信号处理器中，避免阻塞。
        """
        import socket

        body = json.dumps({"id": process_id}).encode("utf-8")

        try:
            # 使用低级 socket 发送请求，设置短超时
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(1)
            sock.connect((DEFAULT_HOST, DEFAULT_PORT))

            request = (
                f"POST /kill HTTP/1.1\r\n"
                f"Host: {DEFAULT_HOST}:{DEFAULT_PORT}\r\n"
                f"Content-Type: application/json\r\n"
                f"Content-Length: {len(body)}\r\n"
                f"Connection: close\r\n"
                f"\r\n"
            ).encode("utf-8") + body

            sock.sendall(request)
            sock.close()
        except Exception:
            # 忽略错误，尽力而为
            pass

    def stream_output(self, process_id: str):
        """流式读取进程输出 (生成器)"""
        url = f"{self.base_url}/stream?id={process_id}"
        req = urllib.request.Request(url)

        try:
            with urllib.request.urlopen(req) as resp:
                event_type = None
                data_lines = []

                for raw_line in resp:
                    line = raw_line.decode("utf-8").rstrip("\n\r")

                    if line.startswith(":"):
                        # 心跳或注释，忽略
                        continue

                    if line.startswith("event:"):
                        event_type = line[6:].strip()
                        data_lines = []

                    elif line.startswith("data:"):
                        payload = line[5:]
                        data_lines.append(payload[1:] if payload.startswith(" ") else payload)

                    elif line == "":
                        # 空行表示事件结束
                        if event_type and data_lines:
                            content = "\n".join(data_lines)
                            yield (event_type, content)

                            if event_type == "exit":
                                return

                        event_type = None
                        data_lines = []

        except urllib.error.URLError as e:
            raise ConnectionError(f"Stream connection failed: {e.reason}")


# ============================================================================
# CLI Commands
# ============================================================================


def cmd_health(client: WinGUIClient, args: argparse.Namespace) -> int:
    """健康检查"""
    try:
        result = client.health()
        print(color("✓ Server is running", Colors.GREEN))
        print(f"  Version: {result.get('version', 'unknown')}")
        return 0
    except ConnectionError as e:
        print(color(f"✗ {e}", Colors.RED))
        return 1


def cmd_list(client: WinGUIClient, args: argparse.Namespace) -> int:
    """列出进程"""
    try:
        processes = client.list_processes()

        if not processes:
            print(color("No running processes", Colors.GRAY))
            return 0

        print(f"{'ID':<10} {'Running':<8} {'Command'}")
        print("-" * 60)

        for p in processes:
            status = (
                color("●", Colors.GREEN) if p["running"] else color("○", Colors.GRAY)
            )
            command = p["command"]
            cmd = command if isinstance(command, str) else " ".join(command)
            if len(cmd) > 40:
                cmd = cmd[:37] + "..."
            print(f"{p['id']:<10} {status:<8} {cmd}")

        return 0

    except ConnectionError as e:
        print(color(f"✗ {e}", Colors.RED))
        return 1


def cmd_kill(client: WinGUIClient, args: argparse.Namespace) -> int:
    """终止进程"""
    try:
        success = client.kill(args.kill)

        if success:
            print(color(f"✓ Process {args.kill} terminated", Colors.GREEN))
            return 0
        else:
            print(color(f"✗ Failed to terminate process {args.kill}", Colors.RED))
            return 1

    except ConnectionError as e:
        print(color(f"✗ {e}", Colors.RED))
        return 1


def cmd_start_process(client: WinGUIClient, args: argparse.Namespace) -> int:
    """使用 PowerShell Start-Process 启动 GUI 程序"""
    command = args.command

    # 移除 REMAINDER 可能包含的 '--' 分隔符
    if command and command[0] == "--":
        command = command[1:]

    if not command:
        print(color("✗ No command specified", Colors.RED))
        return 1

    # 构建 PowerShell 命令
    exe_path = command[0]
    arguments = command[1:] if len(command) > 1 else []

    # 转义引号
    exe_path_escaped = exe_path.replace("'", "''")

    if arguments:
        # 将参数合并为一个字符串
        args_str = " ".join(arguments).replace("'", "''")
        ps_cmd = f"Start-Process -FilePath '{exe_path_escaped}' -ArgumentList '{args_str}' -WindowStyle Normal"
    else:
        ps_cmd = f"Start-Process -FilePath '{exe_path_escaped}' -WindowStyle Normal"

    # 通过 runwingui 执行 PowerShell 命令
    try:
        process_id = client.run(["powershell.exe", "-Command", ps_cmd], cwd=args.cwd)
        # Start-Process 会立即返回，等待 powershell 完成
        exit_code = 0
        for event_type, content in client.stream_output(process_id):
            if event_type == "exit":
                exit_code = int(content)
            elif event_type == "stderr" and content.strip():
                print(color(content, Colors.RED), file=sys.stderr)

        if exit_code == 0:
            print(color("✓ Process started", Colors.GREEN))
        return exit_code

    except ConnectionError as e:
        print(color(f"✗ {e}", Colors.RED), file=sys.stderr)
        return 1
    except RuntimeError as e:
        print(color(f"✗ {e}", Colors.RED), file=sys.stderr)
        return 1


def cmd_run(client: WinGUIClient, args: argparse.Namespace) -> int:
    """运行命令"""
    global _current_process_id, _client, _cancel_requested

    # 如果指定了 --start-process，使用 PowerShell Start-Process
    if getattr(args, "start_process", False):
        return cmd_start_process(client, args)

    command = args.command

    # 移除 REMAINDER 可能包含的 '--' 分隔符
    if command and command[0] == "--":
        command = command[1:]

    if not command:
        print(color("✗ No command specified", Colors.RED))
        return 1

    # 设置全局引用供信号处理器使用
    _client = client

    # 解析环境变量
    env = None
    if getattr(args, "env", None):
        env = {}
        for item in args.env:
            if "=" in item:
                key, value = item.split("=", 1)
                env[key] = value

    # 检测 stdin 是否有数据（管道输入）
    stdin_data = None
    if not sys.stdin.isatty():
        # 使用 select 检查是否有数据可读，避免阻塞
        import select

        if select.select([sys.stdin], [], [], 0.1)[0]:
            stdin_data = sys.stdin.read()

    try:
        # Refuse a stale server rather than silently lose strict argv/deadlines.
        if args.strict and not client.health().get("strict_execution"):
            raise RuntimeError("Windows bridge server requires restart/update for strict execution")
        if _cancel_requested:
            return 130
        # 启动进程
        if getattr(args, "shell", False):
            command_payload: list[str] | str = " ".join(command)
        else:
            command_payload = command
        process_id = client.run(
            command_payload,
            cwd=args.cwd,
            env=env,
            stdin_data=stdin_data,
            shell=getattr(args, "shell", False),
            strict=args.strict,
            detached=args.detach,
            timeout=args.timeout,
        )
        _current_process_id = process_id  # 注册到全局
        if _cancel_requested:
            client.kill(process_id)
            _current_process_id = None
            return 130

        # Detach 模式：启动后立即返回，不等待输出
        if getattr(args, "detach", False):
            _current_process_id = None
            print(f"{process_id}")  # 仅输出远端进程 ID，启动确认后不再拥有其生命周期
            return 0

        # 流式读取输出，直接打印到终端
        exit_code = None
        timed_out = False

        for event_type, content in client.stream_output(process_id):
            if event_type == "stdout":
                # 直接输出，确保有换行
                sys.stdout.write(content)
                if not content.endswith("\n"):
                    sys.stdout.write("\n")
                sys.stdout.flush()
            elif event_type == "stderr":
                sys.stderr.write(content)
                if not content.endswith("\n"):
                    sys.stderr.write("\n")
                sys.stderr.flush()
            elif event_type == "error":
                sys.stderr.write(color(content, Colors.RED))
                sys.stderr.flush()
            elif event_type == "timeout":
                timed_out = True
                sys.stderr.write("__MCPX_COMMAND_TIMEOUT__\n")
                sys.stderr.flush()
            elif event_type == "exit":
                exit_code = int(content)

        _current_process_id = None  # 清除全局引用
        if exit_code is None:
            client.kill(process_id)
            raise RuntimeError("Windows output stream ended without an exit result")
        return 124 if timed_out else exit_code

    except ConnectionError as e:
        print(color(f"✗ {e}", Colors.RED), file=sys.stderr)
        print(
            color("  Is the server running? Start it with:", Colors.GRAY),
            file=sys.stderr,
        )
        print(
            color("  runwingui --start-server", Colors.GRAY),
            file=sys.stderr,
        )
        return 1
    except RuntimeError as e:
        print(color(f"✗ {e}", Colors.RED), file=sys.stderr)
        return 1


# ============================================================================
# Main
# ============================================================================


def main():
    # 注册信号处理器
    signal.signal(signal.SIGINT, sigint_handler)
    signal.signal(signal.SIGTERM, sigint_handler)

    parser = argparse.ArgumentParser(
        description="WinGUI Bridge Client - Run Windows GUI programs from WSL2",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s notepad.exe                    # 启动记事本
  %(prog)s cmd /c dir                     # 执行 Windows 命令
  %(prog)s --cwd "C:\\Projects" cmd /c dir # 指定工作目录
  %(prog)s --list                         # 列出运行中的进程
  %(prog)s --kill abc123                  # 终止指定进程
  %(prog)s --health                       # 检查服务器状态
""",
    )

    parser.add_argument(
        "command", nargs=argparse.REMAINDER, help="Command and arguments to run"
    )

    parser.add_argument(
        "--host", default=DEFAULT_HOST, help=f"Server host (default: {DEFAULT_HOST})"
    )

    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help=f"Server port (default: {DEFAULT_PORT})",
    )

    parser.add_argument(
        "--cwd", help="Working directory for the command (Windows path)"
    )

    parser.add_argument("--health", action="store_true", help="Check server health")

    parser.add_argument(
        "--list", action="store_true", dest="list_procs", help="List running processes"
    )

    parser.add_argument("--kill", metavar="ID", help="Kill a process by ID")

    parser.add_argument(
        "--purge",
        action="store_true",
        help="Purge completed processes from server memory",
    )

    parser.add_argument(
        "--detach",
        action="store_true",
        help="Start process in background and return immediately (prints process ID)",
    )

    parser.add_argument("--strict", action="store_true", help="Native argv without legacy shell fallback; requires an updated server")
    parser.add_argument("--timeout", type=float, default=0, help="Windows execution deadline seconds; nonpositive disables it")

    parser.add_argument(
        "--shell",
        action="store_true",
        help="Run the command string through the Windows shell. Use for shell syntax and quoted executable paths.",
    )

    parser.add_argument(
        "--start-process",
        action="store_true",
        dest="start_process",
        help="Use PowerShell Start-Process to launch (better for GUI apps, no output capture)",
    )

    parser.add_argument(
        "--env",
        action="append",
        metavar="KEY=VALUE",
        help="Set environment variable (can be used multiple times)",
    )

    args = parser.parse_args()

    # 创建客户端
    client = WinGUIClient(args.host, args.port)

    # 执行命令
    if args.health:
        return cmd_health(client, args)
    elif args.list_procs:
        return cmd_list(client, args)
    elif args.kill:
        return cmd_kill(client, args)
    elif args.purge:
        try:
            result = client.purge()
            remaining = result.get("remaining", "?")
            print(color(f"✓ Purged completed processes ({remaining} remaining)", Colors.GREEN))
            return 0
        except ConnectionError as e:
            print(color(f"✗ {e}", Colors.RED))
            return 1
    elif args.command:
        return cmd_run(client, args)
    else:
        parser.print_help()
        return 0


if __name__ == "__main__":
    sys.exit(main())
