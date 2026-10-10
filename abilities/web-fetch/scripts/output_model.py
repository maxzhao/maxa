"""Shared output layer for functional web-fetch URL commands."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os
import re
import subprocess
import tempfile
from typing import Any

from fetch_core import FetchCoreResult


class OutputModelError(Exception):
    """Typed error raised by the URL output layer."""

    def __init__(self, code: str, message: str, *, exit_code: int = 1, metadata: dict[str, Any] | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.exit_code = exit_code
        self.metadata = metadata or {}


@dataclass(slots=True)
class RenderedOutput:
    content: bytes
    content_type: str

    def text(self) -> str:
        return self.content.decode("utf-8", errors="replace")


def _extension_for_content_type(content_type: str) -> str:
    lowered = (content_type or "").split(";", 1)[0].strip().lower()
    if lowered in {"text/html", "application/xhtml+xml"}:
        return ".html"
    if lowered in {"application/json", "application/ld+json"}:
        return ".json"
    if lowered in {"application/xml", "text/xml", "application/rss+xml", "application/atom+xml"}:
        return ".xml"
    if lowered == "image/svg+xml":
        return ".svg"
    if lowered.startswith("text/"):
        return ".txt"
    return ".bin"


def convert_to_markdown(result: FetchCoreResult) -> RenderedOutput:
    """Convert fetched content to Markdown through `uvx markitdown`.

    A system temporary directory is used for the input file so markitdown can infer
    a useful format from extension/content. The temp directory is removed by the
    context manager on both success and failure.
    """

    suffix = _extension_for_content_type(result.content_type)
    with tempfile.TemporaryDirectory(prefix="web-fetch-markitdown-") as tmpdir:
        input_path = Path(tmpdir) / f"input{suffix}"
        input_path.write_bytes(result.content)
        try:
            completed = subprocess.run(
                ["uvx", "markitdown", str(input_path)],
                cwd=os.getcwd(),
                capture_output=True,
                check=False,
                timeout=120,
            )
        except FileNotFoundError as exc:
            raise OutputModelError(
                "convert_failed",
                "[convert] uvx executable not found; markdown conversion requires `uvx markitdown`. Suggestion: use `--format raw --output <path>` to save original content.",
                exit_code=3,
            ) from exc
        except subprocess.TimeoutExpired as exc:
            stderr = (exc.stderr or b"").decode("utf-8", errors="replace") if isinstance(exc.stderr, bytes) else str(exc.stderr or "")
            raise OutputModelError(
                "convert_failed",
                f"[convert] markitdown timed out after 120s. stderr: {stderr}. Suggestion: use `--format raw --output <path>` to save original content.",
                exit_code=3,
                metadata={"stderr": stderr},
            ) from exc

        if completed.returncode != 0:
            stderr = completed.stderr.decode("utf-8", errors="replace").strip()
            raise OutputModelError(
                "convert_failed",
                f"[convert] markitdown failed with exit code {completed.returncode}. stderr: {stderr}. Suggestion: use `--format raw --output <path>` to save original content, or adjust `--format`.",
                exit_code=3,
                metadata={"exit_code": completed.returncode, "stderr": stderr},
            )
        return RenderedOutput(completed.stdout, "text/markdown; charset=utf-8")


def render_output(result: FetchCoreResult, *, output_format: str) -> RenderedOutput:
    if output_format == "raw":
        return RenderedOutput(result.content, result.content_type)
    if output_format == "markdown":
        return convert_to_markdown(result)
    raise OutputModelError("invalid_arguments", f"[output] unsupported format: {output_format}", exit_code=2)


def _merged_context_ranges(text: str, regex: re.Pattern[str], context_chars: int) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    for match in regex.finditer(text):
        start = max(0, match.start() - context_chars)
        end = min(len(text), match.end() + context_chars)
        if ranges and start <= ranges[-1][1]:
            ranges[-1] = (ranges[-1][0], max(ranges[-1][1], end))
        else:
            ranges.append((start, end))
    return ranges


def apply_pattern(rendered: RenderedOutput, *, pattern: str | None, context_chars: int, textual: bool) -> RenderedOutput:
    """Apply regex context extraction to the final rendered text."""

    if not pattern:
        return rendered
    if context_chars < 0:
        raise OutputModelError("invalid_arguments", "[pattern] --context-chars must be >= 0", exit_code=2)
    if not textual:
        raise OutputModelError(
            "pattern_binary_not_supported",
            "[pattern] --pattern requires final text content; raw binary responses cannot be searched. Suggestion: use `--format markdown` or fetch text content before applying --pattern.",
            exit_code=1,
        )
    try:
        regex = re.compile(pattern)
    except re.error as exc:
        raise OutputModelError("pattern_invalid", f"[pattern] invalid regex: {exc}", exit_code=2) from exc

    text = rendered.text()
    ranges = _merged_context_ranges(text, regex, context_chars)
    if not ranges:
        raise OutputModelError("pattern_no_match", f"[pattern] no matches for regex: {pattern}", exit_code=1)

    chunks = [text[start:end] for start, end in ranges]
    extracted = "\n\n---\n\n".join(chunks).encode("utf-8")
    return RenderedOutput(extracted, "text/plain; charset=utf-8")


def write_or_print(rendered: RenderedOutput, *, output_path: str | None, overwrite: bool, textual_inline: bool) -> bytes | str:
    """Return bytes for inline stdout or a status line for file output."""

    if output_path:
        path = Path(output_path).expanduser()
        if path.exists() and not overwrite:
            raise OutputModelError("output_exists", f"[output] Target file already exists: {path}. Use --overwrite to replace it.", exit_code=1, metadata={"path": str(path)})
        try:
            path.write_bytes(rendered.content)
        except OSError as exc:
            raise OutputModelError("output_failed", f"[output] Failed to write {path}: {exc}. Suggestion: adjust the path/permissions or use --overwrite if appropriate.", exit_code=1, metadata={"path": str(path)}) from exc
        return f"Wrote {path}"

    if not textual_inline:
        raise OutputModelError(
            "binary_inline_not_supported",
            "[output] raw inline output is not supported for binary responses. Suggestion: use `--format markdown` if you need to identify/convert the content, or `--format raw --output <path>` if you only need to download it.",
            exit_code=1,
        )
    return rendered.content


def emit_rendered(
    result: FetchCoreResult,
    *,
    output_format: str,
    output_path: str | None,
    overwrite: bool,
    pattern: str | None = None,
    context_chars: int = 200,
) -> bytes | str:
    rendered = render_output(result, output_format=output_format)
    textual = output_format == "markdown" or result.is_textual()
    rendered = apply_pattern(rendered, pattern=pattern, context_chars=context_chars, textual=textual)
    textual_inline = True if pattern else textual
    return write_or_print(rendered, output_path=output_path, overwrite=overwrite, textual_inline=textual_inline)
