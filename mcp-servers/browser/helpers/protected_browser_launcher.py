#!/usr/bin/env python3
"""Protected browser launcher for browser.

Starts a real Chromium via undetected-chromedriver and exposes a CDP endpoint
for the Node MCP server to attach existing Playwright tools.

Stdout is reserved for newline-delimited JSON events. Logs go to stderr.
"""

import argparse
import glob
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from typing import Optional


PROFILE_SINGLETON_NAMES = ("SingletonLock", "SingletonCookie", "SingletonSocket")


def emit(event: str, **kwargs):
    print(json.dumps({"event": event, **kwargs}, ensure_ascii=False), flush=True)


def log(message: str):
    print(message, file=sys.stderr, flush=True)


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        sock.listen(1)
        return int(sock.getsockname()[1])


def find_chrome(explicit: Optional[str]) -> str:
    if explicit:
        if os.path.exists(explicit):
            return explicit
        raise RuntimeError(f"Chrome executable not found: {explicit}")

    paths = glob.glob(os.path.expanduser("~/.cache/ms-playwright/chromium-*/chrome-linux*/chrome"))
    if paths:
        return sorted(paths)[-1]

    for cmd in ["google-chrome", "chromium-browser", "chromium"]:
        found = shutil.which(cmd)
        if found:
            return found

    raise RuntimeError("Chrome/Chromium executable not found")


def find_chromedriver(explicit: Optional[str]) -> str:
    if explicit:
        if os.path.exists(explicit):
            return explicit
        raise RuntimeError(f"patched chromedriver not found: {explicit}")

    default = os.path.expanduser("~/.local/share/undetected_chromedriver/undetected_chromedriver")
    if os.path.exists(default):
        return default

    raise RuntimeError(
        "patched chromedriver not found at ~/.local/share/undetected_chromedriver/undetected_chromedriver"
    )


def _profile_lock_pid(profile_dir: str) -> Optional[int]:
    lock_path = os.path.join(profile_dir, "SingletonLock")
    try:
        target = os.readlink(lock_path)
    except (FileNotFoundError, OSError):
        return None
    try:
        return int(target.rsplit("-", 1)[1])
    except (IndexError, ValueError):
        return None


def _pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def clear_stale_profile_locks(profile_dir: str) -> bool:
    """Remove Chromium singleton links only when their recorded owner is dead."""
    pid = _profile_lock_pid(profile_dir)
    if pid is None:
        return False
    if _pid_is_alive(pid):
        raise RuntimeError(
            f"Chrome profile is already in use by live process {pid}: {profile_dir}"
        )
    for name in PROFILE_SINGLETON_NAMES:
        path = os.path.join(profile_dir, name)
        try:
            if os.path.lexists(path):
                os.unlink(path)
        except FileNotFoundError:
            pass
    return True


def start_xvfb_if_needed(headless: bool):
    if headless or os.environ.get("DISPLAY"):
        return None, None

    xvfb = shutil.which("Xvfb")
    if not xvfb:
        raise RuntimeError("DISPLAY is not set and Xvfb is not installed")

    display_num = 99
    while os.path.exists(f"/tmp/.X{display_num}-lock"):
        display_num += 1
    display = f":{display_num}"
    proc = subprocess.Popen(
        [xvfb, display, "-screen", "0", "1920x1080x24"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    time.sleep(1)
    os.environ["DISPLAY"] = display
    return proc, display


def normalize_proxy(proxy: Optional[str]) -> Optional[str]:
    if not proxy:
        return None
    if "://" in proxy:
        scheme, rest = proxy.split("://", 1)
        scheme = scheme.lower()
        if scheme == "socks":
            scheme = "socks5"
        if scheme in ["socks4", "socks5"]:
            return f"{scheme}://{rest}"
        return f"http://{rest}"
    return f"http://{proxy}"


def wait_for_cloudflare(driver, timeout: int) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        try:
            title = (driver.title or "").lower()
            source = (driver.page_source or "").lower()
            if "just a moment" in title or "checking" in title:
                time.sleep(3)
                continue
            if "checking your browser" in source or "please wait" in source:
                time.sleep(3)
                continue
            return True
        except Exception:
            pass
        time.sleep(2)
    return False


def simulate_human(driver):
    try:
        import random

        for _ in range(random.randint(2, 4)):
            scroll = random.randint(150, 400)
            driver.execute_script(f"window.scrollBy(0, {scroll})")
            time.sleep(random.uniform(0.3, 0.7))
        driver.execute_script("window.scrollTo(0, 0)")
        time.sleep(random.uniform(0.5, 1.0))
    except Exception as exc:
        log(f"human simulation skipped: {exc}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Launch protected browser backend")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--proxy")
    parser.add_argument("--profile-dir")
    parser.add_argument("--chrome-binary")
    parser.add_argument("--chromedriver-path")
    parser.add_argument("--chrome-version-main", type=int)
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--warmup-url")
    parser.add_argument("--warmup-timeout", type=int, default=90)
    parser.add_argument("--timeout", type=int, default=30000)
    args = parser.parse_args()

    driver = None
    xvfb_proc = None
    profile_dir = args.profile_dir
    temp_profile = False
    cleaning_up = False

    def cleanup(*_):
        nonlocal driver, xvfb_proc, profile_dir, temp_profile, cleaning_up
        if cleaning_up:
            return
        cleaning_up = True
        try:
            if driver is not None:
                driver.quit()
        except Exception as exc:
            log(f"driver quit failed: {exc}")
        try:
            if xvfb_proc is not None and xvfb_proc.poll() is None:
                xvfb_proc.terminate()
                try:
                    xvfb_proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    xvfb_proc.kill()
        except Exception as exc:
            log(f"xvfb cleanup failed: {exc}")
        if temp_profile and profile_dir:
            shutil.rmtree(profile_dir, ignore_errors=True)

    def handle_signal(signum, _frame):
        cleanup()
        raise SystemExit(128 + signum)

    def handle_startup_timeout(_signum, _frame):
        raise TimeoutError(
            f"protected browser startup exceeded {args.timeout}ms before readiness"
        )

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    if hasattr(signal, "SIGALRM"):
        signal.signal(signal.SIGALRM, handle_startup_timeout)
        signal.alarm(max(1, (args.timeout // 1000) - 2))

    try:
        import undetected_chromedriver as uc
    except Exception as exc:
        emit("error", errorType="dependency_missing", message=f"undetected_chromedriver import failed: {exc}")
        return 2

    try:
        chrome_binary = find_chrome(args.chrome_binary)
        chromedriver_path = find_chromedriver(args.chromedriver_path)
        if not profile_dir:
            profile_dir = tempfile.mkdtemp(prefix="browser_protected_profile_")
            temp_profile = True
        else:
            os.makedirs(profile_dir, exist_ok=True)
            if clear_stale_profile_locks(profile_dir):
                log(f"removed stale Chromium singleton locks from {profile_dir}")

        xvfb_proc, display = start_xvfb_if_needed(args.headless)
        port = args.port or find_free_port()
        endpoint = f"http://{args.host}:{port}"

        options = uc.ChromeOptions()
        options.binary_location = chrome_binary
        options.add_argument("--no-sandbox")
        options.add_argument("--disable-dev-shm-usage")
        options.add_argument("--window-size=1920,1080")
        options.add_argument(f"--user-data-dir={profile_dir}")
        options.add_argument(f"--remote-debugging-port={port}")
        if args.headless:
            options.add_argument("--headless=new")

        proxy = normalize_proxy(args.proxy)
        if proxy:
            options.add_argument(f"--proxy-server={proxy}")
            options.add_argument("--proxy-bypass-list=localhost;127.0.0.1;[::1]")

        options.set_capability("goog:loggingPrefs", {"performance": "ALL"})

        proxy_env = {}
        for var in [
            "http_proxy",
            "https_proxy",
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "all_proxy",
            "ALL_PROXY",
            "no_proxy",
            "NO_PROXY",
        ]:
            if var in os.environ:
                proxy_env[var] = os.environ[var]
                del os.environ[var]

        try:
            kwargs = {
                "options": options,
                "driver_executable_path": chromedriver_path,
                "browser_executable_path": chrome_binary,
                "port": port,
            }
            if args.chrome_version_main:
                driver = uc.Chrome(version_main=args.chrome_version_main, **kwargs)
            else:
                driver = uc.Chrome(**kwargs)
        finally:
            os.environ.update(proxy_env)

        debugger_address = (driver.capabilities or {}).get("goog:chromeOptions", {}).get("debuggerAddress")
        if debugger_address:
            endpoint = f"http://{debugger_address}"

        driver.command_executor.set_timeout(max(args.timeout // 1000, 30))
        driver.set_page_load_timeout(max(args.timeout // 1000, 30))
        driver.execute_cdp_cmd("Network.enable", {})

        warmup = None
        if args.warmup_url:
            driver.get(args.warmup_url)
            time.sleep(3)
            warmup_timeout = min(
                args.warmup_timeout,
                max(1, args.timeout // 1000),
            )
            cf_ok = wait_for_cloudflare(driver, warmup_timeout)
            if cf_ok:
                simulate_human(driver)
            warmup = {"url": args.warmup_url, "cloudflarePassed": bool(cf_ok)}

        if hasattr(signal, "SIGALRM"):
            signal.alarm(0)
        emit(
            "ready",
            endpoint=endpoint,
            pid=os.getpid(),
            display=os.environ.get("DISPLAY"),
            profileDir=profile_dir,
            tempProfile=temp_profile,
            warmup=warmup,
        )

        while True:
            line = sys.stdin.readline()
            if line == "":
                break
            if line.strip() == "stop":
                break
            time.sleep(0.1)
        return 0
    except Exception as exc:
        emit("error", errorType="launch_failed", message=str(exc))
        return 1
    finally:
        if hasattr(signal, "SIGALRM"):
            signal.alarm(0)
        cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
