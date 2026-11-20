#!/usr/bin/env python3
"""Offline tests for structural anonymity release verification."""

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile


sys.dont_write_bytecode = True
SCRIPTS_DIR = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "anonymous_release_check",
    SCRIPTS_DIR / "anonymous_release_check.py",
)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class AnonymousReleaseTests(unittest.TestCase):
    def make_bundle(self, root):
        app = root / "AWSPlatform.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Frameworks").mkdir()
        licenses = app / "Contents/Resources/Licenses"
        (licenses / "swift-runtime").mkdir(parents=True)
        (app / "Contents/MacOS/AWSPlatform").write_bytes(b"mock-exec")
        (app / "Contents/Frameworks/libswiftMock.dylib").write_bytes(b"mock-dylib")
        (licenses / "LICENSE").write_text("MIT\n", encoding="utf-8")
        (licenses / "swift-runtime/PROVENANCE.json").write_text(
            json.dumps({"embedded_libraries": [{"name": "libswiftMock.dylib"}]}) + "\n",
            encoding="utf-8",
        )
        files_map = {}
        for rel in ("LICENSE", "swift-runtime/PROVENANCE.json"):
            files_map[rel] = hashlib.sha256((licenses / rel).read_bytes()).hexdigest()
        (licenses / "manifest.json").write_text(
            json.dumps({
                "packages": [{"identity": "mock-pkg", "revision": "abc123"}],
                "files": files_map,
            }) + "\n",
            encoding="utf-8",
        )
        pkg_resolved = root / "Package.resolved"
        pkg_resolved.write_text(
            json.dumps({"pins": [{"identity": "mock-pkg", "state": {"revision": "abc123"}}]}) + "\n",
            encoding="utf-8",
        )
        return app, pkg_resolved

    def fake_runner(self, codesign_output="Signature=adhoc\nTeamIdentifier=not set\n", archs="arm64 x86_64",
                    slice_outputs=None):
        slice_outputs = slice_outputs or {}

        def run(*args):
            values = [str(a) for a in args]
            if values[:3] == ["xcrun", "lipo", "-archs"]:
                return 0, archs + "\n", ""
            if len(values) >= 4 and values[:2] == ["codesign", "--arch"]:
                arch = values[2]
                return 0, "", slice_outputs.get(arch, codesign_output)
            if values[:2] == ["codesign", "-dvvv"]:
                return 0, "", codesign_output
            if values[:2] == ["codesign", "--verify"]:
                return 0, "", ""
            return 1, "", f"unexpected command: {values}"
        return run

    def test_valid_adhoc_universal_bundle_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            app, pkg = self.make_bundle(Path(directory))
            CHECK.verify_anonymous_app(app, run=self.fake_runner(), check_privacy=False, package_resolved=pkg)

    def test_authority_header_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app, pkg = self.make_bundle(Path(directory))
            bad = "Authority=Developer ID Application: Example\nTeamIdentifier=not set\nSignature=adhoc\n"
            with self.assertRaisesRegex(RuntimeError, "Authority leaked"):
                CHECK.verify_anonymous_app(
                    app, run=self.fake_runner(codesign_output=bad), check_privacy=False, package_resolved=pkg
                )

    def test_single_slice_signature_leak_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app, pkg = self.make_bundle(Path(directory))
            leaked_x86 = "Authority=Developer ID Application: Example\nTeamIdentifier=ABCDEFGHIJ\n"
            with self.assertRaisesRegex(RuntimeError, "x86_64"):
                CHECK.verify_anonymous_app(
                    app,
                    run=self.fake_runner(slice_outputs={"x86_64": leaked_x86}),
                    check_privacy=False,
                    package_resolved=pkg,
                )

    def test_non_empty_team_identifier_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app, pkg = self.make_bundle(Path(directory))
            bad = "Signature=adhoc\nTeamIdentifier=ABCDEFGHIJ\n"
            with self.assertRaisesRegex(RuntimeError, "TeamIdentifier leaked"):
                CHECK.verify_anonymous_app(
                    app, run=self.fake_runner(codesign_output=bad), check_privacy=False, package_resolved=pkg
                )

    def test_embedded_provisioning_profile_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app, pkg = self.make_bundle(Path(directory))
            (app / "Contents/embedded.mobileprovision").write_bytes(b"profile")
            with self.assertRaisesRegex(RuntimeError, "Forbidden metadata"):
                CHECK.verify_anonymous_app(app, run=self.fake_runner(), check_privacy=False, package_resolved=pkg)

    def test_sparkle_framework_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app, pkg = self.make_bundle(Path(directory))
            (app / "Contents/Frameworks/Sparkle.framework").mkdir()
            with self.assertRaisesRegex(RuntimeError, "Sparkle.framework"):
                CHECK.verify_anonymous_app(app, run=self.fake_runner(), check_privacy=False, package_resolved=pkg)

    def test_single_architecture_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app, pkg = self.make_bundle(Path(directory))
            with self.assertRaisesRegex(RuntimeError, "universal arm64\\+x86_64"):
                CHECK.verify_anonymous_app(
                    app, run=self.fake_runner(archs="arm64"), check_privacy=False, package_resolved=pkg
                )

    def test_license_manifest_checksum_and_provenance_are_enforced(self):
        with tempfile.TemporaryDirectory() as directory:
            app, pkg = self.make_bundle(Path(directory))
            (app / "Contents/Resources/Licenses/LICENSE").write_text("tampered\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                CHECK.verify_anonymous_app(app, run=self.fake_runner(), check_privacy=False, package_resolved=pkg)

        with tempfile.TemporaryDirectory() as directory:
            app, pkg = self.make_bundle(Path(directory))
            prov_path = app / "Contents/Resources/Licenses/swift-runtime/PROVENANCE.json"
            prov_path.write_text(json.dumps({"embedded_libraries": []}) + "\n", encoding="utf-8")
            manifest_path = app / "Contents/Resources/Licenses/manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["files"]["swift-runtime/PROVENANCE.json"] = hashlib.sha256(prov_path.read_bytes()).hexdigest()
            manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "embedded_libraries mismatch"):
                CHECK.verify_anonymous_app(app, run=self.fake_runner(), check_privacy=False, package_resolved=pkg)

    def test_dmg_signature_authority_and_unexpected_signature_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            dmg = Path(directory) / "AWSPlatform.dmg"
            dmg.write_bytes(b"dmg")
            CHECK.verify_unsigned_dmg(dmg, run=self.fake_runner(codesign_output="code object is not signed at all\n"))
            with self.assertRaisesRegex(RuntimeError, "DMG container"):
                CHECK.verify_unsigned_dmg(
                    dmg, run=self.fake_runner(codesign_output="Authority=Developer ID Application: Example\n")
                )
            with self.assertRaisesRegex(RuntimeError, "Signature field"):
                CHECK.verify_unsigned_dmg(dmg, run=self.fake_runner(codesign_output="Signature=adhoc\n"))

    def test_build_anonymous_release_refuses_existing_output_directory(self):
        script = SCRIPTS_DIR / "build-anonymous-release.sh"
        with tempfile.TemporaryDirectory() as directory:
            existing = Path(directory) / "existing-release"
            existing.mkdir()
            sentinel = existing / "keep-me.txt"
            sentinel.write_text("important", encoding="utf-8")
            result = subprocess.run(
                [str(script), "--output-dir", str(existing)],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("refusing to overwrite", result.stderr)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "important")

    def test_zip_container_rejects_comments_and_unexpected_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            good_zip = root / "good.zip"
            with zipfile.ZipFile(good_zip, "w") as zf:
                zf.writestr("AWSPlatform.app/Contents/Info.plist", b"ok")
            CHECK.verify_zip_container(good_zip)

            comment_zip = root / "comment.zip"
            with zipfile.ZipFile(comment_zip, "w") as zf:
                zf.comment = b"build note"
                zf.writestr("AWSPlatform.app/Contents/Info.plist", b"ok")
            with self.assertRaisesRegex(RuntimeError, "archive comment"):
                CHECK.verify_zip_container(comment_zip)

            entry_comment_zip = root / "entry-comment.zip"
            with zipfile.ZipFile(entry_comment_zip, "w") as zf:
                info = zipfile.ZipInfo("AWSPlatform.app/Contents/Info.plist")
                info.comment = b"secret"
                zf.writestr(info, b"ok")
            with self.assertRaisesRegex(RuntimeError, "entry comment"):
                CHECK.verify_zip_container(entry_comment_zip)

            extra_zip = root / "extra.zip"
            with zipfile.ZipFile(extra_zip, "w") as zf:
                zf.writestr("AWSPlatform.app/Contents/Info.plist", b"ok")
                zf.writestr("__MACOSX/._Info.plist", b"bad")
            with self.assertRaisesRegex(RuntimeError, "Unexpected ZIP entry"):
                CHECK.verify_zip_container(extra_zip)

    def test_mounted_dmg_root_rejects_unexpected_entries_or_wrong_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            dmg_root = Path(directory) / "dmg"
            dmg_root.mkdir()
            (dmg_root / "AWSPlatform.app").mkdir()
            (dmg_root / "Applications").symlink_to("/Applications")
            (dmg_root / ".fseventsd").mkdir()
            (dmg_root / ".Trashes").mkdir()
            CHECK.verify_mounted_dmg_root(dmg_root)

            bad_sym_root = Path(directory) / "dmg-bad-link"
            bad_sym_root.mkdir()
            (bad_sym_root / "AWSPlatform.app").mkdir()
            (bad_sym_root / "Applications").symlink_to("/tmp")
            with self.assertRaisesRegex(RuntimeError, "symlink to /Applications"):
                CHECK.verify_mounted_dmg_root(bad_sym_root)

            extra_root = Path(directory) / "dmg-extra"
            extra_root.mkdir()
            (extra_root / "AWSPlatform.app").mkdir()
            (extra_root / "Applications").symlink_to("/Applications")
            (extra_root / ".DS_Store").write_bytes(b"bad")
            with self.assertRaisesRegex(RuntimeError, "Unexpected entries in DMG root"):
                CHECK.verify_mounted_dmg_root(extra_root)


if __name__ == "__main__":
    unittest.main()
