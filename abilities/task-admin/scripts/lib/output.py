"""JSON output formatting for TaskAdmin scripts."""

import json
import sys
from typing import Any


def success(data: Any) -> None:
    """Print success response and exit."""
    print(json.dumps({"success": True, "data": data}, ensure_ascii=False, indent=2))
    sys.exit(0)


def error(message: str) -> None:
    """Print error response and exit."""
    print(json.dumps({"success": False, "error": message}, ensure_ascii=False, indent=2))
    sys.exit(1)
