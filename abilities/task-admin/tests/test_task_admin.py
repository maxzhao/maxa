import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest


SKILL_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = SKILL_ROOT / "scripts"


def run_cli_result(project: Path, script: str, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPTS / f"{script}.py"),
            "--project-root",
            str(project),
            *args,
        ],
        text=True,
        capture_output=True,
        check=False,
    )


def run_cli(project: Path, script: str, *args: str, ok: bool = True) -> dict:
    result = run_cli_result(project, script, *args)
    payload = json.loads(result.stdout)
    if ok:
        assert result.returncode == 0, result.stdout + result.stderr
        assert payload["success"] is True
        return payload["data"]
    assert result.returncode != 0
    assert payload["success"] is False
    return payload


def create_task(
    project: Path,
    name: str,
    *,
    dependencies: str = "",
    priority: str = "medium",
) -> dict:
    source_dir = project / "inputs"
    source_dir.mkdir(exist_ok=True)
    suffix = name.replace(" ", "-")
    plan = source_dir / f"{suffix}-plan.md"
    todo = source_dir / f"{suffix}-todo.md"
    plan.write_text(f"# {name}\n\n## Goal\n\nImplement {name}.\n", encoding="utf-8")
    todo.write_text(f"# TODO\n\n- [ ] Implement {name}.\n", encoding="utf-8")
    args = [
        "--name",
        name,
        "--priority",
        priority,
        "--dependencies",
        dependencies,
        "--plan-file",
        str(plan),
        "--todo-file",
        str(todo),
    ]
    return run_cli(project, "create_task", *args)


def fire_events(result: subprocess.CompletedProcess[str]) -> list[dict]:
    prefix = "__FIRE_EVENT__:"
    return [json.loads(line.removeprefix(prefix)) for line in result.stderr.splitlines() if line.startswith(prefix)]


def test_create_resolve_list_next_and_update(tmp_path: Path) -> None:
    first = create_task(tmp_path, "First", priority="high")
    assert first["id"] == 1
    task_dir = Path(first["task_dir"])
    assert {path.name for path in task_dir.iterdir()} == {"_meta.yaml", "plan.md", "todo.md"}

    second = create_task(tmp_path, "Second", dependencies="1")
    assert second["id"] == 2
    state = (tmp_path / ".maxa/tasks/state.yaml").read_text(encoding="utf-8")
    assert "currentTag: master" in state
    assert (tmp_path / ".maxa/tasks/master/_meta.yaml").is_file()

    resolved = run_cli(tmp_path, "resolve_task", "--id", "1")
    assert resolved["exists"] is True
    assert resolved["plan_file"].endswith("task_001/plan.md")
    assert "parent_file" not in resolved
    assert "progress_file" not in resolved

    listed = run_cli(tmp_path, "list_tasks")
    assert [task["id"] for task in listed["tasks"]] == [1, 2]
    assert all("subtasks" not in task for task in listed["tasks"])

    next_task = run_cli(tmp_path, "next_task")["next_task"]
    assert next_task["id"] == 1
    run_cli(tmp_path, "update_task", "--id", "1", "--status", "done")
    next_task = run_cli(tmp_path, "next_task")["next_task"]
    assert next_task["id"] == 2


def test_status_updates_emit_ordered_derived_lifecycle_events(tmp_path: Path) -> None:
    task = create_task(tmp_path, "Lifecycle")
    task_id = str(task["id"])
    base_payload = {"task_id": task_id, "tag": "master", "title": "Lifecycle"}

    started = run_cli_result(tmp_path, "update_task", "--id", task_id, "--status", "in-progress")
    assert started.returncode == 0, started.stdout + started.stderr
    assert fire_events(started) == [
        {
            "event": "TaskStatusChanged",
            "data": {**base_payload, "prev_status": "pending", "new_status": "in-progress"},
        },
        {"event": "TaskStarted", "data": base_payload},
    ]

    unchanged = run_cli_result(tmp_path, "update_task", "--id", task_id, "--status", "in-progress")
    assert unchanged.returncode == 0, unchanged.stdout + unchanged.stderr
    assert fire_events(unchanged) == [
        {
            "event": "TaskStatusChanged",
            "data": {**base_payload, "prev_status": "in-progress", "new_status": "in-progress"},
        }
    ]

    review = run_cli_result(tmp_path, "update_task", "--id", task_id, "--status", "review")
    assert review.returncode == 0, review.stdout + review.stderr
    assert [event["event"] for event in fire_events(review)] == ["TaskStatusChanged"]

    restarted = run_cli_result(tmp_path, "update_task", "--id", task_id, "--status", "in-progress")
    assert restarted.returncode == 0, restarted.stdout + restarted.stderr
    assert [event["event"] for event in fire_events(restarted)] == ["TaskStatusChanged", "TaskStarted"]

    completed = run_cli_result(tmp_path, "update_task", "--id", task_id, "--status", "done")
    assert completed.returncode == 0, completed.stdout + completed.stderr
    assert fire_events(completed) == [
        {
            "event": "TaskStatusChanged",
            "data": {**base_payload, "prev_status": "in-progress", "new_status": "done"},
        },
        {"event": "TaskCompleted", "data": base_payload},
    ]

    unchanged_done = run_cli_result(tmp_path, "update_task", "--id", task_id, "--status", "done")
    assert unchanged_done.returncode == 0, unchanged_done.stdout + unchanged_done.stderr
    assert [event["event"] for event in fire_events(unchanged_done)] == ["TaskStatusChanged"]


def test_dependency_validation_and_dotted_id_rejection(tmp_path: Path) -> None:
    create_task(tmp_path, "One")
    create_task(tmp_path, "Two")
    create_task(tmp_path, "Three")

    run_cli(tmp_path, "manage_deps", "--action", "add", "--id", "2", "--depends-on", "1")
    run_cli(tmp_path, "manage_deps", "--action", "add", "--id", "3", "--depends-on", "2")
    cycle = run_cli(
        tmp_path,
        "manage_deps",
        "--action",
        "add",
        "--id",
        "1",
        "--depends-on",
        "3",
        ok=False,
    )
    assert "circular dependency" in cycle["error"]
    assert run_cli(tmp_path, "analyze_deps", "--action", "validate")["valid"] is True

    dotted = run_cli(tmp_path, "resolve_task", "--id", "3.2", ok=False)
    assert "expected a positive integer" in dotted["error"]
    missing = run_cli(
        tmp_path,
        "create_task",
        "--name",
        "Bad",
        "--dependencies",
        "99",
        "--plan-file",
        str(tmp_path / "inputs/One-plan.md"),
        "--todo-file",
        str(tmp_path / "inputs/One-todo.md"),
        ok=False,
    )
    assert "do not exist" in missing["error"]
    assert not (tmp_path / ".maxa/tasks/master/task_004").exists()


def test_move_renumber_delete_and_tag_lifecycle(tmp_path: Path) -> None:
    create_task(tmp_path, "Source")
    create_task(tmp_path, "Dependent", dependencies="1")
    run_cli(tmp_path, "manage_tag", "--action", "create", "--name", "beta")

    blocked = run_cli(
        tmp_path,
        "move_task",
        "--id",
        "1",
        "--to-tag",
        "beta",
        ok=False,
    )
    assert "depended on" in blocked["error"]

    moved = run_cli(
        tmp_path,
        "move_task",
        "--id",
        "1",
        "--to-tag",
        "beta",
        "--force",
    )
    assert moved["new_id"] == 1
    master = run_cli(tmp_path, "list_tasks", "--tag", "master")
    assert master["tasks"][0]["dependencies"] == []

    assert run_cli(tmp_path, "manage_tag", "--action", "list")["current_tag"] == "master"
    run_cli(tmp_path, "manage_tag", "--action", "switch", "--name", "beta")
    create_task(tmp_path, "Beta dependent", dependencies="1")
    renumbered = run_cli(tmp_path, "renumber_task", "--id", "1", "--to", "3")
    assert renumbered["operation"] == "move"
    beta = run_cli(tmp_path, "list_tasks", "--tag", "beta")
    assert next(task for task in beta["tasks"] if task["id"] == 2)["dependencies"] == [3]

    swapped = run_cli(tmp_path, "renumber_task", "--id", "3", "--to", "2")
    assert swapped["operation"] == "swap"
    beta = run_cli(tmp_path, "list_tasks", "--tag", "beta")
    assert next(task for task in beta["tasks"] if task["id"] == 3)["dependencies"] == [2]

    blocked_delete = run_cli(tmp_path, "delete_task", "--id", "2", ok=False)
    assert "depended on" in blocked_delete["error"]
    run_cli(tmp_path, "delete_task", "--id", "2", "--force")
    beta = run_cli(tmp_path, "list_tasks", "--tag", "beta")
    assert beta["tasks"][0]["dependencies"] == []

    run_cli(tmp_path, "manage_tag", "--action", "copy", "--name", "copy", "--copy-from", "beta")
    copied = run_cli(tmp_path, "list_tasks", "--tag", "copy")
    assert len(copied["tasks"]) == 1
    run_cli(tmp_path, "manage_tag", "--action", "rename", "--name", "copy", "--new-name", "archive")
    run_cli(tmp_path, "manage_tag", "--action", "switch", "--name", "archive")
    deleted = run_cli(tmp_path, "manage_tag", "--action", "delete", "--name", "archive")
    assert deleted["switched_to"] == "master"


def test_move_blocks_destination_missing_outgoing_dependencies(tmp_path: Path) -> None:
    create_task(tmp_path, "Dependency")
    create_task(tmp_path, "Mover", dependencies="1")
    run_cli(tmp_path, "manage_tag", "--action", "create", "--name", "beta")

    blocked = run_cli(
        tmp_path,
        "move_task",
        "--id",
        "2",
        "--to-tag",
        "beta",
        ok=False,
    )
    assert "absent from destination" in blocked["error"]

    run_cli(tmp_path, "manage_tag", "--action", "switch", "--name", "beta")
    create_task(tmp_path, "Destination dependency")
    run_cli(tmp_path, "manage_tag", "--action", "switch", "--name", "master")
    moved = run_cli(
        tmp_path,
        "move_task",
        "--id",
        "2",
        "--to-tag",
        "beta",
    )
    assert moved["new_id"] == 2
    beta = run_cli(tmp_path, "list_tasks", "--tag", "beta")
    assert next(task for task in beta["tasks"] if task["id"] == 2)["dependencies"] == [1]


@pytest.mark.parametrize(
    ("script", "args"),
    [
        ("resolve_task", ["--id", "1", "--tag", "../escape"]),
        ("list_tasks", ["--tag", "a/b"]),
        ("next_task", ["--tag", "../escape"]),
        ("move_task", ["--id", "1", "--to-tag", "../escape"]),
        ("manage_tag", ["--action", "create", "--name", "../escape"]),
    ],
)
def test_cli_rejects_tag_path_escape(tmp_path: Path, script: str, args: list[str]) -> None:
    create_task(tmp_path, "Valid")
    payload = run_cli(tmp_path, script, *args, ok=False)
    assert "Invalid tag name" in payload["error"]
    assert not (tmp_path / ".maxa/escape").exists()


def test_move_failure_restores_source_optional_docs_and_incoming_edges(tmp_path: Path, monkeypatch) -> None:
    source = create_task(tmp_path, "Source")
    create_task(tmp_path, "Dependent", dependencies="1")
    notes = Path(source["task_dir"]) / "notes.md"
    notes.write_text("source evidence\n", encoding="utf-8")
    run_cli(tmp_path, "manage_tag", "--action", "create", "--name", "beta")

    spec = importlib.util.spec_from_file_location("taskadmin_move_failure", SCRIPTS / "move_task.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    real_replace = os.replace
    destination = tmp_path / ".maxa/tasks/beta/task_001"

    def fail_publication(src, dst):
        if Path(dst) == destination:
            raise OSError("injected publication failure")
        return real_replace(src, dst)

    monkeypatch.setattr(module.os, "replace", fail_publication)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "move_task.py",
            "--project-root",
            str(tmp_path),
            "--id",
            "1",
            "--to-tag",
            "beta",
            "--force",
        ],
    )
    with pytest.raises(SystemExit) as exc:
        module.main()
    assert exc.value.code == 1
    source_dir = tmp_path / ".maxa/tasks/master/task_001"
    assert (source_dir / "_meta.yaml").is_file()
    assert (source_dir / "plan.md").is_file()
    assert (source_dir / "todo.md").is_file()
    assert (source_dir / "notes.md").read_text(encoding="utf-8") == "source evidence\n"
    assert not destination.exists()
    master = run_cli(tmp_path, "list_tasks", "--tag", "master")
    assert next(task for task in master["tasks"] if task["id"] == 2)["dependencies"] == [1]


def test_create_and_update_reject_blank_task_names(tmp_path: Path) -> None:
    inputs = tmp_path / "inputs"
    inputs.mkdir()
    plan = inputs / "plan.md"
    todo = inputs / "todo.md"
    plan.write_text("# Plan\n", encoding="utf-8")
    todo.write_text("# TODO\n", encoding="utf-8")
    created = run_cli(
        tmp_path,
        "create_task",
        "--name",
        "   ",
        "--plan-file",
        str(plan),
        "--todo-file",
        str(todo),
        ok=False,
    )
    assert "must not be empty" in created["error"]
    task = create_task(tmp_path, "Valid")
    updated = run_cli(tmp_path, "update_task", "--id", str(task["id"]), "--name", "  ", ok=False)
    assert "must not be empty" in updated["error"]


def test_create_rejects_empty_required_document_without_partial_task(tmp_path: Path) -> None:
    inputs = tmp_path / "inputs"
    inputs.mkdir()
    plan = inputs / "plan.md"
    todo = inputs / "todo.md"
    plan.write_text("# Plan\n", encoding="utf-8")
    todo.write_text("", encoding="utf-8")
    result = run_cli(
        tmp_path,
        "create_task",
        "--name",
        "Incomplete",
        "--plan-file",
        str(plan),
        "--todo-file",
        str(todo),
        ok=False,
    )
    assert "must not be empty" in result["error"]
    assert not (tmp_path / ".maxa/tasks").exists()


@pytest.mark.parametrize(
    ("script", "args"),
    [
        ("create_task", ["--name", "New", "--plan-file", "inputs/One-plan.md", "--todo-file", "inputs/One-todo.md", "--tag", "beta"]),
        ("update_task", ["--id", "1", "--status", "in-progress", "--tag", "beta"]),
        ("delete_task", ["--id", "1", "--tag", "beta"]),
        ("manage_deps", ["--action", "add", "--id", "2", "--depends-on", "1", "--tag", "beta"]),
        ("renumber_task", ["--id", "1", "--to", "3", "--tag", "beta"]),
        ("analyze_deps", ["--action", "fix", "--tag", "master"]),
        ("move_task", ["--id", "1", "--from-tag", "master", "--to-tag", "beta"]),
    ],
)
def test_write_selectors_are_rejected_before_mutation(tmp_path: Path, script: str, args: list[str]) -> None:
    create_task(tmp_path, "One")
    create_task(tmp_path, "Two")
    run_cli(tmp_path, "manage_tag", "--action", "create", "--name", "beta")
    store = tmp_path / ".maxa/tasks"
    before = {str(path.relative_to(store)): path.read_bytes() for path in store.rglob("*") if path.is_file()}
    result = run_cli_result(tmp_path, script, *args)
    assert result.returncode == 2
    assert "--from-tag" in result.stderr if script == "move_task" else "--tag" in result.stderr
    assert fire_events(result) == []
    assert before == {str(path.relative_to(store)): path.read_bytes() for path in store.rglob("*") if path.is_file()}


@pytest.mark.parametrize("state_case", ["missing", "malformed", "invalid-tag", "wrong-type", "missing-tag", "missing-meta"])
def test_invalid_existing_state_blocks_writes_and_switch_repairs(tmp_path: Path, state_case: str) -> None:
    task = create_task(tmp_path, "One")
    store = tmp_path / ".maxa/tasks"
    state = store / "state.yaml"
    if state_case == "missing":
        state.unlink()
    elif state_case == "malformed":
        state.write_text("not yaml\n", encoding="utf-8")
    elif state_case == "invalid-tag":
        state.write_text("currentTag: ../escape\n", encoding="utf-8")
    elif state_case == "wrong-type":
        state.write_text("currentTag: []\n", encoding="utf-8")
    elif state_case == "missing-tag":
        state.write_text("currentTag: absent\n", encoding="utf-8")
    else:
        (store / "master/_meta.yaml").unlink()
    before = {str(path.relative_to(store)): path.read_bytes() for path in store.rglob("*") if path.is_file()}
    for script, args in [
        ("create_task", ["--name", "Blocked", "--plan-file", str(tmp_path / "inputs/One-plan.md"), "--todo-file", str(tmp_path / "inputs/One-todo.md")]),
        ("update_task", ["--id", "1", "--status", "in-progress"]),
    ]:
        result = run_cli_result(tmp_path, script, *args)
        assert result.returncode == 1
        assert "Invalid current tag state" in json.loads(result.stdout)["error"]
        assert fire_events(result) == []
        assert before == {str(path.relative_to(store)): path.read_bytes() for path in store.rglob("*") if path.is_file()}
    assert run_cli(tmp_path, "resolve_task", "--id", "1", "--tag", "master")["exists"] is True
    run_cli(tmp_path, "manage_tag", "--action", "create", "--name", "repair")
    run_cli(tmp_path, "manage_tag", "--action", "switch", "--name", "repair")
    created = create_task(tmp_path, "Repaired")
    assert created["tag"] == "repair"
    assert Path(task["meta_file"]).read_text(encoding="utf-8").find("status: pending") >= 0


def test_switch_controls_writes_and_retains_cross_tag_reads(tmp_path: Path) -> None:
    master = create_task(tmp_path, "Same title")
    master_before = Path(master["meta_file"]).read_bytes()
    run_cli(tmp_path, "manage_tag", "--action", "create", "--name", "beta", "--workspace", "declaration")
    run_cli(tmp_path, "manage_tag", "--action", "switch", "--name", "beta")
    one = create_task(tmp_path, "Same title")
    two = create_task(tmp_path, "Same title")
    assert (one["tag"], one["id"], two["id"]) == ("beta", 1, 2)
    started = run_cli_result(tmp_path, "update_task", "--id", "1", "--status", "in-progress", "--workspace", "opaque-value")
    assert started.returncode == 0
    assert all(event["data"]["tag"] == "beta" for event in fire_events(started))
    run_cli(tmp_path, "manage_deps", "--action", "add", "--id", "2", "--depends-on", "1")
    run_cli(tmp_path, "manage_deps", "--action", "remove", "--id", "2", "--depends-on", "1")
    meta_file = Path(two["meta_file"])
    meta_file.write_text(meta_file.read_text(encoding="utf-8").replace("dependencies: []", "dependencies: [2]"), encoding="utf-8")
    assert run_cli(tmp_path, "analyze_deps", "--action", "fix")["fixed_count"] == 1
    run_cli(tmp_path, "renumber_task", "--id", "2", "--to", "4")
    run_cli(tmp_path, "delete_task", "--id", "4")
    for script, args in [("list_tasks", []), ("next_task", []), ("resolve_task", ["--id", "1"]), ("analyze_deps", ["--action", "validate"]), ("analyze_deps", ["--action", "graph"])]:
        assert run_cli(tmp_path, script, *args, "--tag", "master")["tag"] == "master"
    assert run_cli(tmp_path, "manage_tag", "--action", "list")["current_tag"] == "beta"
    assert Path(master["meta_file"]).read_bytes() == master_before
    assert run_cli(tmp_path, "list_tasks")["tasks"][0]["workspace"] == "opaque-value"


def test_empty_store_still_initializes_master(tmp_path: Path) -> None:
    (tmp_path / ".maxa/tasks").mkdir(parents=True)
    assert create_task(tmp_path, "First")["tag"] == "master"
