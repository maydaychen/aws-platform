"""Local-only source export tests; never access a remote repository."""

import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("public_source_export", ROOT / "scripts/export-public-source.py")
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class PublicSourceExportTests(unittest.TestCase):
    def setUp(self):
        temporary_root = ROOT / ".tmp/privacy-hardening/export-tests"
        temporary_root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=temporary_root)
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.source = self.base / "source"
        self.source.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Example Developer")
        self.git("config", "user.email", "100+example@users.noreply.github.com")
        self.write(".gitignore", ".tmp/\ndist/\n")
        self.write("LICENSE", "Example project license\n")
        self.write("README.md", "A public source fixture\n")
        self.write("scripts/run.sh", "#!/bin/sh\nexit 0\n")
        (self.source / "scripts/run.sh").chmod(0o755)
        self.commit()
        self.output = self.base / "published"

    def git(self, *arguments):
        result = subprocess.run(
            ["git", "-C", str(self.source), "-c", "core.hooksPath=/dev/null",
             "-c", "commit.gpgSign=false", *arguments],
            capture_output=True, text=True, check=True,
        )
        return result.stdout.strip()

    def write(self, name, text):
        path = self.source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def export(self, **options):
        return exporter.export_public_source(self.source, self.output, **options)

    def test_fixed_head_exports_all_files_and_modes_without_local_files_or_history(self):
        self.write(".tmp/private.txt", "untracked local state")
        self.write("dist/old.zip", "old deliverable")
        before = self.git("show-ref")
        commit = self.git("rev-parse", "HEAD")
        result = self.export()
        self.assertEqual(result["source_commit"], commit)
        self.assertEqual(result["file_count"], 4)
        self.assertFalse(result["includes_git_history"])
        self.assertEqual((self.output / "LICENSE").read_text(), "Example project license\n")
        self.assertEqual(stat.S_IMODE((self.output / "scripts/run.sh").stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE((self.output / "README.md").stat().st_mode), 0o644)
        self.assertFalse((self.output / ".git").exists())
        self.assertFalse((self.output / ".tmp").exists())
        self.assertFalse((self.output / "dist").exists())
        self.assertEqual(before, self.git("show-ref"))
        self.assertEqual(commit, self.git("rev-parse", "HEAD"))
        self.assertEqual(self.git("status", "--porcelain"), "")
        manifest = self.output.with_name(self.output.name + ".manifest.json")
        self.assertEqual(json.loads(manifest.read_text()), result)
        self.assertNotIn(str(self.source), manifest.read_text())

    def test_dirty_tracked_source_is_refused_before_creating_output(self):
        self.write("README.md", "pending edit")
        with self.assertRaises(RuntimeError):
            self.export()
        self.assertFalse(self.output.exists())
        self.assertEqual((self.source / "README.md").read_text(), "pending edit")

    def test_untracked_nonignored_source_is_refused(self):
        self.write("not-committed.swift", "pending source")
        with self.assertRaises(RuntimeError):
            self.export()
        self.assertFalse(self.output.exists())

    def test_ignored_output_inside_source_does_not_change_original_git_state(self):
        self.output = self.source / "dist/public-source"
        before = self.git("show-ref")
        result = self.export()
        self.assertEqual(result["file_count"], 4)
        self.assertEqual(self.git("show-ref"), before)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_existing_directory_and_manifest_are_not_overwritten(self):
        self.output.mkdir()
        (self.output / "keep.txt").write_text("existing")
        with self.assertRaises(RuntimeError):
            self.export()
        self.assertEqual((self.output / "keep.txt").read_text(), "existing")
        self.output = self.base / "another-output"
        manifest = self.output.with_name(self.output.name + ".manifest.json")
        manifest.write_text("existing manifest")
        with self.assertRaises(RuntimeError):
            self.export()
        self.assertEqual(manifest.read_text(), "existing manifest")

    def test_symlink_destination_and_git_metadata_destination_are_refused(self):
        self.output.symlink_to(self.base / "missing")
        with self.assertRaises(RuntimeError):
            self.export()
        self.assertTrue(self.output.is_symlink())
        self.output = self.source / ".git/published"
        before = self.git("show-ref")
        with self.assertRaises(RuntimeError):
            self.export()
        self.assertEqual(self.git("show-ref"), before)
        self.assertFalse(self.output.exists())

    def test_tracked_sensitive_paths_and_symlinks_are_refused(self):
        for name in (".env", ".aws/config", "server.pem", "dist/tracked.zip"):
            with self.subTest(name=name):
                self.write(name, "private fixture")
                self.git("add", "-f", name)
                self.git("commit", "-qm", "sensitive fixture")
                with self.assertRaises(RuntimeError):
                    self.export()
                self.assertFalse(self.output.exists())
                self.git("rm", "-q", name)
                self.git("commit", "-qm", "remove sensitive fixture")
        (self.source / "linked-license").symlink_to("LICENSE")
        self.commit()
        with self.assertRaises(RuntimeError):
            self.export()
        self.assertFalse(self.output.exists())

    def test_archive_traversal_links_and_unexpected_files_do_not_escape(self):
        for name, kind in (("../outside", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE),
                           (".git/config", tarfile.REGTYPE), ("README.md", tarfile.SYMTYPE),
                           ("unexpected", tarfile.REGTYPE)):
            with self.subTest(name=name, kind=kind):
                archive = io.BytesIO()
                with tarfile.open(fileobj=archive, mode="w") as stream:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    member.linkname = "../outside"
                    stream.addfile(member)
                archive.seek(0)
                with tempfile.TemporaryDirectory(dir=self.base) as stage:
                    with self.assertRaises(RuntimeError):
                        exporter.extract_archive(archive, Path(stage), {"README.md": (0o644, "unused")})
                self.assertFalse((self.base / "outside").exists())

    def test_privacy_failure_cleans_only_the_new_staging_directory(self):
        private_path = "/" + "Users" + "/private-person/work/file.swift"
        self.write("README.md", "Do not publish " + private_path + "\n")
        self.commit()
        before = self.git("show-ref")
        with self.assertRaises(RuntimeError):
            self.export()
        self.assertFalse(self.output.exists())
        self.assertFalse(self.output.with_name(self.output.name + ".manifest.json").exists())
        self.assertEqual(list(self.base.glob(".public-source-*")), [])
        self.assertTrue(self.source.is_dir())
        self.assertEqual(before, self.git("show-ref"))

    def test_private_deny_patterns_and_environment_are_honored(self):
        self.write("README.md", "A private-brand-marker appears here\n")
        self.commit()
        patterns = self.base / "patterns.json"
        patterns.write_text(json.dumps(["private-brand-marker"]))
        with patch.dict(os.environ, {"AWSPLATFORM_PRIVACY_PATTERNS_FILE": str(patterns)}):
            with self.assertRaises(RuntimeError):
                self.export()
        self.assertFalse(self.output.exists())
        with self.assertRaises(RuntimeError):
            self.export(patterns_file=patterns)
        self.assertFalse(self.output.exists())

    def test_head_change_during_privacy_scan_prevents_publication(self):
        original = exporter.privacy_scan.require_clean
        before = self.git("rev-parse", "HEAD")

        def changed(root, extra_patterns=()):
            original(root, extra_patterns=extra_patterns)
            self.write("README.md", "newer committed content\n")
            self.commit()

        with patch.object(exporter.privacy_scan, "require_clean", changed):
            with self.assertRaises(RuntimeError):
                self.export()
        self.assertNotEqual(before, self.git("rev-parse", "HEAD"))
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.base.glob(".public-source-*")), [])

    def test_uncommitted_edit_during_privacy_scan_prevents_publication(self):
        before = self.git("rev-parse", "HEAD")

        def changed(root, extra_patterns=()):
            self.write("README.md", "pending edit made during export\n")

        with patch.object(exporter.privacy_scan, "require_clean", changed):
            with self.assertRaises(RuntimeError):
                self.export()
        self.assertEqual(before, self.git("rev-parse", "HEAD"))
        self.assertEqual((self.source / "README.md").read_text(), "pending edit made during export\n")
        self.assertFalse(self.output.exists())

    def test_concurrently_created_destination_is_preserved_and_manifest_is_rolled_back(self):
        def create_destination(root, extra_patterns=()):
            self.output.mkdir()
            (self.output / "keep.txt").write_text("another task's output")

        with patch.object(exporter.privacy_scan, "require_clean", create_destination):
            with self.assertRaises(FileExistsError):
                self.export()
        self.assertEqual((self.output / "keep.txt").read_text(), "another task's output")
        self.assertFalse(self.output.with_name(self.output.name + ".manifest.json").exists())
        self.assertEqual(list(self.base.glob(".public-source-*")), [])

    def test_export_ignore_cannot_silently_omit_required_tracked_source(self):
        self.write(".gitattributes", "LICENSE export-ignore\n")
        self.commit()
        with self.assertRaises(RuntimeError):
            self.export()
        self.assertFalse(self.output.exists())

    def test_export_subst_cannot_silently_modify_committed_file_content(self):
        self.write(".gitattributes", "README.md export-subst\n")
        self.write("README.md", "$Format:%H$\n")
        self.commit()
        with self.assertRaises(RuntimeError):
            self.export()
        self.assertFalse(self.output.exists())

    def test_manifest_contains_no_private_root_and_cli_errors_do_not_echo_it(self):
        self.write("README.md", "pending content")
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/export-public-source.py"),
             "--source-dir", str(self.source), "--output-dir", str(self.output)],
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(str(self.source), result.stderr)
        self.assertIn("preserved", result.stderr)


if __name__ == "__main__":
    unittest.main()
