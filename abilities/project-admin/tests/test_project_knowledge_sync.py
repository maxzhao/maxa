from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "project_knowledge_sync.py"
sys.path.insert(0, str(SCRIPT_PATH.parent))
spec = importlib.util.spec_from_file_location("project_knowledge_sync", SCRIPT_PATH)
sync = importlib.util.module_from_spec(spec)
assert spec and spec.loader
sys.modules["project_knowledge_sync"] = sync
spec.loader.exec_module(sync)


class StignoreTests(unittest.TestCase):
    def test_create_local_include_and_shared_rules(self) -> None:
        vault = Path(tempfile.mkdtemp(prefix="project-admin-stignore-"))
        local_changed, shared_changed = sync.ensure_stignore(vault)

        self.assertTrue(local_changed)
        self.assertTrue(shared_changed)
        self.assertEqual((vault / ".stignore").read_text(), "#include .stignore-shared\n")
        shared = (vault / ".stignore-shared").read_text()
        self.assertIn("/mcp.json\n", shared)
        self.assertIn("(?d)/knowledge\n", shared)
        self.assertIn("(?d)/abilities\n", shared)
        self.assertIn("(?d)/abilities/**\n", shared)
        self.assertNotIn("(?d)/skills\n", shared)

    def test_migrate_legacy_local_rules_without_loss(self) -> None:
        vault = Path(tempfile.mkdtemp(prefix="project-admin-stignore-"))
        legacy = "# custom\n/custom-local\n(?d)/history\n(?d)/history/**\n"
        (vault / ".stignore").write_text(legacy)

        sync.ensure_stignore(vault)

        self.assertEqual((vault / ".stignore").read_text(), "#include .stignore-shared\n")
        shared = (vault / ".stignore-shared").read_text()
        self.assertIn("/custom-local\n", shared)
        self.assertIn("(?d)/history/**\n", shared)
        self.assertIn("(?d)/knowledge/**\n", shared)

    def test_existing_shared_rules_gain_mcp_ignore_without_loss(self) -> None:
        vault = Path(tempfile.mkdtemp(prefix="project-admin-stignore-"))
        (vault / ".stignore").write_text("#include .stignore-shared\n")
        (vault / ".stignore-shared").write_text("# custom\n/custom-local\n")
        self.assertEqual(sync.ensure_stignore(vault), (False, True))
        shared = (vault / ".stignore-shared").read_text()
        self.assertIn("/custom-local\n", shared)
        self.assertIn("/mcp.json\n", shared)

    def test_existing_shared_rules_are_idempotent(self) -> None:
        vault = Path(tempfile.mkdtemp(prefix="project-admin-stignore-"))
        sync.ensure_stignore(vault)
        self.assertEqual(sync.ensure_stignore(vault), (False, False))


if __name__ == "__main__":
    unittest.main()
