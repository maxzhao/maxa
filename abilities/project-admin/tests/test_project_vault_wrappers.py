"""Subprocess wrapper tests; fake external CLI, isolated HOME, real Git topology."""
from __future__ import annotations
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "primary"
        self.root.mkdir()
        self.git("init", "-b", "baseline")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "--allow-empty", "-m", "fixture")
        self.linked = self.base / "linked"
        self.git("worktree", "add", "-b", "feature", str(self.linked))
        for root in (self.root, self.linked):
            v = root / ".maxa"
            v.mkdir()
            (v / "_meta.yaml").write_text('name: fixture\nschema_version: 1\n')
            for zone in ("attachments", "canvases"):
                (v / zone).mkdir()
        self.log = self.base / "calls"
        self.bin = self.base / "bin"; self.bin.mkdir()
        cli = self.bin / "obsidian"
        cli.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$CLI_LOG"
if [[ "$1" == vaults ]]; then printf 'fixture\\t%s\\n' "$CLI_TARGET"; exit 0; fi
if [[ "$1" != vault=fixture ]]; then echo 'FOREIGN DEFAULT'; exit 91; fi
if [[ "$2" == vault && "$3" == info=path ]]; then printf '%s\\n' "$CLI_TARGET"; exit 0; fi
if [[ "${CLI_FAIL:-}" == 1 ]]; then exit 92; fi
case "$2" in
  links|backlinks) echo 'index.md' ;;
  unresolved) echo 'No unresolved links found.' ;;
  orphans) : ;;
  tags) echo 'test' ;;
  *) exit 93 ;;
esac
''')
        cli.chmod(0o755)
        # bash -lc executable discovery may reset PATH; use BASH_ENV in this
        # isolated process to keep the fake CLI authoritative in child shells.
        shell_env = self.base / "shell-env"
        shell_env.write_text(f'export PATH="{self.bin}:$PATH"\n')
        self.env = {**os.environ, "HOME": str(self.base / "home"), "BASH_ENV": str(shell_env),
                    "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "CLI_LOG": str(self.log), "CLI_TARGET": str(self.root / ".maxa")}
        Path(self.env["HOME"]).mkdir()

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)

    def run_script(self, name, root, *args, **env):
        return subprocess.run(["bash", str(SCRIPTS / name), *args], cwd=root,
                              env={**self.env, **env}, text=True, capture_output=True, timeout=45)

    def test_graph_linked_rejects_without_cli_and_primary_is_explicit(self):
        bad = self.run_script("graph_neighbors.sh", self.linked, "Note")
        self.assertNotEqual(bad.returncode, 0, bad.stdout + bad.stderr)
        self.assertFalse(self.log.exists())
        good = self.run_script("graph_neighbors.sh", self.root / ".maxa", "Note")
        self.assertEqual(good.returncode, 0, good.stdout + good.stderr)
        calls = self.log.read_text().splitlines()
        self.assertEqual(calls, ["vault=fixture vault info=path", "vault=fixture links file=Note",
                                 "vault=fixture vault info=path", "vault=fixture backlinks file=Note"])
        fail = self.run_script("graph_neighbors.sh", self.root, "Note", CLI_FAIL="1")
        self.assertNotEqual(fail.returncode, 0)

    def test_health_linked_and_quick_are_file_only(self):
        linked = self.run_script("vault_health.sh", self.linked)
        self.assertEqual(linked.returncode, 0, linked.stdout + linked.stderr)
        self.assertIn("file-only (linked Worktree policy)", linked.stdout)
        self.assertFalse(self.log.exists())
        quick = self.run_script("vault_health.sh", self.root, "--quick")
        self.assertEqual(quick.returncode, 0, quick.stdout + quick.stderr)
        self.assertIn("file-only (--quick)", quick.stdout)
        self.assertFalse(self.log.exists())

    def test_health_live_failure_is_not_healthy_or_default_fallback(self):
        fail = self.run_script("vault_health.sh", self.root, CLI_FAIL="1")
        self.assertNotEqual(fail.returncode, 0, fail.stdout + fail.stderr)
        self.assertNotIn("PASS", fail.stdout)
        calls = self.log.read_text().splitlines()
        self.assertTrue(all(c == "vaults verbose" or c.startswith("vault=fixture ") for c in calls), calls)
        self.assertIn("vault=fixture tags", calls)
        good = self.run_script("vault_health.sh", self.root)
        self.assertEqual(good.returncode, 0, good.stdout + good.stderr)
        self.assertIn("file and verified live graph", good.stdout)

    def test_explicit_vault_symlink_never_redirects_to_primary(self):
        import shutil
        shutil.rmtree(self.linked / ".maxa")
        (self.linked / ".maxa").symlink_to(self.root / ".maxa")
        for name, extra in [("graph_neighbors.sh", ["Note"]), ("vault_health.sh", []),
                            ("vault_health.sh", ["--quick"])]:
            for target in (str(self.linked / ".maxa"), str(self.linked / ".maxa") + "/"):
                result = self.run_script(name, self.linked, "--project-root", target, *extra)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(self.log.exists())
                self.assertNotIn("PASS", result.stdout)

    def test_wrong_live_target_blocks_requested_graph(self):
        result = self.run_script("graph_neighbors.sh", self.root, "Note", CLI_TARGET=str(self.linked / ".maxa"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text().splitlines(), ["vault=fixture vault info=path"])


if __name__ == "__main__":
    unittest.main()
