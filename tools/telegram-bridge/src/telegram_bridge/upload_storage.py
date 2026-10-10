from __future__ import annotations

import mimetypes
import os
import re
import unicodedata
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Awaitable, Callable

MAX_UPLOAD_BYTES = 20 * 1024 * 1024


class UploadError(Exception):
    code = "upload_failed"


class UploadTooLarge(UploadError):
    code = "file_too_large"


class UploadPathError(UploadError):
    code = "unsafe_path"


@dataclass(frozen=True)
class StoredUpload:
    relative_path: str
    absolute_path: Path
    size: int


def extension_for(mime_type: str | None, default: str = "") -> str:
    extension = mimetypes.guess_extension(str(mime_type or "").split(";", 1)[0].strip()) or default
    return extension if not extension or extension.startswith(".") else "." + extension


def safe_filename(name: str | None, *, fallback: str, extension: str = "") -> str:
    raw = unicodedata.normalize("NFKC", str(name or "")).replace("\\", "/").split("/")[-1]
    raw = "".join("_" if unicodedata.category(char).startswith("C") else char for char in raw)
    raw = re.sub(r"[<>:\"/\\|?*]+", "_", raw).strip(" .")
    if not raw or raw.upper() in {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)), *(f"LPT{i}" for i in range(1, 10))}:
        raw = fallback
    raw = raw[:180].rstrip(" .") or fallback
    if extension and not Path(raw).suffix:
        raw += extension
    return raw


def safe_session_dir(project_root: str | Path, session_id: str, *, create: bool = False) -> tuple[Path, Path]:
    root = Path(project_root).expanduser()
    if not root.is_absolute():
        raise UploadPathError("project root must be absolute")
    if not re.fullmatch(r"[A-Za-z0-9_-]{8,128}", session_id):
        raise UploadPathError("invalid upload session id")
    real_root = root.resolve()
    upload_root = real_root / ".maxa" / "upload"
    session_dir = upload_root / session_id

    # The runtime upload root and session directory are owned storage
    # boundaries, not redirectable aliases. Comparing lexical paths rooted at
    # the real project with resolved paths rejects symlinks in any component,
    # including links to another directory inside the same project.
    for path, label in ((upload_root, "upload root"), (session_dir, "upload session")):
        if path.is_symlink() or (path.exists() and path.resolve() != path):
            raise UploadPathError(f"{label} must not be a symlink or redirected path")
    if create:
        upload_root.mkdir(parents=True, exist_ok=True)
        if upload_root.is_symlink() or upload_root.resolve() != upload_root:
            raise UploadPathError("upload root must not be a symlink or redirected path")
        session_dir.mkdir(exist_ok=True)
        if session_dir.is_symlink() or session_dir.resolve() != session_dir:
            raise UploadPathError("upload session must not be a symlink or redirected path")
    return real_root, session_dir


class UploadStorage:
    def __init__(self, project_root: str | Path, session_id: str, *, max_bytes: int = MAX_UPLOAD_BYTES):
        self.project_root, self.session_dir = safe_session_dir(project_root, session_id)
        self.session_id = session_id
        self.max_bytes = int(max_bytes)
        self._assert_below(self.session_dir)

    def _assert_below(self, path: Path) -> None:
        try:
            path.resolve(strict=False).relative_to(self.project_root)
        except ValueError as exc:
            raise UploadPathError("upload path escapes project root") from exc

    def destination(self, filename: str, number: int = 1) -> Path:
        self.project_root, self.session_dir = safe_session_dir(self.project_root, self.session_id, create=True)
        base = self.session_dir / filename
        candidate = base if number == 1 else self.session_dir / f"{base.stem}-{number}{base.suffix}"
        self._assert_below(candidate)
        return candidate

    def _publish_no_clobber(self, partial: Path, filename: str) -> Path:
        number = 1
        while True:
            candidate = self.destination(filename, number)
            try:
                # Hard-link creation is atomic and fails if the destination already
                # exists. Both paths are in the same session directory/filesystem.
                os.link(partial, candidate)
            except FileExistsError:
                number += 1
                continue
            partial.unlink()
            return candidate

    async def store(self, filename: str, downloader: Callable[[Path, int], Awaitable[int]]) -> StoredUpload:
        self.project_root, self.session_dir = safe_session_dir(self.project_root, self.session_id, create=True)
        partial = self.session_dir / f".upload-{uuid.uuid4().hex}.part"
        self._assert_below(partial)
        try:
            size = int(await downloader(partial, self.max_bytes))
            if size > self.max_bytes:
                raise UploadTooLarge("observed download exceeds limit")
            if not partial.is_file():
                raise UploadError("download did not create a regular file")
            final_path = self._publish_no_clobber(partial, filename)
            if not final_path.is_file():
                raise UploadPathError("final upload is not a regular file")
            relative = final_path.resolve().relative_to(self.project_root).as_posix()
            return StoredUpload(relative_path=relative, absolute_path=final_path, size=size)
        except Exception:
            try:
                partial.unlink(missing_ok=True)
            except OSError:
                pass
            raise
