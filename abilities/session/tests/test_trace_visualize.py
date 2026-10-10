from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT_PATH = REPO_ROOT / "abilities" / "session" / "scripts" / "trace_visualize.py"

spec = importlib.util.spec_from_file_location("trace_visualize", SCRIPT_PATH)
tv = importlib.util.module_from_spec(spec)
assert spec and spec.loader
sys.modules["trace_visualize"] = tv
spec.loader.exec_module(tv)


def write_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")


def make_project() -> Path:
    root = Path(tempfile.mkdtemp(prefix="trace-viz-test-"))
    (root / ".maxa" / "history" / "traces").mkdir(parents=True)
    (root / ".maxa" / "history" / "chats").mkdir(parents=True)
    (root / ".maxa" / ".stignore").write_text("#include .stignore-shared\n", encoding="utf-8")
    (root / ".maxa" / ".stignore-shared").write_text(
        "# test\n(?d)/history\n(?d)/history/**\n", encoding="utf-8"
    )
    return root


def sample_events(root_id: str) -> list[dict[str, object]]:
    root_span = "span_root"
    child_span = "span_child"
    return [
        {
            "event_id": "evt_start",
            "root_trace_id": root_id,
            "kind": "trace.started",
            "created_at": 1,
            "span_id": root_span,
            "session": {"save_id": root_id, "role": "root", "temporary": False},
        },
        {
            "event_id": "evt_prompt",
            "root_trace_id": root_id,
            "kind": "main_turn.user_prompt",
            "created_at": 2,
            "span_id": root_span,
            "session": {"save_id": root_id, "role": "root", "temporary": False},
            "message": {"role": "user", "content": "Please do something very long " * 20, "message_index": 1},
        },
        {
            "event_id": "evt_reply",
            "root_trace_id": root_id,
            "kind": "main_turn.agent_reply",
            "created_at": 3,
            "span_id": root_span,
            "session": {"save_id": root_id, "role": "root", "temporary": False},
            "message": {"role": "assistant", "content": "Done", "message_index": 2},
        },
        {
            "event_id": "evt_fork",
            "root_trace_id": root_id,
            "kind": "fork.created",
            "created_at": 4,
            "span_id": child_span,
            "parent_span_id": root_span,
            "session": {"save_id": "child_save", "role": "fork", "temporary": False},
            "child": {"save_id": "child_save", "title": "Child"},
        },
        {
            "event_id": "evt_sub_done",
            "root_trace_id": root_id,
            "kind": "subagent.completed",
            "created_at": 5,
            "span_id": child_span,
            "parent_span_id": root_span,
            "session": {"save_id": "child_save", "role": "subagent", "temporary": False},
            "tool": {"name": "run_agent", "mode": "new_chat"},
            "result": {"status": "completed", "content": "child final"},
        },
        {
            "event_id": "evt_archive",
            "root_trace_id": root_id,
            "kind": "compression.archive_created",
            "created_at": 6,
            "span_id": root_span,
            "session": {"save_id": root_id, "role": "root", "temporary": False},
            "archive": {"event_id": "archive_1", "path": "archive_1.json", "turn_count": 2},
        },
    ]


def create_recorded_trace(project: Path, root_id: str = "trace_test") -> None:
    tdir = project / ".maxa" / "history" / "traces" / root_id
    archives = tdir / "archives"
    archives.mkdir(parents=True)
    write_json(
        tdir / "manifest.json",
        {
            "schema_version": 1,
            "root_trace_id": root_id,
            "root_save_id": root_id,
            "root_title": "Trace Test",
            "status": "active",
            "source": "trace_start",
        },
    )
    (tdir / "events.jsonl").write_text(
        "\n".join(json.dumps(e, ensure_ascii=False) for e in sample_events(root_id)) + "\n",
        encoding="utf-8",
    )
    write_json(
        archives / "archive_1.json",
        {
            "event_id": "archive_1",
            "root_trace_id": root_id,
            "source_save_id": root_id,
            "span_id": "span_root",
            "range": {"start_index": 1, "end_index": 2},
            "turns": [
                {"role": "user", "content": "hello", "message_index": 1},
                {"role": "assistant", "content": "world", "message_index": 2},
            ],
        },
    )


def test_recorded_export_canvas_markdown_and_stignore() -> None:
    project = make_project()
    create_recorded_trace(project)
    result = tv.export_trace(
        tv.build_parser().parse_args(
            ["--project-root", str(project), "--root-trace-id", "trace_test", "--json"]
        )
    )
    canvas_path = Path(result["files"]["canvas"])
    markdown_path = Path(result["files"]["markdown"])
    assert canvas_path.exists()
    assert markdown_path.exists()
    canvas = json.loads(canvas_path.read_text(encoding="utf-8"))
    tv.validate_canvas(canvas)
    assert result["counts"]["events"] == 6
    assert result["counts"]["spans"] == 2
    markdown = markdown_path.read_text(encoding="utf-8")
    assert "trace-overview.canvas" in markdown
    assert "Prompt / Reply Excerpts" in markdown
    assert "...[truncated]" in markdown
    stignore_lines = (project / ".maxa" / ".stignore-shared").read_text(encoding="utf-8").splitlines()
    assert not tv.stignore_is_ignored(stignore_lines, "history/traces/trace_test/visualization/trace-summary.md")
    assert not tv.stignore_is_ignored(stignore_lines, "history/traces/trace_test/visualization/trace-overview.canvas")
    assert tv.stignore_is_ignored(stignore_lines, "history/traces/trace_test/events.jsonl")
    assert tv.stignore_is_ignored(stignore_lines, "history/chats/chat.json")


def test_overwrite_conflict_and_determinism() -> None:
    project = make_project()
    create_recorded_trace(project)
    parser = tv.build_parser()
    args = parser.parse_args(["--project-root", str(project), "--root-trace-id", "trace_test"])
    tv.export_trace(args)
    try:
        tv.export_trace(args)
        raise AssertionError("expected conflict")
    except FileExistsError as exc:
        assert "--overwrite" in str(exc)
    args_overwrite = parser.parse_args(["--project-root", str(project), "--root-trace-id", "trace_test", "--overwrite"])
    tv.export_trace(args_overwrite)
    first = (project / ".maxa" / "history" / "traces" / "trace_test" / "visualization" / "trace-overview.canvas").read_text(encoding="utf-8")
    tv.export_trace(args_overwrite)
    second = (project / ".maxa" / "history" / "traces" / "trace_test" / "visualization" / "trace-overview.canvas").read_text(encoding="utf-8")
    assert first == second


def test_synthesized_export_has_gaps_and_no_fake_trace_manifest() -> None:
    project = make_project()
    save_id = "saved_chat"
    write_json(
        project / ".maxa" / "history" / "chats" / f"{save_id}.json",
        {
            "save_id": save_id,
            "title": "Saved Chat",
            "updated_at": 123,
            "messages": [
                {"role": "user", "content": "hello"},
                {"role": "llm", "content": "hi"},
                {"role": "tool", "content": "ignored"},
            ],
        },
    )
    result = tv.export_trace(
        tv.build_parser().parse_args(["--project-root", str(project), "--save-id", save_id])
    )
    assert result["source"] == "synthesized"
    assert result["counts"]["events"] == 2
    assert result["warnings"]
    assert not (project / ".maxa" / "history" / "traces" / save_id / "manifest.json").exists()
    assert (project / ".maxa" / "history" / "traces" / save_id / "visualization" / "trace-summary.md").exists()


def test_output_path_safety() -> None:
    project = make_project()
    create_recorded_trace(project)
    parser = tv.build_parser()
    bad_sets = [
        ["--project-root", str(project), "--root-trace-id", "trace_test", "--output-dir", "../outside"],
        ["--project-root", str(project), "--root-trace-id", "trace_test", "--output-dir", "/tmp/outside"],
    ]
    for argv in bad_sets:
        try:
            tv.export_trace(parser.parse_args(argv))
            raise AssertionError(f"expected unsafe path rejection for {argv}")
        except ValueError:
            pass


def test_cli_help() -> None:
    completed = subprocess.run(
        [sys.executable, str(SCRIPT_PATH), "--help"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    assert "--root-trace-id" in completed.stdout
    assert "--overwrite" in completed.stdout


def run_tests() -> None:
    tests = [
        test_recorded_export_canvas_markdown_and_stignore,
        test_overwrite_conflict_and_determinism,
        test_synthesized_export_has_gaps_and_no_fake_trace_manifest,
        test_output_path_safety,
        test_cli_help,
    ]
    for test in tests:
        test()
    print(f"Results: {len(tests)} passed, 0 failed")


if __name__ == "__main__":
    run_tests()
