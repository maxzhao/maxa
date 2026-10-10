#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List

RISKY_TRIGGER_TERMS = {
    "task",
    "session",
    "history",
    "design",
    "animation",
    "research",
    "windows",
    "click",
    "type",
    "desktop",
    "workflow",
    "任务",
    "历史",
    "设计",
    "研究",
}

RECOMMENDED_DESCRIPTION_MARKERS: list[str] = []
FORBIDDEN_DESCRIPTION_MARKERS = [
    "do not use for",
    "Triggers on",
]
MANDATORY_MODE_MARKERS = [
    "mandatory",
    "protocol",
    "always load",
    "load this skill first",
    "must load",
    "触发模式：强制",
    "触发模式:强制",
]
MANDATORY_ENFORCEMENT_MARKERS = [
    "system/project",
    "project instructions",
    "startup",
    "ChatSubmitted",
    "hook",
    "项目规则",
    "系统说明",
    "系统/项目",
]
ALLOWED_FRONTMATTER_KEYS = {"name", "description", "license", "compatibility", "metadata", "allowed-tools"}
REQUIRED_FRONTMATTER_KEYS = {"name", "description"}
ALLOWED_VISIBILITY_VALUES = {"global", "search", "hidden"}
USER_GUIDE_FILENAME = "USER_GUIDE.md"
NON_CODE_DOCUMENT_SIZE_LIMIT_BYTES = 30_000
ROOT_DOCUMENT_FILENAMES = {USER_GUIDE_FILENAME, "SYSTEM.md", "AGENTS.md", "CLAUDE.md"}
DOCUMENT_EXTENSIONS = {".md", ".mdc", ".txt"}
DOCUMENT_DIRECTORIES = {"references", "docs"}
DOCUMENT_SIZE_SKIP_DIRECTORIES = {
    ".git",
    "__pycache__",
    "assets",
    "bin",
    "hooks",
    "node_modules",
    "scripts",
    "tests",
    "vendor",
}
PYTHON_RUNTIME_SKIP_DIRECTORIES = {
    ".git",
    ".venv",
    "__pycache__",
    "node_modules",
    "vendor",
}
PYTHON_RUNTIME_DOCUMENT_FILENAMES = {"SKILL.md", USER_GUIDE_FILENAME, "SYSTEM.md", "AGENTS.md", "CLAUDE.md"}
PYTHON_RUNTIME_DOCUMENT_DIRECTORIES = {"references", "docs"}
PYTHON_RUNTIME_ENTRY_DIRECTORIES = {"bin", "hooks"}
PYTHON_RUNTIME_ENTRY_EXTENSIONS = {".sh", ".bash", ".zsh", ".fish", ".lua"}
PYTHON_SCRIPT_DOC_CALL_PATTERN = re.compile(
    r"\\bpython3?\\b[^\\n]*(?:^|/)scripts/[^\\s`'\"]+\\.py",
    re.I,
)
PYTHON_DIRECT_CALL_PATTERN = re.compile(r"\\bpython3?\\b", re.I)

DISCOURAGED_NUMBER_PATTERNS = [
    re.compile(r"\b\d+\s+tools?\b", re.I),
    re.compile(r"\b\d+\s+actions?\b", re.I),
    re.compile(r"\b\d+\s+categories\b", re.I),
]


@dataclass
class Issue:
    level: str
    path: Path
    message: str


@dataclass
class SkillMeta:
    path: Path
    name: str
    triggers: List[str]


def extract_frontmatter(text: str) -> str | None:
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    return m.group(1) if m else None


def parse_scalar(frontmatter: str, key: str) -> str | None:
    m = re.search(rf"^{re.escape(key)}:\s*(.*)$", frontmatter, re.M)
    if not m:
        return None
    value = m.group(1).strip()
    return value.strip("'\"") if value else ""


def parse_triggers(frontmatter: str) -> List[str] | None:
    inline = parse_scalar(frontmatter, "triggers")
    if inline is None:
        return None
    if inline:
        if inline.startswith("[") and inline.endswith("]"):
            body = inline[1:-1]
            values = [item.strip().strip("'\"") for item in body.split(",")]
            return [v for v in values if v]
        return [inline]

    lines = frontmatter.splitlines()
    values: List[str] = []
    in_triggers = False
    for line in lines:
        if re.match(r"^triggers:\s*$", line):
            in_triggers = True
            continue
        if in_triggers:
            if re.match(r"^\w[\w_-]*:\s*", line):
                break
            m = re.match(r"^\s+-\s+(.+?)\s*$", line)
            if m:
                value = m.group(1).strip().strip("'\"")
                if value:
                    values.append(value)
    return values


def parse_keys(frontmatter: str) -> List[str]:
    keys = []
    for line in frontmatter.splitlines():
        if ":" not in line or re.match(r"^\s+-\s+", line):
            continue
        key = line.split(":", 1)[0].strip()
        if key:
            keys.append(key)
    return keys


def is_size_checked_document(path: Path, skill_dir: Path) -> bool:
    if not path.is_file() or path.name == "SKILL.md":
        return False
    try:
        rel = path.relative_to(skill_dir)
    except ValueError:
        return False
    if any(part in DOCUMENT_SIZE_SKIP_DIRECTORIES for part in rel.parts[:-1]):
        return False
    if path.name in ROOT_DOCUMENT_FILENAMES:
        return True
    if rel.parts and rel.parts[0] in DOCUMENT_DIRECTORIES and path.suffix.lower() in DOCUMENT_EXTENSIONS:
        return True
    return False


def lint_document_sizes(skill_dir: Path) -> List[Issue]:
    issues: List[Issue] = []
    for doc_path in sorted(skill_dir.rglob("*")):
        if not is_size_checked_document(doc_path, skill_dir):
            continue
        size = doc_path.stat().st_size
        if size > NON_CODE_DOCUMENT_SIZE_LIMIT_BYTES:
            issues.append(Issue(
                "error",
                doc_path,
                f"non-code document exceeds {NON_CODE_DOCUMENT_SIZE_LIMIT_BYTES} bytes ({size} bytes); split it into focused references or compress content",
            ))
    return issues


def iter_skill_paths(skill_dir: Path) -> Iterable[Path]:
    for item in sorted(skill_dir.rglob("*")):
        if any(part in PYTHON_RUNTIME_SKIP_DIRECTORIES for part in item.relative_to(skill_dir).parts):
            continue
        if item.is_file():
            yield item


def has_python_scripts(skill_dir: Path) -> bool:
    for item in iter_skill_paths(skill_dir):
        if item.suffix == ".py" and item.name != "__init__.py":
            return True
    return False


def is_python_runtime_doc(path: Path, skill_dir: Path) -> bool:
    try:
        rel = path.relative_to(skill_dir)
    except ValueError:
        return False
    if path.name in PYTHON_RUNTIME_DOCUMENT_FILENAMES:
        return True
    return bool(rel.parts and rel.parts[0] in PYTHON_RUNTIME_DOCUMENT_DIRECTORIES and path.suffix.lower() in DOCUMENT_EXTENSIONS)


def is_python_runtime_entrypoint(path: Path, skill_dir: Path) -> bool:
    try:
        rel = path.relative_to(skill_dir)
    except ValueError:
        return False
    if rel.parts and rel.parts[0] in PYTHON_RUNTIME_ENTRY_DIRECTORIES:
        return True
    return path.suffix.lower() in PYTHON_RUNTIME_ENTRY_EXTENSIONS


def lint_python_runtime(skill_dir: Path) -> List[Issue]:
    issues: List[Issue] = []
    if not has_python_scripts(skill_dir):
        return issues

    pyproject = skill_dir / "pyproject.toml"
    if not pyproject.exists():
        issues.append(Issue(
            "error",
            pyproject,
            "Ability contains Python scripts but is not a uv project; add root pyproject.toml and configure an owning uv executor; Agents invoke cataloged scripts through call with @ability:/scripts/<script>.py",
        ))
    elif not pyproject.is_file():
        issues.append(Issue("error", pyproject, "pyproject.toml must be a file"))

    uv_lock = skill_dir / "uv.lock"
    if not uv_lock.exists():
        issues.append(Issue(
            "warn",
            uv_lock,
            "Ability contains Python scripts but has no uv.lock; run `uv lock --project <ability_root>` after declaring dependencies",
        ))

    for item in iter_skill_paths(skill_dir):
        if not (is_python_runtime_doc(item, skill_dir) or is_python_runtime_entrypoint(item, skill_dir)):
            continue
        try:
            text = item.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if is_python_runtime_doc(item, skill_dir):
            for match in PYTHON_SCRIPT_DOC_CALL_PATTERN.finditer(text):
                issues.append(Issue(
                    "error",
                    item,
                    "Agent-facing docs must not run Ability Python scripts with system python/python3; prefer call with the cataloged @ability:/scripts/<script>.py target and its uv executor; explicit manual/test commands must retain the owning uv runtime",
                ))
                break
        elif PYTHON_DIRECT_CALL_PATTERN.search(text):
            issues.append(Issue(
                "error",
                item,
                "Ability entrypoints/hooks/wrappers must not call system python/python3; route Python scripts through `uv run --project <ability_root> python <ability_root>/scripts/<script>.py ...`",
            ))
    return issues


def parse_ability_routing(skill_path: Path) -> tuple[list[str], str | None]:
    path = skill_path.parent / "ABILITY.yaml"
    if not path.is_file():
        return [], None
    text = path.read_text(encoding="utf-8")
    visibility_match = re.search(r"^visibility:\s*([^#\s]+)", text, re.MULTILINE)
    visibility = visibility_match.group(1).strip("'\"") if visibility_match else None
    triggers: list[str] = []
    in_triggers = False
    for line in text.splitlines():
        if re.match(r"^triggers:\s*$", line):
            in_triggers = True
            continue
        if in_triggers and re.match(r"^[A-Za-z][A-Za-z0-9_-]*:", line):
            break
        match = re.match(r"^\s+-\s+(.+?)\s*$", line) if in_triggers else None
        if match:
            triggers.append(match.group(1).strip("'\""))
    return triggers, visibility


def lint_skill(path: Path) -> Tuple[List[Issue], SkillMeta | None]:
    issues: List[Issue] = []
    text = path.read_text(encoding="utf-8")
    frontmatter = extract_frontmatter(text)
    if frontmatter is None:
        return [Issue("error", path, "missing standard frontmatter block")], None

    user_guide = path.parent / USER_GUIDE_FILENAME
    if not user_guide.exists():
        issues.append(Issue("error", path, f"missing required root {USER_GUIDE_FILENAME}"))
    elif not user_guide.is_file():
        issues.append(Issue("error", user_guide, f"{USER_GUIDE_FILENAME} must be a file"))
    else:
        user_guide_text = user_guide.read_text(encoding="utf-8")
        if not user_guide_text.strip():
            issues.append(Issue("error", user_guide, f"{USER_GUIDE_FILENAME} must not be empty"))

    issues.extend(lint_document_sizes(path.parent))
    issues.extend(lint_python_runtime(path.parent))

    keys = parse_keys(frontmatter)
    for required in sorted(REQUIRED_FRONTMATTER_KEYS):
        if keys.count(required) != 1:
            issues.append(Issue("error", path, f'frontmatter must contain exactly one "{required}" field, got keys={keys}'))

    extras = [k for k in keys if k not in ALLOWED_FRONTMATTER_KEYS]
    if extras:
        issues.append(Issue("error", path, f"frontmatter contains unsupported keys: {extras}; allowed keys are {sorted(ALLOWED_FRONTMATTER_KEYS)}"))

    name = parse_scalar(frontmatter, "name") or path.parent.name
    desc = parse_scalar(frontmatter, "description")
    triggers, visibility = parse_ability_routing(path)

    if visibility and visibility not in ALLOWED_VISIBILITY_VALUES:
        issues.append(Issue(
            "error",
            path,
            f'visibility must be one of {sorted(ALLOWED_VISIBILITY_VALUES)}, got "{visibility}"',
        ))

    if not desc:
        issues.append(Issue("error", path, "description missing or empty"))
        desc = ""

    if not triggers:
        triggers = []

    for needle in RECOMMENDED_DESCRIPTION_MARKERS:
        if desc and needle not in desc:
            issues.append(Issue("warn", path, f'description missing recommended marker: "{needle}"'))

    desc_lower = desc.lower()
    trigger_text_lower = " ".join(triggers).lower()
    for marker in FORBIDDEN_DESCRIPTION_MARKERS:
        if marker.lower() in desc_lower:
            issues.append(Issue("error", path, f'description contains trigger/exclusion text that belongs elsewhere: "{marker}"'))

    is_mandatory = any(marker.lower() in (desc_lower + " " + trigger_text_lower) for marker in MANDATORY_MODE_MARKERS)

    seen_local = set()
    for trig in triggers:
        normalized = trig.strip().lower()
        if not normalized:
            issues.append(Issue("error", path, "triggers contains an empty trigger phrase"))
            continue
        if normalized in seen_local:
            issues.append(Issue("warn", path, f"duplicate trigger phrase inside Ability: {trig}"))
        seen_local.add(normalized)
        if normalized in RISKY_TRIGGER_TERMS and not is_mandatory:
            issues.append(Issue("warn", path, f"trigger phrase too broad for optional/narrow Ability: {trig}"))

    if is_mandatory and not any(marker.lower() in desc_lower for marker in MANDATORY_ENFORCEMENT_MARKERS):
        issues.append(Issue("warn", path, "mandatory/protocol Ability should mention mirrored enforcement via system/project instructions or startup/ChatSubmitted hooks"))

    for pattern in DISCOURAGED_NUMBER_PATTERNS:
        if pattern.search(desc):
            issues.append(Issue("warn", path, "description contains likely stale numeric implementation detail"))
            break

    return issues, SkillMeta(path=path, name=name, triggers=triggers)


def lint_trigger_conflicts(metas: Iterable[SkillMeta]) -> List[Issue]:
    by_trigger: dict[str, List[SkillMeta]] = {}
    display: dict[str, str] = {}
    for meta in metas:
        for trig in meta.triggers:
            normalized = re.sub(r"\s+", " ", trig.strip().lower())
            if not normalized:
                continue
            by_trigger.setdefault(normalized, []).append(meta)
            display.setdefault(normalized, trig.strip())

    issues: List[Issue] = []
    for normalized, owners in sorted(by_trigger.items()):
        unique = {owner.path.resolve() for owner in owners}
        if len(unique) <= 1:
            continue
        owner_text = ", ".join(f"{owner.name} ({owner.path.parent.name})" for owner in owners)
        first = owners[0]
        issues.append(Issue(
            "warn",
            first.path,
            f'trigger keyword conflict "{display[normalized]}" used by multiple Abilities: {owner_text}; agent should refine triggers or document routing priority',
        ))
    return issues


def iter_skill_files(roots: Iterable[Path]) -> Iterable[Path]:
    seen = set()
    for root in roots:
        if not root.exists():
            continue
        for path in sorted(root.glob("*/SKILL.md")):
            resolved = path.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            yield resolved


def default_roots(project_root: Path | None) -> List[Path]:
    roots = [Path.home() / ".config/nvim/abilities"]
    if project_root is not None:
        roots.append(project_root / ".maxa/abilities")
    return roots


def main() -> int:
    parser = argparse.ArgumentParser(description="Lint Maxa Ability packages and standard SKILL.md frontmatter")
    parser.add_argument("--project-root", help="project root; if set, also lint {project_root}/.maxa/abilities")
    parser.add_argument("--root", action="append", default=[], help="additional Ability root(s) to lint; may be passed multiple times")
    parser.add_argument("--strict", action="store_true", help="treat warnings as errors")
    args = parser.parse_args()

    project_root = Path(args.project_root).expanduser().resolve() if args.project_root else None
    roots = default_roots(project_root)
    roots.extend(Path(r).expanduser().resolve() for r in args.root)

    issues: List[Issue] = []
    metas: List[SkillMeta] = []
    count = 0
    for path in iter_skill_files(roots):
        count += 1
        skill_issues, meta = lint_skill(path)
        issues.extend(skill_issues)
        if meta:
            metas.append(meta)
    issues.extend(lint_trigger_conflicts(metas))

    errors = [i for i in issues if i.level == "error"]
    warnings = [i for i in issues if i.level == "warn"]

    for item in issues:
        print(f"[{item.level.upper()}] {item.path}: {item.message}")

    checked_roots = [str(r) for r in roots if r.exists()]
    print(f"\nChecked {count} Ability packages across {len(checked_roots)} root(s)")
    for root in checked_roots:
        print(f"- {root}")
    print(f"Summary: {len(errors)} error(s), {len(warnings)} warning(s)")

    if errors:
        return 1
    if args.strict and warnings:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
