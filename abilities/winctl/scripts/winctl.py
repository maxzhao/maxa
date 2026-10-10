#!/usr/bin/env python3
"""winctl.py - Unified CLI for Windows desktop control via TCP JSON-RPC.

Replaces 25 winctl MCP tools with a single Python CLI script.
Communicates with the Windows WinCtl Server on TCP port 9527.

Agent invocation after load(target="winctl"):
    call(tool="@winctl:/scripts/winctl.py", params={"args": ["--help"]})
    call(tool="@winctl:/scripts/winctl.py", params={"args": ["--list"]})

The cataloged executor owns Python/uv. Pass action and optional JSON params as
literal argv, with the JSON object encoded in one string. Example args:
    ["screenshot_desktop"]
    ["screenshot_desktop", '{"format":"jpeg","quality":70}']
    ["mouse_click", '{"x":800,"y":400}']
    ["list_windows"]
    ["list_windows", '{"filter":"Chrome"}']
    ["key_type", '{"text":"Hello World"}']
    ["key_hotkey", '{"keys":["ctrl","shift","esc"]}']
Use observed window handles/coordinates, not example values.

Environment:
    If the server is not already running, auto-start requires either
    WINCTL_SERVER_START_CMD or WINCTL_SERVER_CWD.
"""

import socket
import json
import sys
import os
import time
import base64
import tempfile
import subprocess
import shlex
from datetime import datetime

# ── Server Configuration ──────────────────────────────────────────────
SERVER_HOST = "127.0.0.1"
SERVER_PORT = 9527
CONNECT_TIMEOUT = 2       # seconds
REQUEST_TIMEOUT = 30      # seconds
MAX_START_ATTEMPTS = 20
START_POLL_INTERVAL = 0.5  # seconds
START_SERVER_CMD = os.environ.get("WINCTL_SERVER_START_CMD")
SERVER_CWD = os.environ.get("WINCTL_SERVER_CWD")


# ── Action Definitions ────────────────────────────────────────────────
# Parameter spec: type (number|string|array), required, default, enum
# "one_of": at least one of listed params must be provided
# "post": post-processing function name for screenshots

ACTIONS = {
    # ── Screenshots ───────────────────────────────────────────────
    "screenshot_desktop": {
        "params": {
            "monitor": {"type": "number", "default": 0},
            "format": {"type": "string", "default": "png", "enum": ["png", "jpeg", "jpg"]},
            "quality": {"type": "number", "default": 85},
        },
        "post": "screenshot_desktop",
    },
    "screenshot_window": {
        "params": {
            "hwnd": {"type": "number"},
            "title": {"type": "string"},
            "format": {"type": "string", "default": "png", "enum": ["png", "jpeg", "jpg"]},
            "quality": {"type": "number", "default": 85},
        },
        "one_of": ["hwnd", "title"],
        "post": "screenshot_window",
    },
    # ── Window Management ─────────────────────────────────────────
    "list_windows": {
        "params": {
            "filter": {"type": "string"},
        },
    },
    "get_window_info": {
        "params": {
            "hwnd": {"type": "number"},
            "title": {"type": "string"},
        },
        "one_of": ["hwnd", "title"],
    },
    "focus_window": {
        "params": {
            "hwnd": {"type": "number"},
            "title": {"type": "string"},
        },
        "one_of": ["hwnd", "title"],
    },
    "resize_window": {
        "params": {
            "hwnd": {"type": "number"},
            "title": {"type": "string"},
            "x": {"type": "number"},
            "y": {"type": "number"},
            "width": {"type": "number"},
            "height": {"type": "number"},
        },
        "one_of": ["hwnd", "title"],
    },
    "find_child_window": {
        "params": {
            "hwnd": {"type": "number"},
            "title": {"type": "string"},
            "class_filter": {"type": "string", "default": ""},
        },
        "one_of": ["hwnd", "title"],
    },
    # ── Mouse ─────────────────────────────────────────────────────
    "mouse_move": {
        "params": {
            "x": {"type": "number", "required": True},
            "y": {"type": "number", "required": True},
            "duration": {"type": "number", "default": 0},
        },
    },
    "mouse_click": {
        "params": {
            "x": {"type": "number"},
            "y": {"type": "number"},
            "button": {"type": "string", "default": "left", "enum": ["left", "middle", "right"]},
            "clicks": {"type": "number", "default": 1},
        },
    },
    "mouse_drag": {
        "params": {
            "from_x": {"type": "number", "required": True},
            "from_y": {"type": "number", "required": True},
            "to_x": {"type": "number", "required": True},
            "to_y": {"type": "number", "required": True},
            "duration": {"type": "number", "default": 0.5},
        },
    },
    "mouse_scroll": {
        "params": {
            "amount": {"type": "number", "required": True},
            "x": {"type": "number"},
            "y": {"type": "number"},
        },
    },
    "click_in_window": {
        "params": {
            "hwnd": {"type": "number"},
            "title": {"type": "string"},
            "x": {"type": "number", "required": True},
            "y": {"type": "number", "required": True},
            "button": {"type": "string", "default": "left", "enum": ["left", "middle", "right"]},
            "clicks": {"type": "number", "default": 1},
        },
        "one_of": ["hwnd", "title"],
    },
    "drag_in_window": {
        "params": {
            "hwnd": {"type": "number"},
            "title": {"type": "string"},
            "from_x": {"type": "number", "required": True},
            "from_y": {"type": "number", "required": True},
            "to_x": {"type": "number", "required": True},
            "to_y": {"type": "number", "required": True},
            "duration": {"type": "number", "default": 0.5},
        },
        "one_of": ["hwnd", "title"],
    },
    "window_drag": {
        "params": {
            "hwnd": {"type": "number"},
            "title": {"type": "string"},
            "from_x": {"type": "number", "required": True},
            "from_y": {"type": "number", "required": True},
            "to_x": {"type": "number", "required": True},
            "to_y": {"type": "number", "required": True},
            "steps": {"type": "number", "default": 20},
            "duration": {"type": "number", "default": 0.5},
        },
        "one_of": ["hwnd", "title"],
    },
    # ── Keyboard ──────────────────────────────────────────────────
    "key_type": {
        "params": {
            "text": {"type": "string", "required": True},
            "interval": {"type": "number", "default": 0},
        },
    },
    "key_press": {
        "params": {
            "key": {"type": "string", "required": True},
            "modifiers": {"type": "array"},
        },
    },
    "key_hotkey": {
        "params": {
            "keys": {"type": "array", "required": True},
        },
    },
    # ── Clipboard ─────────────────────────────────────────────────
    "get_clipboard": {
        "params": {},
    },
    "set_clipboard": {
        "params": {
            "text": {"type": "string", "required": True},
        },
    },
    # ── Cursor / DPI ──────────────────────────────────────────────
    "get_cursor_position": {
        "params": {},
    },
    "get_dpi_info": {
        "params": {
            "hwnd": {"type": "number"},
        },
    },
    # ── Virtual Desktops ──────────────────────────────────────────
    "list_desktops": {
        "params": {},
    },
    "switch_desktop": {
        "params": {
            "index": {"type": "number"},
            "name": {"type": "string"},
        },
        "one_of": ["index", "name"],
    },
    "move_window_to_desktop": {
        "params": {
            "hwnd": {"type": "number", "required": True},
            "desktop_index": {"type": "number", "required": True},
        },
    },
    # ── Win32 Messages ────────────────────────────────────────────
    "post_message": {
        "params": {
            "hwnd": {"type": "number"},
            "title": {"type": "string"},
            "msg": {"type": "number", "required": True},
            "wparam": {"type": "number", "default": 0},
            "lparam": {"type": "number", "default": 0},
        },
        "one_of": ["hwnd", "title"],
    },
}


# ── Validation ────────────────────────────────────────────────────────

def validate_params(action: str, params: dict) -> dict:
    """Validate and apply defaults to params based on action definition.

    Returns validated params dict (only defined params, unknown keys stripped).
    Raises ValueError on validation failure.
    """
    spec = ACTIONS[action]
    param_defs = spec.get("params", {})
    one_of = spec.get("one_of")
    validated = {}

    # Check one_of constraint (at least one must be provided and non-empty)
    if one_of:
        has_any = False
        for k in one_of:
            v = params.get(k)
            if v is not None and v != "":
                has_any = True
                break
        if not has_any:
            raise ValueError(
                f"Either {' or '.join(repr(k) for k in one_of)} must be provided"
            )

    # Validate each defined param
    for name, pdef in param_defs.items():
        value = params.get(name)
        ptype = pdef.get("type")
        required = pdef.get("required", False)
        default = pdef.get("default")
        enum = pdef.get("enum")

        # Apply default if value not provided
        if value is None and default is not None:
            value = default

        # Check required
        if required and value is None:
            raise ValueError(f"'{name}' is required")

        # Skip if not provided and not required
        if value is None:
            continue

        # Type check
        if ptype == "number":
            if not isinstance(value, (int, float)):
                raise ValueError(
                    f"'{name}' must be a number, got {type(value).__name__}"
                )
        elif ptype == "string":
            if not isinstance(value, str):
                raise ValueError(
                    f"'{name}' must be a string, got {type(value).__name__}"
                )
            if required and not value.strip():
                raise ValueError(f"'{name}' cannot be empty")
        elif ptype == "array":
            if not isinstance(value, list):
                raise ValueError(
                    f"'{name}' must be an array, got {type(value).__name__}"
                )
            if required and len(value) == 0:
                raise ValueError(f"'{name}' cannot be empty")

        # Enum check
        if enum and value not in enum:
            raise ValueError(f"'{name}' must be one of {enum}, got {value!r}")

        validated[name] = value

    # Extra validation: key_hotkey keys must be non-empty strings
    if action == "key_hotkey" and "keys" in validated:
        for i, k in enumerate(validated["keys"]):
            if not isinstance(k, str) or not k.strip():
                raise ValueError(f"keys[{i}] must be a non-empty string")

    # Extra validation: key_press modifiers must be strings
    if action == "key_press" and "modifiers" in validated:
        for i, m in enumerate(validated["modifiers"]):
            if not isinstance(m, str):
                raise ValueError(f"modifiers[{i}] must be a string")

    return validated


# ── Server Communication ──────────────────────────────────────────────

def is_server_running() -> bool:
    """Check if WinCtl Server is running via TCP health check."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect((SERVER_HOST, SERVER_PORT))
        sock.close()
        return True
    except (socket.error, OSError):
        return False


def build_start_command() -> str | None:
    """Build the configured server start command without hardcoding local paths."""
    if START_SERVER_CMD:
        return START_SERVER_CMD
    if SERVER_CWD:
        return f"runwingui --detach --cwd {shlex.quote(SERVER_CWD)} python server.py"
    return None


def start_server() -> bool:
    """Start WinCtl Server using configured command and wait until ready."""
    if is_server_running():
        return True

    start_cmd = build_start_command()
    if not start_cmd:
        print(
            "[WinCtl] Server not running and no auto-start configuration found. "
            "Set WINCTL_SERVER_START_CMD or WINCTL_SERVER_CWD, or start the server manually.",
            file=sys.stderr,
        )
        return False

    print("[WinCtl] Server not running, starting with configured command...", file=sys.stderr)
    completed = subprocess.run(start_cmd, shell=True, capture_output=True, text=True)
    if completed.returncode != 0:
        msg = (completed.stderr or completed.stdout or "start command failed").strip()
        print(f"[WinCtl] Start command failed: {msg}", file=sys.stderr)
        return False

    # Poll until server is ready
    for _ in range(MAX_START_ATTEMPTS):
        time.sleep(START_POLL_INTERVAL)
        if is_server_running():
            print("[WinCtl] Server started successfully.", file=sys.stderr)
            return True

    return False


def ensure_server():
    """Ensure server is running; auto-start if needed. Exit on failure."""
    if is_server_running():
        return
    if not start_server():
        error_exit("WinCtl Server failed to start within 10 seconds")


def send_request(method: str, params: dict) -> dict:
    """Send JSON-RPC request to WinCtl Server and return result."""
    request = {
        "id": int(time.time() * 1000),
        "method": method,
        "params": params,
    }
    request_json = json.dumps(request, ensure_ascii=False)

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(REQUEST_TIMEOUT)
        sock.connect((SERVER_HOST, SERVER_PORT))
        sock.sendall((request_json + "\n").encode("utf-8"))

        response = b""
        while b"\n" not in response:
            chunk = sock.recv(65536)
            if not chunk:
                break
            response += chunk

        sock.close()
    except socket.timeout:
        error_exit(f"Request timed out after {REQUEST_TIMEOUT}s")
    except (socket.error, OSError) as e:
        error_exit(f"Connection to WinCtl Server failed: {e}")

    try:
        result = json.loads(response.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        error_exit(f"Failed to parse server response: {e}")

    if "error" in result and result["error"]:
        msg = (
            result["error"].get("message", "Unknown error")
            if isinstance(result["error"], dict)
            else str(result["error"])
        )
        error_exit(f"Server error: {msg}")

    return result.get("result", {})


# ── Screenshot Post-processing ────────────────────────────────────────

def save_screenshot(result: dict, suffix: str) -> dict:
    """Decode base64 image from server result, save to temp file, return metadata."""
    if not result or not result.get("image"):
        error_exit("Server returned no image data")

    ext = result.get("format", "png")
    if ext == "jpg":
        ext = "jpeg"

    image_data = base64.b64decode(result["image"])
    temp_path = os.path.join(
        tempfile.gettempdir(),
        f"winctl_{suffix}_{int(time.time())}.{ext}",
    )

    with open(temp_path, "wb") as f:
        f.write(image_data)

    return {
        "saved_to": temp_path,
        "format": result.get("format", ext),
        "size": {
            "width": result.get("width"),
            "height": result.get("height"),
        },
        "fileSize": len(image_data),
    }


def post_screenshot_desktop(result: dict) -> dict:
    """Post-process desktop screenshot: base64 → file + metadata."""
    output = save_screenshot(result, "desktop")
    output["monitor"] = result.get("monitor")
    output["capture_method"] = result.get("capture_method")
    output["hint"] = {
        "description": "截图已保存到临时文件；可调用 analyze，并提供 path、analysis_prompt、max_steps 进行视觉分析。",
        "path": output["saved_to"],
    }
    return output


def post_screenshot_window(result: dict) -> dict:
    """Post-process window screenshot: base64 → file + metadata."""
    output = save_screenshot(result, "window")
    output["hwnd"] = result.get("hwnd")
    output["title"] = result.get("title")
    output["hint"] = {
        "description": "窗口截图已保存到临时文件；可调用 analyze，并提供 path、analysis_prompt、max_steps 进行视觉分析。",
        "path": output["saved_to"],
    }
    return output


# ── Output Helpers ────────────────────────────────────────────────────

def error_exit(message: str, code: int = 1):
    """Print error JSON to stderr and exit with non-zero code."""
    json.dump({"error": message}, sys.stderr, ensure_ascii=False)
    sys.stderr.write("\n")
    sys.exit(code)


def success_output(data):
    """Print success JSON to stdout."""
    output = {
        "success": True,
        "data": data,
        "timestamp": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    }
    json.dump(output, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


# ── Help ──────────────────────────────────────────────────────────────

def print_help():
    """Print usage information with all actions and their parameters."""
    print(__doc__.strip())
    print()
    print("Actions:")
    for action in sorted(ACTIONS):
        spec = ACTIONS[action]
        params = spec.get("params", {})
        one_of = spec.get("one_of")
        parts = []
        for name, pdef in params.items():
            req = pdef.get("required", False)
            default = pdef.get("default")
            ptype = pdef.get("type", "?")
            if req:
                parts.append(f"{name}:{ptype}*")
            elif default is not None:
                parts.append(f"{name}:{ptype}={default}")
            else:
                parts.append(f"{name}:{ptype}")
        param_str = ", ".join(parts) if parts else "(none)"
        constraint = f"  [one_of: {'/'.join(one_of)}]" if one_of else ""
        print(f"  {action:30s} {param_str}{constraint}")


def print_list():
    """Print action names only (one per line)."""
    for action in sorted(ACTIONS):
        print(action)


# ── Main ──────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        print_help()
        sys.exit(0)

    if sys.argv[1] == "--list":
        print_list()
        sys.exit(0)

    action = sys.argv[1]

    # Parse optional JSON params
    params_raw = {}
    if len(sys.argv) >= 3:
        try:
            params_raw = json.loads(sys.argv[2])
        except json.JSONDecodeError as e:
            error_exit(f"Invalid JSON params: {e}")
        if not isinstance(params_raw, dict):
            error_exit("JSON params must be an object")

    # Validate action
    if action not in ACTIONS:
        error_exit(f"Unknown action: {action}. Use --list to see available actions.")

    # Validate params
    try:
        params = validate_params(action, params_raw)
    except ValueError as e:
        error_exit(f"Validation error: {e}")

    # Ensure server is running
    ensure_server()

    # Send request to WinCtl Server
    result = send_request(action, params)

    # Post-process (screenshots: base64 → file)
    post = ACTIONS[action].get("post")
    if post == "screenshot_desktop":
        output = post_screenshot_desktop(result)
    elif post == "screenshot_window":
        output = post_screenshot_window(result)
    else:
        output = result

    success_output(output)


if __name__ == "__main__":
    main()
