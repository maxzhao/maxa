"""Run: uv run --project abilities/project-admin python -m unittest discover -s abilities/project-admin/tests -p test_vault_doc_sizes.py"""
from pathlib import Path
import importlib.util
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("vault_doc_sizes", Path(__file__).parents[1] / "scripts/vault_doc_sizes.py")
sizes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sizes)


class WeaveSizeTests(unittest.TestCase):
    def test_complete_utf8_boundaries_and_subtree(self):
        with tempfile.TemporaryDirectory() as directory:
            vault = Path(directory) / ".maxa"
            for rel, limit in [("weave/index.md", 2048), ("weave/topics/example.md", 6144), ("weave/concepts/example.md", 3072), ("weave/log.md", 6144)]:
                path = vault / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"x" * limit)
            self.assertEqual(sizes.build_rows(vault, 30000), [])
            for path in (vault / "weave").rglob("*.md"):
                with path.open("ab") as stream:
                    stream.write("中".encode("utf-8"))
            rows = sizes.build_rows(vault, 30000)
            self.assertEqual({r["limit_bytes"] for r in rows}, {2048, 3072, 6144})
            self.assertTrue(all(r["bytes"] == r["limit_bytes"] + 3 for r in rows))
            subtree = sizes.build_rows(vault / "weave", 30000)
            self.assertEqual({r["path"]: r["limit_bytes"] for r in subtree}, {r["path"][6:]: r["limit_bytes"] for r in rows})

    def test_ordinary_override_and_workspace_exclusion(self):
        with tempfile.TemporaryDirectory() as directory:
            vault = Path(directory)
            for rel in ["research/example.md", "tasks/example.md", "drafts/example.md", "attachments/example.md"]:
                path = vault / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"x" * 30001)
            rows = sizes.build_rows(vault, 30000)
            self.assertEqual([r["path"] for r in rows], ["research/example.md"])
            self.assertEqual(rows[0]["limit_bytes"], 30000)
            self.assertEqual(sizes.build_rows(vault, 40000), [])


if __name__ == "__main__":
    unittest.main()
