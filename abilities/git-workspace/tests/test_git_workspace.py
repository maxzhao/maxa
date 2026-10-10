import importlib.util
import json
import shutil
import sys
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "git_workspace.py"
spec = importlib.util.spec_from_file_location("git_workspace", SCRIPT)
gw = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gw
spec.loader.exec_module(gw)


class GitWorkspaceTests(unittest.TestCase):
    def setUp(self):
        if shutil.which("git") is None:
            self.skipTest("git unavailable")
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "repo"
        self.root.mkdir()
        self.git("init")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test User")
        (self.root / "README.md").write_text("hello\n", encoding="utf-8")
        (self.root / ".vscode").mkdir()
        (self.root / ".vscode" / "tracked.json").write_text("{}\n", encoding="utf-8")
        self.git("add", "README.md", ".vscode/tracked.json")
        self.git("commit", "-m", "initial")
        (self.root / ".maxa").mkdir()
        (self.root / ".env").write_text("SECRET=local\n", encoding="utf-8")
        (self.root / ".env.shared").write_text("SHARED=local\n", encoding="utf-8")
        (self.root / ".vscode" / "local.json").write_text("{}\n", encoding="utf-8")
        (self.root / ".maxa" / "workspaces.yml").write_text(
            f"""version: 1

workspaces:
  - name: main
    path: {self.root.as_posix()}
    type: main
    responsibility: Shared integration and governance

layout:
  root: "../{{repo_name}}-workspaces"
  name_template: "{{repo_name}}-{{workspace}}"
  branch_template: "workspace/{{workspace}}"

create:
  base: current_head

sync:
  on_create: true
  source: current_checkout
  only_untracked: true
  existing_target: skip_warn
  missing_source: warn
  include_patterns: |
    .env
    .vscode/
    missing.local
  link_patterns: |
    .env.shared
""",
            encoding="utf-8",
        )

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.root), *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def init_taskadmin(self):
        tasks = self.root / ".maxa/tasks"
        (tasks / "integration").mkdir(parents=True)
        (tasks / "state.yaml").write_text("currentTag: integration\nlastSwitched: 2026-09-24T00:00:00.000Z\n", encoding="utf-8")
        (tasks / "integration/_meta.yaml").write_text("description: Main checkout\ncreated: 2026-09-24T00:00:00.000Z\n", encoding="utf-8")
        self.git("add", ".maxa/tasks")
        self.git("commit", "-m", "initialize tasks")
        return tasks

    def test_create_configures_child_tag_without_changing_source_and_before_setup(self):
        tasks = self.init_taskadmin()
        config = self.root / ".maxa/workspaces.yml"
        config.write_text(config.read_text(encoding="utf-8").replace(
            "create:\n  base: current_head\n",
            "create:\n  base: current_head\n  after_commands:\n"
            "    - command: grep -q '^currentTag: feature-a$' .maxa/tasks/state.yaml\n"
            "      cwd: .\n",
        ), encoding="utf-8")

        result = gw.create_workspace(self.root, "feature-a")
        target = Path(result["path"])
        self.assertEqual(result["taskadmin_tag"], {"status": "configured", "tag": "feature-a", "workspace": "feature-a"})
        self.assertEqual(len(result["after_commands_completed"]), 1)
        self.assertIn("currentTag: feature-a", (target / ".maxa/tasks/state.yaml").read_text(encoding="utf-8"))
        self.assertIn("workspace: feature-a", (target / ".maxa/tasks/feature-a/_meta.yaml").read_text(encoding="utf-8"))
        self.assertIn("currentTag: integration", (tasks / "state.yaml").read_text(encoding="utf-8"))
        self.assertFalse((tasks / "feature-a").exists())

    def test_create_reuses_compatible_child_tag_and_rejects_conflicts(self):
        tasks = self.init_taskadmin()
        tag = tasks / "feature-a"
        tag.mkdir()
        (tag / "_meta.yaml").write_text("description: Existing tag\nworkspace: feature-a\n", encoding="utf-8")
        (tag / "task_001").mkdir()
        (tag / "task_001/plan.md").write_text("existing task\n", encoding="utf-8")
        self.git("add", ".maxa/tasks")
        self.git("commit", "-m", "existing child task")
        target = Path(gw.create_workspace(self.root, "feature-a")["path"])
        self.assertEqual((target / ".maxa/tasks/feature-a/task_001/plan.md").read_text(encoding="utf-8"), "existing task\n")
        self.assertIn("description: Existing tag", (target / ".maxa/tasks/feature-a/_meta.yaml").read_text(encoding="utf-8"))

        (tasks / "feature-b").mkdir()
        (tasks / "feature-b/_meta.yaml").write_text("workspace: elsewhere\n", encoding="utf-8")
        with self.assertRaisesRegex(gw.WorkspaceError, "not available"):
            gw.create_workspace(self.root, "feature-b")
        self.assertFalse((self.root.parent / "repo-workspaces/repo-feature-b").exists())
        (tasks / "feature-c/task_001").mkdir(parents=True)
        (tasks / "feature-c/_meta.yaml").write_text("description: Main tasks\n", encoding="utf-8")
        with self.assertRaisesRegex(gw.WorkspaceError, "not available"):
            gw.create_workspace(self.root, "feature-c")
        self.assertFalse((self.root.parent / "repo-workspaces/repo-feature-c").exists())
        with self.assertRaisesRegex(gw.WorkspaceError, "invalid TaskAdmin tag"):
            gw.create_workspace(self.root, "invalid.name")
        self.assertFalse((self.root.parent / "repo-workspaces/repo-invalid.name").exists())

    def test_create_retains_worktree_when_tag_setup_fails(self):
        self.init_taskadmin()
        with patch.object(gw, "configure_child_tag", side_effect=gw.WorkspaceError("tag setup failed")):
            with self.assertRaisesRegex(gw.WorkspaceError, "tag setup failed.*workspace retained"):
                gw.create_workspace(self.root, "feature-fail")
        self.assertTrue((self.root.parent / "repo-workspaces/repo-feature-fail").is_dir())

    def test_parse_config(self):
        cfg = gw.load_config(self.root)
        self.assertEqual(cfg.version, 1)
        self.assertEqual(cfg.sync_source, "current_checkout")
        self.assertEqual(cfg.existing_target, "skip_warn")
        self.assertEqual(cfg.include_patterns, [".env", ".vscode/", "missing.local"])
        self.assertEqual(cfg.link_patterns, [".env.shared"])
        self.assertEqual(cfg.after_commands, [])
        self.assertEqual(len(cfg.workspaces), 1)
        self.assertEqual(cfg.workspaces[0].name, "main")
        self.assertEqual(cfg.workspaces[0].kind, "main")
        self.assertEqual(cfg.workspaces[0].responsibility, "Shared integration and governance")

    def test_config_without_workspace_definitions_remains_valid(self):
        text = (self.root / ".maxa" / "workspaces.yml").read_text(encoding="utf-8")
        legacy = "version: 1\n\nlayout:\n" + text.split("layout:\n", 1)[1]
        cfg = gw.parse_config(legacy)
        self.assertEqual(cfg.workspaces, [])

    def test_detect_reports_explicit_main_definition(self):
        result = gw.detect_workspace(self.root)
        self.assertEqual(
            result["workspace_definition"],
            {
                "name": "main",
                "type": "main",
                "responsibility": "Shared integration and governance",
            },
        )

    def test_duplicate_workspace_paths_are_rejected(self):
        text = (self.root / ".maxa" / "workspaces.yml").read_text(encoding="utf-8")
        duplicate = text.replace(
            "\nlayout:\n",
            f"\n  - name: duplicate\n    path: {self.root.as_posix()}/.\n"
            "    type: child\n    responsibility: Duplicate identity\n\nlayout:\n",
        )
        with self.assertRaisesRegex(gw.WorkspaceError, "duplicate workspaces.path"):
            gw.parse_config(duplicate)

    def test_create_syncs_only_untracked_and_status_blocks_cleanup(self):
        result = gw.create_workspace(self.root, "feature-a")
        target = Path(result["path"])
        self.assertEqual(result["taskadmin_tag"]["status"], "skipped")
        self.assertTrue((target / ".env").exists())
        shared = target / ".env.shared"
        self.assertTrue(shared.is_symlink())
        self.assertEqual(shared.readlink(), self.root / ".env.shared")
        self.assertIn(".env.shared", result["linked"])
        self.assertTrue((target / ".vscode" / "local.json").exists())
        self.assertIn(".vscode/tracked.json", result["skipped_tracked"])
        self.assertIn("missing.local", result["missing_patterns"])

        status = gw.status_workspace(self.root, "feature-a")
        self.assertEqual(status["untracked_count"], 3)
        cleanup = gw.cleanup_workspace(self.root, "feature-a")
        self.assertEqual(cleanup["status"], "blocked")
        self.assertIn("workspace has untracked files", cleanup["blockers"])

    def test_create_refuses_missing_link_source_before_creating_worktree(self):
        (self.root / ".env.shared").unlink()

        with self.assertRaisesRegex(gw.WorkspaceError, "missing primary-worktree link source"):
            gw.create_workspace(self.root, "feature-missing")

        expected = self.root.parent / "repo-workspaces" / "repo-feature-missing"
        self.assertFalse(expected.exists())

    def test_create_runs_after_commands_serially_from_workspace_after_sync(self):
        config = self.root / ".maxa" / "workspaces.yml"
        text = config.read_text(encoding="utf-8").replace(
            "create:\n  base: current_head\n",
            "create:\n  base: current_head\n  after_commands:\n"
            "    - command: test -L .env.shared\n"
            "      cwd: .\n"
            "    - command: printf 'first\\n' > .workspace-setup.log\n"
            "      cwd: .\n"
            "    - command: printf 'second\\n' >> workspace-setup.log\n"
            "      cwd: .vscode\n",
        )
        config.write_text(text, encoding="utf-8")

        result = gw.create_workspace(self.root, "feature-setup")
        target = Path(result["path"])

        self.assertEqual(
            result["after_commands_completed"],
            [
                {"command": "test -L .env.shared", "cwd": "."},
                {"command": "printf 'first\\n' > .workspace-setup.log", "cwd": "."},
                {"command": "printf 'second\\n' >> workspace-setup.log", "cwd": ".vscode"},
            ],
        )
        self.assertEqual((target / ".workspace-setup.log").read_text(encoding="utf-8"), "first\n")
        self.assertEqual((target / ".vscode" / "workspace-setup.log").read_text(encoding="utf-8"), "second\n")

    def test_create_retains_workspace_when_after_command_fails(self):
        config = self.root / ".maxa" / "workspaces.yml"
        text = config.read_text(encoding="utf-8").replace(
            "create:\n  base: current_head\n",
            "create:\n  base: current_head\n  after_commands:\n    - command: exit 7\n      cwd: .\n",
        )
        config.write_text(text, encoding="utf-8")

        with self.assertRaisesRegex(gw.WorkspaceError, "exit 7.*workspace retained"):
            gw.create_workspace(self.root, "feature-setup-fail")

        expected = self.root.parent / "repo-workspaces" / "repo-feature-setup-fail"
        self.assertTrue(expected.exists())
        self.assertTrue((expected / ".env.shared").is_symlink())

    def test_create_rejects_after_command_cwd_outside_workspace(self):
        config = self.root / ".maxa" / "workspaces.yml"
        text = config.read_text(encoding="utf-8").replace(
            "create:\n  base: current_head\n",
            "create:\n  base: current_head\n  after_commands:\n    - command: true\n      cwd: ../\n",
        )
        config.write_text(text, encoding="utf-8")

        with self.assertRaisesRegex(gw.WorkspaceError, "cwd escapes workspace"):
            gw.create_workspace(self.root, "feature-cwd-escape")

    def test_sync_skips_existing_link_target_without_overwrite(self):
        target = Path(gw.create_workspace(self.root, "feature-existing")["path"])
        shared = target / ".env.shared"
        shared.unlink()
        shared.write_text("WORKSPACE=local\n", encoding="utf-8")

        result = gw.sync_workspace(self.root, "feature-existing")

        self.assertFalse(shared.is_symlink())
        self.assertEqual(shared.read_text(encoding="utf-8"), "WORKSPACE=local\n")
        self.assertIn(".env.shared", result["skipped_existing"])

    def test_check_workspace_reports_wrong_checkout(self):
        gw.create_workspace(self.root, "feature-b")
        check = gw.check_workspace(self.root, "feature-b")
        self.assertEqual(check["status"], "blocked")
        self.assertFalse(check["matches"])
        self.assertIn("expected_path", check)

    def test_linked_worktree_uses_primary_root_for_layout(self):
        first = gw.create_workspace(self.root, "feature-c")
        linked_root = Path(first["path"])
        linked_config = linked_root / ".maxa" / "workspaces.yml"
        linked_config.parent.mkdir(parents=True, exist_ok=True)
        linked_config.write_text(
            (self.root / ".maxa" / "workspaces.yml").read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        cfg = gw.load_config(linked_root)
        second_path = gw.workspace_path(linked_root, cfg, "feature-d")
        expected = self.root.parent / "repo-workspaces" / "repo-feature-d"
        self.assertEqual(second_path, expected.resolve())

    def test_detect_reports_explicit_child_definition(self):
        first = gw.create_workspace(self.root, "feature-context")
        linked_root = Path(first["path"])
        config_text = (self.root / ".maxa" / "workspaces.yml").read_text(encoding="utf-8").replace(
            "\nlayout:\n",
            f"\n  - name: feature-context\n    path: {linked_root.as_posix()}\n"
            "    type: child\n    responsibility: Implement feature context\n\nlayout:\n",
        )
        linked_config = linked_root / ".maxa" / "workspaces.yml"
        linked_config.parent.mkdir(parents=True, exist_ok=True)
        linked_config.write_text(config_text, encoding="utf-8")

        result = gw.detect_workspace(linked_root)
        self.assertEqual(
            result["workspace_definition"],
            {
                "name": "feature-context",
                "type": "child",
                "responsibility": "Implement feature context",
            },
        )

    def test_task_binding_resolution(self):
        tag_root = self.root / ".maxa" / "tasks" / "alpha"
        first = tag_root / "task_001"
        second = tag_root / "task_002"
        first.mkdir(parents=True)
        second.mkdir(parents=True)
        (tag_root / "_meta.yaml").write_text("description: alpha\nworkspace: tag-ws\n", encoding="utf-8")
        (first / "_meta.yaml").write_text(
            "name: First\nstatus: pending\npriority: high\ndependencies: []\nworkspace: task-ws\n",
            encoding="utf-8",
        )
        (second / "_meta.yaml").write_text(
            "name: Second\nstatus: pending\npriority: medium\ndependencies: []\n",
            encoding="utf-8",
        )

        task = gw.task_binding(self.root, "alpha", "1")
        fallback = gw.task_binding(self.root, "alpha", "2")
        self.assertEqual(task["task_id"], 1)
        self.assertEqual(task["workspace"], "task-ws")
        self.assertEqual(task["source"], "task")
        self.assertEqual(fallback["workspace"], "tag-ws")
        self.assertEqual(fallback["source"], "tag")
        self.assertNotIn("parent_workspace", task)
        with self.assertRaisesRegex(gw.WorkspaceError, "expected a positive integer"):
            gw.task_binding(self.root, "alpha", "1.1")
        with self.assertRaisesRegex(gw.WorkspaceError, "invalid TaskAdmin tag"):
            gw.task_binding(self.root, "../escape", "1")


if __name__ == "__main__":
    unittest.main()
