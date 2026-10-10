from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/project_knowledge_vault.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("project_knowledge_vault", SCRIPT)
vault = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(vault)


class VaultRoutingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.target = root / "project/.maxa"
        self.target.mkdir(parents=True)
        self.alias = root / "project-alias"
        self.alias.symlink_to(self.target, target_is_directory=True)
        self.meta = {"name": "project", "project_root": self.target.parent, "vault_path": self.target,
                     "alias_path": self.alias, "config_path": root / "obsidian.json"}
        # These tests isolate CLI target verification; real Git ownership is covered separately.
        owner = patch.object(vault, "require_external_owner", return_value={"external_ops_allowed": True})
        owner.start()
        self.addCleanup(owner.stop)

    def result(self, stdout, code=0):
        return subprocess.CompletedProcess([], code, stdout, "")

    def test_target_precedes_command_and_preserves_arguments(self):
        args = ["links", "path=specs/index.md"]
        with patch.object(vault, "obsidian_exists", return_value=True), \
             patch.object(vault, "ensure_registered"), \
             patch.object(vault.subprocess, "run", side_effect=[
                 self.result(str(self.alias)), self.result("project-link\n")]) as run, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(vault.run_obsidian(self.meta, args), 0)
        self.assertEqual(run.call_args_list[0].args[0],
                         ["obsidian", "vault=project", "vault", "info=path"])
        self.assertEqual(run.call_args_list[1].args[0],
                         ["obsidian", "vault=project", *args])

    def test_bad_identity_blocks_requested_mutation(self):
        for output in ["/different-vault", "Vault not found.", ""]:
            with self.subTest(output=output), \
                 patch.object(vault, "obsidian_exists", return_value=True), \
                 patch.object(vault, "ensure_registered"), \
                 patch.object(vault.subprocess, "run", return_value=self.result(output)) as run:
                with self.assertRaises(vault.VaultError):
                    vault.run_obsidian(self.meta, ["property:set", "name=test", "value=x"])
                self.assertEqual(run.call_count, 1)

    def test_override_rejected_before_registration(self):
        with patch.object(vault, "obsidian_exists", return_value=True), \
             patch.object(vault, "ensure_registered") as register:
            with self.assertRaises(vault.VaultError):
                vault.run_obsidian(self.meta, ["links", "vault=other"])
            register.assert_not_called()

    def test_timeout_fails_closed(self):
        with patch.object(vault.subprocess, "run", side_effect=subprocess.TimeoutExpired("obsidian", 15)):
            with self.assertRaises(vault.VaultError):
                vault.verify_target(self.meta)

    def test_status_does_not_use_registration_or_gui_as_readiness(self):
        self.meta["config_path"].write_text(json.dumps({"vaults": {"id": {"path": str(self.alias)}}}))
        with patch.object(vault, "load_meta", return_value=self.meta), \
             patch.object(vault, "obsidian_known_vaults", return_value=[]), \
             patch.object(vault, "local_gui_available", return_value=True), \
             patch.object(vault, "obsidian_exists", return_value=True), \
             patch.object(vault, "verify_target", side_effect=vault.VaultError("Vault not found.")), \
             patch("sys.argv", [str(SCRIPT), "--project-root", self.temp.name, "status"]), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(vault.main(), 0)
        status = json.loads(output.getvalue())
        self.assertTrue(status["config_registered"])
        self.assertTrue(status["local_gui_available"])
        self.assertFalse(status["graph_ops_ready"])
        self.assertEqual(status["target_error"], "Vault not found.")


if __name__ == "__main__":
    unittest.main()
