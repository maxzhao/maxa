from __future__ import annotations

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import project_vault_ownership as ownership
import project_knowledge_vault as vault
import project_knowledge_sync as sync


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.primary = self.base / "primary space 中文"
        self.primary.mkdir()
        self.git(self.primary, "init", "-b", "baseline")
        self.git(self.primary, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "--allow-empty", "-m", "fixture")
        self.linked = self.base / "main"
        self.git(self.primary, "worktree", "add", "-b", "main", str(self.linked))
        self.home = self.base / "home"
        self.home.mkdir()
        self.addCleanup(patch.stopall)
        patch.object(Path, "home", return_value=self.home).start()
        for root in (self.primary, self.linked):
            (root / ".maxa").mkdir()
            (root / ".maxa/_meta.yaml").write_text(
                'name: "smx-knowledge::fixture::001"\nschema_version: 1\n'
                'syncthing_folder_id: smx-knowledge-fixture-001\n')

    def git(self, root, *args):
        return subprocess.run(["git", "-C", str(root), *args], capture_output=True,
                              text=True, check=True).stdout.strip()

    def test_primary_linked_subproject_and_symlink(self):
        for root, kind in [(self.primary, "primary"), (self.linked, "linked")]:
            nested = root / "nested"; nested.mkdir()
            alias = self.base / (kind + "-alias"); alias.symlink_to(nested)
            for path in (root, nested, alias):
                with self.subTest(path=path):
                    got = ownership.resolve_ownership(path)
                    self.assertEqual(got["checkout_kind"], kind)
                    self.assertEqual(got["external_ops_allowed"], kind == "primary")
                    self.assertEqual(got["primary_checkout_path"], str(self.primary))
        detached = self.base / "detached"
        self.git(self.primary, "worktree", "add", "--detach", str(detached))
        self.assertEqual(ownership.resolve_ownership(detached)["checkout_kind"], "linked")

    def test_newline_path_and_separate_git_directory(self):
        root = self.base / 'quote"line\n'
        root.mkdir()
        self.git(root, "init", "--separate-git-dir", str(self.base / "admin-dir"))
        self.assertEqual(ownership.resolve_ownership(root)["checkout_kind"], "primary")
        with patch.object(ownership, "_git_value", wraps=ownership._git_value):
            self.assertTrue(ownership.resolve_ownership(root)["external_ops_allowed"])

    def test_standalone_broken_missing_git_and_environment_override(self):
        plain = self.base / "plain"; plain.mkdir()
        self.assertEqual(ownership.resolve_ownership(plain)["checkout_kind"], "standalone")
        (plain / ".git").write_text("gitdir: /nonexistent-fixture-git\n")
        self.assertEqual(ownership.resolve_ownership(plain)["checkout_kind"], "unresolved")
        with patch.object(ownership, "_git", side_effect=FileNotFoundError("git unavailable")):
            self.assertEqual(ownership.resolve_ownership(self.primary)["checkout_kind"], "unresolved")
        with patch.dict(os.environ, {"GIT_DIR": str(self.primary / ".git"), "GIT_WORK_TREE": str(self.primary)}):
            self.assertEqual(ownership.resolve_ownership(self.linked)["checkout_kind"], "linked")

    def test_bare_origin_linked_checkout_has_no_primary(self):
        bare = self.base / "bare.git"
        self.git(self.primary, "clone", "--bare", str(self.primary), str(bare))
        checkout = self.base / "bare-worktree"
        self.git(bare, "worktree", "add", str(checkout))
        self.assertEqual(ownership.resolve_ownership(bare)["checkout_kind"], "unresolved")
        self.assertEqual(ownership.resolve_ownership(checkout)["checkout_kind"], "unresolved")

    def test_missing_primary_and_malformed_topology_fail_closed(self):
        # Preserve linked administrative data while removing the primary worktree.
        common = self.base / "common-git"
        shutil.move(str(self.primary / ".git"), str(common))
        (self.linked / ".git").write_text(f"gitdir: {common / 'worktrees/main'}\n")
        shutil.rmtree(self.primary)
        got = ownership.resolve_ownership(self.linked)
        self.assertFalse(got["external_ops_allowed"])
        self.assertEqual(got["checkout_kind"], "unresolved")

    def test_linked_direct_commands_reject_before_all_effects(self):
        meta = vault.load_meta(self.linked)
        with patch.object(vault, "obsidian_exists") as exists:
            with self.assertRaises(ownership.OwnershipError):
                vault.run_obsidian(meta, ["links", "path=index.md"])
            exists.assert_not_called()
        for module, commands in [(vault, ("ensure",)), (sync, ("ensure", "scan"))]:
            for command in commands:
                with self.subTest(module=module.__name__, command=command), \
                     patch.object(module.sys, "argv", ["script", "--project-root", str(self.linked), command]), \
                     contextlib.redirect_stderr(io.StringIO()) as err:
                    self.assertEqual(module.main(), 2)
                    self.assertIn("linked", err.getvalue())
        self.assertFalse(meta["alias_root"].exists())
        self.assertFalse(meta["config_path"].exists())
        self.assertEqual(sorted(p.name for p in (self.linked / ".maxa").iterdir()), ["_meta.yaml"])

    def test_linked_status_never_contacts_services(self):
        with patch.object(vault, "obsidian_known_vaults", side_effect=AssertionError("external")), \
             patch.object(vault, "verify_target", side_effect=AssertionError("external")), \
             patch.object(vault.sys, "argv", ["script", "--project-root", str(self.linked), "status"]), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(vault.main(), 0)
        got = json.loads(output.getvalue())
        self.assertEqual(got["checkout_kind"], "linked")
        self.assertIsNone(got["config_registered"])
        self.assertFalse(got["graph_ops_ready"])
        with patch.object(sync, "wsl_status", side_effect=AssertionError("external")), \
             patch.object(sync, "windows_status", side_effect=AssertionError("external")):
            for side in ("wsl", "windows"):
                meta = sync.load_meta(self.linked); meta["manager_side"] = side
                got = sync.status(meta)
                self.assertEqual(got["checkout_kind"], "linked")
                self.assertIsNone(got["folder_registered"])
                with self.assertRaises(ownership.OwnershipError): sync.ensure_folder(meta)
                with self.assertRaises(ownership.OwnershipError): sync.trigger_scan(meta)

    def test_primary_setup_idempotent_and_linked_cannot_steal(self):
        meta = vault.load_meta(self.primary)
        vault.ensure_registered(meta)
        before = meta["config_path"].read_bytes()
        stamp = meta["config_path"].stat().st_mtime_ns
        vault.ensure_registered(meta)
        self.assertEqual(meta["config_path"].stat().st_mtime_ns, stamp)
        self.assertEqual(meta["config_path"].read_bytes(), before)
        with self.assertRaises(ownership.OwnershipError): vault.ensure_registered(vault.load_meta(self.linked))
        self.assertEqual(meta["alias_path"].resolve(), meta["vault_path"])
        self.assertEqual(meta["config_path"].read_bytes(), before)

    def test_conflicting_dangling_alias_and_name_collision_not_changed(self):
        meta = vault.load_meta(self.primary)
        meta["alias_root"].mkdir(parents=True)
        for target in (self.linked / ".maxa", self.base / "missing"):
            meta["alias_path"].symlink_to(target)
            with self.assertRaises(vault.VaultError): vault.ensure_registered(meta)
            self.assertEqual(meta["alias_path"].readlink(), target)
            self.assertFalse(meta["config_path"].exists())
            meta["alias_path"].unlink()
        other = self.base / meta["name"]; other.mkdir()
        meta["config_path"].parent.mkdir(parents=True)
        content = json.dumps({"vaults": {"other": {"path": str(other)}}})
        meta["config_path"].write_text(content)
        with self.assertRaises(vault.VaultError): vault.ensure_registered(meta)
        self.assertFalse(meta["alias_path"].exists())
        self.assertEqual(meta["config_path"].read_text(), content)

    def test_registered_missing_alias_requires_explicit_repair(self):
        meta = vault.load_meta(self.primary)
        meta["config_path"].parent.mkdir(parents=True)
        before = json.dumps({"vaults": {"id": {"path": str(meta["alias_path"])}}})
        meta["config_path"].write_text(before)
        with self.assertRaises(vault.VaultError): vault.ensure_registered(meta)
        self.assertFalse(meta["alias_root"].exists())
        self.assertEqual(meta["config_path"].read_text(), before)

    def test_exec_missing_registration_does_not_setup(self):
        meta = vault.load_meta(self.primary)
        with patch.object(vault, "obsidian_exists", return_value=True), \
             patch.object(vault, "verify_target", side_effect=vault.VaultError("missing registration")), \
             patch.object(vault, "ensure_registered", side_effect=AssertionError("implicit setup")):
            with self.assertRaises(vault.VaultError): vault.run_obsidian(meta, ["links"])
        self.assertFalse(meta["alias_root"].exists())
        self.assertFalse(meta["config_path"].exists())

    def test_metadata_cannot_redirect_vault(self):
        meta_path = self.primary / ".maxa/_meta.yaml"
        with meta_path.open("a") as file:
            file.write(f'vault_root: "{self.linked / ".maxa"}"\n')
        for module in (vault, sync):
            with self.subTest(module=module.__name__):
                meta = module.load_meta(self.primary)
                self.assertEqual(meta["vault_path"], self.primary / ".maxa")
        shutil.rmtree(self.linked / ".maxa")
        (self.linked / ".maxa").symlink_to(self.primary / ".maxa")
        for module in (vault, sync):
            with self.subTest(module=module.__name__):
                with self.assertRaises(ownership.OwnershipError): module.load_meta(self.linked)

    def test_sync_cli_conflict_has_no_local_writes_on_both_platforms(self):
        for side in ("wsl", "windows"):
            meta = sync.load_meta(self.primary); meta["manager_side"] = side
            for foreign in (self.linked / ".maxa", self.primary / ".maxa/knowledge"):
                with self.subTest(side=side, foreign=foreign), \
                     patch.object(sync, "load_meta", return_value=meta), \
                     patch.object(sync, "wsl_list_folders", return_value=[meta["folder_id"]]), \
                     patch.object(sync, "wsl_folder_dump", return_value={"path": str(foreign)}), \
                     patch.object(sync, "windows_status", return_value={"service_active": True, "folder_registered": True, "path_matches": False}), \
                     patch.object(sync, "ensure_folder", side_effect=AssertionError("external write")), \
                     patch.object(sync.sys, "argv", ["script", "--project-root", str(self.primary), "ensure"]), \
                     contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(sync.main(), 2)
                self.assertEqual(sorted(p.name for p in (self.primary / ".maxa").iterdir()), ["_meta.yaml"])

    def test_conflict_preserves_existing_setup_bytes(self):
        directory = self.primary / ".maxa"
        for name in (".stignore", ".stignore-shared", ".stfolder"):
            (directory / name).write_bytes(b"user-owned fixture\n")
        before = {p.name: p.read_bytes() for p in directory.iterdir()}
        for side in ("windows", "wsl"):
            meta = sync.load_meta(self.primary); meta["manager_side"] = side
            with patch.object(sync, "load_meta", return_value=meta), \
                 patch.object(sync, "wsl_list_folders", return_value=[meta["folder_id"]]), \
                 patch.object(sync, "wsl_folder_dump", return_value={"path": str(self.linked / ".maxa")}), \
                 patch.object(sync, "windows_status", return_value={"service_active": True, "folder_registered": True, "path_matches": False}), \
                 patch.object(sync.sys, "argv", ["script", "--project-root", str(self.primary), "ensure"]), \
                 contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(sync.main(), 2)
            self.assertEqual({p.name: p.read_bytes() for p in directory.iterdir()}, before)

    def test_windows_dispatch_uses_one_physical_identity_check(self):
        meta = sync.load_meta(self.primary); meta["manager_side"] = "windows"
        with patch.object(sync, "windows_available", return_value=True), \
             patch.object(sync, "wsl_to_windows_path", return_value='C:\\fixture\\.maxa'), \
             patch.object(sync, "run_powershell_json", return_value={"changed": False}) as run:
            sync.windows_status(meta)
            sync.windows_ensure_folder(meta)
        for call in run.call_args_list:
            script = call.args[0]
            self.assertIn("Test-SameVaultDirectory", script)
            self.assertIn("GetFileInformationByHandle", script)
            self.assertNotIn("$legacy", script)
            self.assertNotIn("TrimEnd", script)

    def test_sync_legacy_or_foreign_path_is_conflict(self):
        meta = sync.load_meta(self.primary)
        for target in (self.primary / ".maxa/knowledge", self.linked / ".maxa"):
            with patch.object(sync, "wsl_list_folders", return_value=[meta["folder_id"]]), \
                 patch.object(sync, "wsl_folder_dump", return_value={"path": str(target)}), \
                 patch.object(sync, "wsl_ensure_folder_defaults", side_effect=AssertionError("write")):
                with self.assertRaises(sync.SyncError): sync.wsl_ensure_folder(meta)


if __name__ == "__main__":
    unittest.main()
