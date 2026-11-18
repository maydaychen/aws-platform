#!/usr/bin/env python3
"""Offline tests for structural anonymity release verification."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "anonymous_release_check",
    Path(__file__).resolve().parents[1] / "anonymous_release_check.py",
)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class AnonymousReleaseTests(unittest.TestCase):
    def make_bundle(self, root):
        app = root / "AWSPlatform.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Frameworks").mkdir()
        (app / "Contents/Resources/Licenses").mkdir(parents=True)
        (app / "Contents/MacOS/AWSPlatform").write_bytes(b"mock-exec")
        (app / "Contents/Frameworks/libswiftMock.dylib").write_bytes(b"mock-dylib")
        (app / "Contents/Resources/Licenses/LICENSE").write_text("MIT")
        return app

    def fake_runner(self, codesign_output="Signature=adhoc\nTeamIdentifier=not set\n", archs="arm64 x86_64"):
        def run(*args):
            values = [str(a) for a in args]
            if values[:3] == ["xcrun", "lipo", "-archs"]:
                return 0, archs + "\n", ""
            if values[:2] == ["codesign", "-dvvv"]:
                return 0, "", codesign_output
            if values[:2] == ["codesign", "--verify"]:
                return 0, "", ""
            return 1, "", f"unexpected command: {values}"
        return run

    def test_valid_adhoc_universal_bundle_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_bundle(Path(directory))
            CHECK.verify_anonymous_app(app, run=self.fake_runner(), check_privacy=False)

    def test_authority_header_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_bundle(Path(directory))
            bad = "Authority=Developer ID Application: Example\nTeamIdentifier=not set\nSignature=adhoc\n"
            with self.assertRaisesRegex(RuntimeError, "Authority leaked"):
                CHECK.verify_anonymous_app(app, run=self.fake_runner(codesign_output=bad), check_privacy=False)

    def test_non_empty_team_identifier_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_bundle(Path(directory))
            bad = "Signature=adhoc\nTeamIdentifier=ABCDEFGHIJ\n"
            with self.assertRaisesRegex(RuntimeError, "TeamIdentifier leaked"):
                CHECK.verify_anonymous_app(app, run=self.fake_runner(codesign_output=bad), check_privacy=False)

    def test_embedded_provisioning_profile_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_bundle(Path(directory))
            (app / "Contents/embedded.mobileprovision").write_bytes(b"profile")
            with self.assertRaisesRegex(RuntimeError, "Forbidden metadata"):
                CHECK.verify_anonymous_app(app, run=self.fake_runner(), check_privacy=False)

    def test_sparkle_framework_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_bundle(Path(directory))
            (app / "Contents/Frameworks/Sparkle.framework").mkdir()
            with self.assertRaisesRegex(RuntimeError, "Sparkle.framework"):
                CHECK.verify_anonymous_app(app, run=self.fake_runner(), check_privacy=False)

    def test_single_architecture_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_bundle(Path(directory))
            with self.assertRaisesRegex(RuntimeError, "universal arm64\\+x86_64"):
                CHECK.verify_anonymous_app(app, run=self.fake_runner(archs="arm64"), check_privacy=False)

    def test_dmg_signature_authority_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            dmg = Path(directory) / "AWSPlatform.dmg"
            dmg.write_bytes(b"dmg")
            CHECK.verify_unsigned_dmg(dmg, run=self.fake_runner(codesign_output="code object is not signed at all\n"))
            with self.assertRaisesRegex(RuntimeError, "DMG container"):
                CHECK.verify_unsigned_dmg(dmg, run=self.fake_runner(codesign_output="Authority=Developer ID Application: Example\n"))


if __name__ == "__main__":
    unittest.main()
