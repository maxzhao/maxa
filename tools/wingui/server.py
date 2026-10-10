#!/usr/bin/env python3
"""
WinGUI Bridge Server
====================
Windows service for the Maxa-owned tools/wingui bridge.
A generated Windows-local launcher starts pythonw.exe through Explorer; the
interpreter reads this authoritative script directly from its WSL UNC path.
HTTP/SSE carries process requests, output and lifecycle results.

Start from WSL with runwingui --start-server. For manual diagnostics, Windows
Python may execute the absolute script path; no Windows source copy is needed.
"""

import subprocess
import threading
import queue
import uuid
import json
import signal
import sys
import os
import shutil
import locale
import math
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs
from typing import Optional
from dataclasses import dataclass, field
from datetime import datetime

# ============================================================================
# Configuration
# ============================================================================

HOST = "127.0.0.1"
PORT = 19527  # 自定义端口，避免冲突
BUFFER_SIZE = 1024
MAX_COMPLETED_PROCESSES = 50  # 保留的已完成进程最大数量
COMPLETED_PROCESS_TTL = 60  # 已完成进程保留秒数 (用于 stream 消费)


def _candidate_output_encodings() -> list[str]:
    """Return encodings for decoding Windows subprocess output.

    Windows console programs often emit text using the active OEM code page
    (for example CP936 on Simplified Chinese systems), while PowerShell and
    modern tools may emit UTF-8.  Keep UTF-8 first for cross-project behavior,
    then fall back to the host preferred/OEM/ANSI code pages.  The environment
    variable is an escape hatch for uncommon local setups without changing the
    shared default.
    """

    candidates = [
        os.environ.get("WINGUI_OUTPUT_ENCODING"),
        "utf-8",
        locale.getpreferredencoding(False),
    ]

    if sys.platform == "win32":
        try:
            oemcp = ctypes.windll.kernel32.GetOEMCP()  # type: ignore[name-defined]
            candidates.append(f"cp{oemcp}")
        except Exception:
            pass
        try:
            acp = ctypes.windll.kernel32.GetACP()  # type: ignore[name-defined]
            candidates.append(f"cp{acp}")
        except Exception:
            pass

    # Common fallback for zh-CN Windows when the Python preferred encoding is
    # UTF-8 but cmd.exe still emits bytes in the OEM code page.
    candidates.append("cp936")

    deduped: list[str] = []
    for enc in candidates:
        if not enc:
            continue
        normalized = enc.lower()
        if normalized not in {item.lower() for item in deduped}:
            deduped.append(enc)
    return deduped


if sys.platform == "win32":
    import ctypes


OUTPUT_ENCODINGS = _candidate_output_encodings()

# ============================================================================
# Process Manager
# ============================================================================


WINDOWS_SHELL_COMMANDS = {
    "cmd",
    "cmd.exe",
    "powershell",
    "powershell.exe",
    "pwsh",
    "pwsh.exe",
}


@dataclass
class ProcessInfo:
    """进程信息"""

    proc: subprocess.Popen
    command: list[str] | str
    cwd: Optional[str]
    start_time: datetime
    output_queue: Optional[queue.Queue] = field(default_factory=queue.Queue)
    is_running: bool = True
    detached: bool = False
    timed_out: bool = False
    readers: list[threading.Thread] = field(default_factory=list)
    deadline_timer: Optional[threading.Timer] = None


class ProcessManager:
    """管理所有启动的子进程"""

    def __init__(self):
        self.processes: dict[str, ProcessInfo] = {}
        self._lock = threading.Lock()
        self._start_cleanup_timer()

    def _start_cleanup_timer(self):
        """启动定期清理线程"""
        timer = threading.Timer(30.0, self._periodic_cleanup)
        timer.daemon = True
        timer.start()

    def _periodic_cleanup(self):
        """定期清理已完成的进程"""
        try:
            self._purge_completed()
        finally:
            self._start_cleanup_timer()

    def _purge_completed(self, force: bool = False):
        """清理已完成的进程

        Args:
            force: True = 立即清理所有已完成进程 (手动 purge)
                   False = 仅清理超过 TTL 或超出上限的 (自动清理)
        """
        now = datetime.now()
        to_remove = []

        with self._lock:
            for pid, info in self.processes.items():
                if not info.is_running:
                    if force:
                        to_remove.append(pid)
                    else:
                        # 检查进程完成后是否已超过 TTL
                        elapsed = (now - info.start_time).total_seconds()
                        if elapsed > COMPLETED_PROCESS_TTL:
                            to_remove.append(pid)

            # 如果超过上限，按时间排序移除最旧的
            if not force:
                completed = [
                    (pid, info)
                    for pid, info in self.processes.items()
                    if not info.is_running
                ]
                if len(completed) > MAX_COMPLETED_PROCESSES:
                    completed.sort(key=lambda x: x[1].start_time)
                    excess = len(completed) - MAX_COMPLETED_PROCESSES
                    for pid, _ in completed[:excess]:
                        if pid not in to_remove:
                            to_remove.append(pid)

            for pid in to_remove:
                del self.processes[pid]

        if to_remove:
            print(
                f"[{now.strftime('%H:%M:%S')}] Purged {len(to_remove)} completed process(es)"
            )

    def _legacy_powershell_command(self, command: list[str]) -> list[str]:
        """Build the historical PowerShell wrapper command.

        This is only used as a compatibility fallback when the first argv item is
        not directly executable on Windows. Explicit shells such as cmd.exe and
        powershell.exe must keep their argv boundary and are never wrapped again.
        """
        cmd_str = " ".join(command)
        return ["powershell.exe", "-NoProfile", "-Command", cmd_str]

    def _should_try_legacy_powershell_fallback(
        self, command: list[str], process_env: dict
    ) -> bool:
        """Return True when legacy PowerShell wrapping may preserve old usage.

        Historically runwingui wrapped every command in PowerShell, so commands
        like `runwingui dir` worked even though `dir` is not an executable. Keep
        that convenience only when argv[0] cannot be resolved as an executable.
        """
        if not command:
            return False

        exe = command[0]
        exe_name = os.path.basename(exe).lower()
        if exe_name in WINDOWS_SHELL_COMMANDS:
            return False

        # Paths with a directory component are explicit executable paths. If they
        # do not exist, surfacing FileNotFound is clearer than reinterpreting the
        # whole command as PowerShell code.
        if os.path.dirname(exe):
            return False

        return shutil.which(exe, path=process_env.get("PATH")) is None

    def start_process(
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
        """启动新进程，返回进程 ID

        Args:
            command: 命令和参数列表，或 shell=True 时的命令字符串
            cwd: 工作目录
            env: 环境变量
            stdin_data: 要写入进程 stdin 的数据，写入后关闭 stdin
            shell: True 时通过 Windows shell 执行 command 字符串
        """
        process_id = str(uuid.uuid4())[:8]

        # 合并环境变量
        process_env = os.environ.copy()
        if env:
            process_env.update(env)

        final_command = command
        if not isinstance(timeout, (int, float)) or isinstance(timeout, bool) or not math.isfinite(timeout):
            raise RuntimeError("timeout must be a finite number")
        if cwd is not None and (not isinstance(cwd, str) or not os.path.isdir(cwd)):
            raise RuntimeError(f"Working directory is not accessible: {cwd}")
        if shell:
            if not isinstance(command, str) or not command.strip():
                raise RuntimeError("Shell mode requires a nonblank command string")
            if strict and cwd and cwd.startswith("\\\\"):
                raise RuntimeError("Windows cmd shell cannot use UNC cwd; use native argv or a drive path")
        elif not isinstance(command, list) or not command or not all(isinstance(arg, str) for arg in command) or not command[0].strip():
            raise RuntimeError("Direct mode requires a nonempty string array")
        elif strict:
            # Resolve only an executable. Never reinterpret missing argv as code.
            executable = command[0]
            candidate = os.path.join(cwd, executable) if cwd and os.path.dirname(executable) and not os.path.isabs(executable) else executable
            search_path = os.pathsep.join(filter(None, (cwd, process_env.get("PATH"))))
            resolved = shutil.which(candidate, path=search_path)
            if resolved is None:
                raise RuntimeError(f"Command not found: {executable}")
            if os.path.splitext(resolved)[1].lower() in {".cmd", ".bat"}:
                raise RuntimeError("Batch scripts require explicit cmd.exe or shell-string execution")
            final_command = [resolved, *command[1:]]
        elif sys.platform == "win32" and self._should_try_legacy_powershell_fallback(command, process_env):
            final_command = self._legacy_powershell_command(command)

        try:
            proc = subprocess.Popen(
                final_command,
                stdin=subprocess.PIPE if stdin_data and not detached else subprocess.DEVNULL,
                stdout=subprocess.DEVNULL if detached else subprocess.PIPE,
                stderr=subprocess.DEVNULL if detached else subprocess.PIPE,
                cwd=cwd,
                env=process_env,
                bufsize=0,
                text=False,
                creationflags=subprocess.CREATE_NEW_PROCESS_GROUP
                if sys.platform == "win32"
                else 0,
                shell=shell,
                executable=(process_env.get("COMSPEC") or os.path.join(os.environ.get("SystemRoot", "C:\\Windows"), "System32", "cmd.exe")) if shell and strict else None,
            )
        except FileNotFoundError as e:
            missing = command if isinstance(command, str) else command[0]
            raise RuntimeError(f"Command not found: {missing}") from e
        except Exception as e:
            raise RuntimeError(f"Failed to start process: {e}") from e

        info = ProcessInfo(
            proc=proc,
            command=command,
            cwd=cwd,
            start_time=datetime.now(),
            output_queue=None if detached else queue.Queue(),
            detached=detached,
        )

        with self._lock:
            self.processes[process_id] = info

        # A detached application's lifetime is independent of the launching client.
        # No pipes/readers/deadline are retained after launch acknowledgement.
        if detached:
            threading.Thread(target=self._monitor_process, args=(process_id,), daemon=True).start()
            return process_id

        # 在单独线程中写入 stdin 数据（避免大数据量时阻塞主流程）
        if stdin_data and proc.stdin:
            stdin_thread = threading.Thread(
                target=self._write_stdin,
                args=(process_id, stdin_data),
                daemon=True,
            )
            stdin_thread.start()

        # 启动 stdout 读取线程
        stdout_thread = threading.Thread(
            target=self._read_stream, args=(process_id, "stdout"), daemon=True
        )
        info.readers.append(stdout_thread)
        stdout_thread.start()

        # 启动 stderr 读取线程
        stderr_thread = threading.Thread(
            target=self._read_stream, args=(process_id, "stderr"), daemon=True
        )
        info.readers.append(stderr_thread)
        stderr_thread.start()
        if timeout > 0:
            def expire():
                with self._lock:
                    current = self.processes.get(process_id)
                    if current is None or not current.is_running:
                        return
                    current.timed_out = True
                self.kill_process(process_id)
            info.deadline_timer = threading.Timer(timeout, expire)
            info.deadline_timer.daemon = True
            info.deadline_timer.start()

        # 启动进程监控线程 (等待退出)
        monitor_thread = threading.Thread(
            target=self._monitor_process, args=(process_id,), daemon=True
        )
        monitor_thread.start()

        return process_id

    def _write_stdin(self, process_id: str, stdin_data: str):
        """在单独线程中写入 stdin 数据并关闭"""
        with self._lock:
            info = self.processes.get(process_id)

        if not info or not info.proc.stdin:
            return

        try:
            info.proc.stdin.write(stdin_data.encode("utf-8"))
            info.proc.stdin.close()
        except Exception as e:
            info.output_queue.put(("error", f"Failed to write stdin: {e}\n"))

    def _decode_output(self, data: bytes) -> str:
        """Decode subprocess output with UTF-8 first and Windows code page fallback."""
        for encoding in OUTPUT_ENCODINGS:
            try:
                return data.decode(encoding)
            except UnicodeDecodeError:
                continue
            except LookupError:
                continue
        return data.decode("utf-8", errors="replace")

    def _read_stream(self, process_id: str, stream_name: str):
        """读取指定流 (stdout 或 stderr) 并放入队列"""
        with self._lock:
            info = self.processes.get(process_id)

        if not info:
            return

        stream = info.proc.stdout if stream_name == "stdout" else info.proc.stderr

        try:
            for raw_line in iter(stream.readline, b""):
                if raw_line:
                    line = self._decode_output(raw_line)
                    # 统一换行符: Windows \r\n -> Unix \n
                    line = line.replace("\r\n", "\n").replace("\r", "\n")
                    info.output_queue.put((stream_name, line))
        except Exception as e:
            info.output_queue.put(("error", f"Read {stream_name} error: {e}\n"))

    def _monitor_process(self, process_id: str):
        """监控进程退出"""
        with self._lock:
            info = self.processes.get(process_id)

        if not info:
            return

        # 等待进程结束
        return_code = info.proc.wait()
        for reader in info.readers:
            reader.join()
        if info.deadline_timer:
            info.deadline_timer.cancel()
        if not info.detached:
            if info.timed_out:
                info.output_queue.put(("timeout", "execution deadline exceeded"))
            info.output_queue.put(("exit", str(return_code)))
        info.is_running = False

    def get_output(
        self, process_id: str, timeout: float = 0.5
    ) -> Optional[tuple[str, str]]:
        """获取进程输出，返回 (type, content) 或 None"""
        with self._lock:
            info = self.processes.get(process_id)

        if not info or info.output_queue is None:
            return None

        try:
            return info.output_queue.get(timeout=timeout)
        except queue.Empty:
            return None

    def kill_process(self, process_id: str) -> bool:
        """终止进程及其所有子进程"""
        with self._lock:
            info = self.processes.get(process_id)

        if not info:
            return False

        try:
            pid = info.proc.pid

            if sys.platform == "win32":
                # Windows: 使用 taskkill /T 终止整个进程树
                # /T = 终止所有子进程, /F = 强制终止
                try:
                    subprocess.run(
                        ["taskkill", "/T", "/F", "/PID", str(pid)],
                        capture_output=True,
                        timeout=5,
                    )
                except subprocess.TimeoutExpired:
                    pass
            else:
                info.proc.terminate()

            # 等待进程结束
            try:
                info.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                info.proc.kill()

            return True
        except Exception:
            return False

    def list_processes(self) -> list[dict]:
        """列出所有进程"""
        with self._lock:
            return [
                {
                    "id": pid,
                    "command": info.command,
                    "cwd": info.cwd,
                    "running": info.is_running,
                    "pid": info.proc.pid,
                    "detached": info.detached,
                    "start_time": info.start_time.isoformat(),
                }
                for pid, info in self.processes.items()
            ]

    def cleanup(self):
        """清理所有进程"""
        with self._lock:
            process_ids = list(self.processes.keys())
        for process_id in process_ids:
            self.kill_process(process_id)


# 全局进程管理器
process_manager = ProcessManager()

# ============================================================================
# Threaded HTTP Server
# ============================================================================


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """多线程 HTTP 服务器，每个请求在独立线程中处理"""

    daemon_threads = True  # 主线程退出时自动终止所有请求线程


# ============================================================================
# HTTP Request Handler
# ============================================================================


class WinGUIHandler(BaseHTTPRequestHandler):
    """HTTP 请求处理器"""

    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        """自定义日志格式"""
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {args[0]}")

    def send_json(self, data: dict, status: int = 200):
        """发送 JSON 响应"""
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", len(body))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, message: str, status: int = 400):
        """发送错误 JSON"""
        self.send_json({"error": message}, status)

    def do_GET(self):
        """处理 GET 请求"""
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == "/health":
            self.send_json({"status": "ok", "version": "1.1.0", "strict_execution": True})

        elif path == "/processes":
            self.send_json({"processes": process_manager.list_processes()})

        elif path == "/purge":
            # 手动清理已完成进程 (强制模式，忽略 TTL)
            process_manager._purge_completed(force=True)
            remaining = len(process_manager.processes)
            self.send_json({"status": "ok", "remaining": remaining})

        elif path == "/stream":
            # SSE 流式输出
            process_id = query.get("id", [None])[0]
            if not process_id:
                self.send_error_json("Missing process id", 400)
                return
            self._handle_stream(process_id)

        else:
            self.send_error_json("Not Found", 404)

    def do_POST(self):
        """处理 POST 请求"""
        parsed = urlparse(self.path)
        path = parsed.path

        # 读取请求体
        content_length = int(self.headers.get("Content-Length", 0))
        body = (
            self.rfile.read(content_length).decode("utf-8") if content_length else "{}"
        )

        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            self.send_error_json("Invalid JSON", 400)
            return

        if path == "/run":
            self._handle_run(data)

        elif path == "/kill":
            process_id = data.get("id")
            if not process_id:
                self.send_error_json("Missing process id", 400)
                return

            success = process_manager.kill_process(process_id)
            self.send_json({"success": success})

        else:
            self.send_error_json("Not Found", 404)

    def _handle_run(self, data: dict):
        """处理启动进程请求"""
        command = data.get("command")
        cwd = data.get("cwd")
        env = data.get("env")
        stdin_data = data.get("stdin")
        shell = bool(data.get("shell", False))
        strict = data.get("strict", False)
        detached = data.get("detach", False)
        timeout = data.get("timeout", 0)
        if not isinstance(strict, bool) or not isinstance(detached, bool):
            self.send_error_json("strict and detach must be boolean", 400)
            return

        if not command:
            self.send_error_json("Missing command", 400)
            return

        # command 可以是字符串或列表。shell=True 时字符串保持原样交给 Windows shell；
        # 非 shell 字符串维持旧兼容行为，继续 shlex 拆分成 argv。
        if isinstance(command, str) and not shell and not strict:
            import shlex

            try:
                command = shlex.split(command)
            except ValueError as e:
                self.send_error_json(f"Invalid command: {e}", 400)
                return

        if shell and not isinstance(command, str):
            self.send_error_json("Shell mode requires command to be a string", 400)
            return

        try:
            process_id = process_manager.start_process(command, cwd, env, stdin_data, shell=shell, strict=strict, detached=detached, timeout=timeout)
            self.send_json({"id": process_id, "command": command})
        except RuntimeError as e:
            self.send_error_json(str(e), 500)

    def _handle_stream(self, process_id: str):
        """处理 SSE 流式输出"""
        # 检查进程是否存在
        with process_manager._lock:
            info = process_manager.processes.get(process_id)
            if info is None:
                self.send_error_json(f"Process {process_id} not found", 404)
                return
            if info.detached:
                self.send_error_json("Detached processes do not capture output", 400)
                return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")  # 使用 close，让连接在结束后立即关闭
        self.send_header("X-Accel-Buffering", "no")  # 禁用 nginx 缓冲
        self.end_headers()

        client_disconnected = False
        heartbeat_failures = 0
        max_heartbeat_failures = 3  # 连续心跳失败次数上限

        try:
            while True:
                result = process_manager.get_output(process_id, timeout=0.5)

                if result is None:
                    # 检查进程是否还存在
                    with process_manager._lock:
                        info = process_manager.processes.get(process_id)
                        if info is None or not info.is_running:
                            # 进程已结束但没有收到 exit 事件，发送默认退出码
                            self.wfile.write(b"event: exit\ndata: -1\n\n")
                            self.wfile.flush()
                            break

                    # 发送心跳 (同时检测连接是否断开)
                    try:
                        self.wfile.write(b": heartbeat\n\n")
                        self.wfile.flush()
                        heartbeat_failures = 0  # 重置失败计数
                    except (
                        BrokenPipeError,
                        ConnectionResetError,
                        ConnectionAbortedError,
                        OSError,
                    ):
                        heartbeat_failures += 1
                        if heartbeat_failures >= max_heartbeat_failures:
                            client_disconnected = True
                            break
                    continue

                event_type, content = result

                # 发送 SSE 事件
                self.wfile.write(f"event: {event_type}\n".encode("utf-8"))
                # 处理多行内容
                for line in content.splitlines():
                    self.wfile.write(f"data: {line}\n".encode("utf-8"))
                self.wfile.write(b"\n")
                self.wfile.flush()

                # 进程退出
                if event_type == "exit":
                    break

        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
            # 客户端断开连接，标记需要终止进程
            client_disconnected = True

        finally:
            # 如果客户端断开，终止对应的 Windows 进程
            if client_disconnected:
                print(
                    f"[{datetime.now().strftime('%H:%M:%S')}] Client disconnected, killing process {process_id}"
                )
                process_manager.kill_process(process_id)

            # 流结束后延迟清理已完成进程 (避免重复 stream 请求时找不到进程)
            def delayed_remove():
                import time

                time.sleep(5)
                with process_manager._lock:
                    info = process_manager.processes.get(process_id)
                    if info and not info.is_running:
                        del process_manager.processes[process_id]

            threading.Thread(target=delayed_remove, daemon=True).start()


# ============================================================================
# Main
# ============================================================================


def main():
    """主函数"""
    print("=" * 60)
    print("WinGUI Bridge Server")
    print("=" * 60)
    print(f"Listening on http://{HOST}:{PORT}")
    print("Press Ctrl+C to stop")
    print("-" * 60)

    server = ThreadedHTTPServer((HOST, PORT), WinGUIHandler)

    def shutdown_handler(signum, frame):
        print("\nShutting down...")
        process_manager.cleanup()
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown_handler)
    signal.signal(signal.SIGTERM, shutdown_handler)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        shutdown_handler(None, None)


if __name__ == "__main__":
    main()
