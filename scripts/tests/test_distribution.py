"""Offline checks for distribution safety gates; no signing or Apple requests."""

import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("distribution", Path(__file__).parents[1] / "package-distribution.py")
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)


class DistributionTests(unittest.TestCase):
    identity = "A" * 40
    team = "ABCDEFGHIJ"
    commit = "b" * 40

    def make_bundle(self, app, version="0.2.0", build="2"):
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Frameworks").mkdir()
        (app / "Contents/Resources").mkdir()
        (app / "Contents/MacOS/AWSPlatform").write_bytes(b"mock executable")
        (app / "Contents/Frameworks/libswiftMock.dylib").write_bytes(b"mock runtime")
        info = {"CFBundleShortVersionString": version, "CFBundleVersion": build,
                "CFBundleIdentifier": "AWSPlatform", "CFBundleExecutable": "AWSPlatform",
                "LSMinimumSystemVersion": "13.0"}
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))

    def fake_run(self, architecture, calls):
        def run(*args, capture=False):
            values = [str(arg) for arg in args]
            calls.append(values)
            if values[:2] == ["git", "status"]:
                return ""
            if values[:2] == ["git", "ls-files"]:
                return "\n".join(distribution.REQUIRED_INPUTS)
            if values[:2] == ["git", "rev-parse"]:
                return self.commit
            if values[0] == "security":
                return f'  1) {self.identity} "Developer ID Application: Example ({self.team})"'
            if values[0].endswith("build-universal.sh"):
                output = Path(values[values.index("--output-dir") + 1])
                self.make_bundle(output / "AWSPlatform.app")
            if values[:3] == ["xcrun", "lipo", "-archs"]:
                return " ".join(distribution.ARCHITECTURES[architecture])
            if values[:4] == ["ditto", "-c", "-k", "--keepParent"]:
                Path(values[-1]).write_bytes(b"mock ZIP")
            if values[:2] == ["hdiutil", "create"]:
                Path(values[-1]).write_bytes(b"mock DMG")
            return "" if capture else None
        return run

    def test_architecture_version_and_build_inputs_reject_invalid_values_before_commands(self):
        valid = [self.identity, self.team, "universal", "0.2.0", "2"]
        invalid = [(0, "short"), (1, "invalid"), (2, "arm64;command"), (2, "../arm64"),
                   (3, "../0.2.0"), (3, "0.2"), (3, "0.2.0-beta"), (3, "0.2.0.1"),
                   (4, "0"), (4, "-1"), (4, "2.0"), (4, "2/other")]
        for index, value in invalid:
            with self.subTest(index=index, value=value), patch.object(distribution, "run") as run:
                options = list(valid)
                options[index] = value
                with self.assertRaises(ValueError):
                    distribution.package(*options)
                run.assert_not_called()

    def test_cli_keeps_universal_default_and_forwards_explicit_release_options(self):
        required = ["package-distribution.py", "--identity", self.identity, "--team-id", self.team]
        with patch.object(distribution.sys, "argv", required), patch.object(distribution, "package") as package:
            distribution.main()
            package.assert_called_once_with(self.identity, self.team, "universal", "0.2.0", "2")
        explicit = required + ["--architecture", "x86_64", "--version", "0.3.1", "--build-number", "4"]
        with patch.object(distribution.sys, "argv", explicit), patch.object(distribution, "package") as package:
            distribution.main()
            package.assert_called_once_with(self.identity, self.team, "x86_64", "0.3.1", "4")

    def test_existing_release_or_broken_symlink_stops_before_build_and_signing(self):
        for existing_type in ("directory", "symlink"):
            with self.subTest(existing_type=existing_type), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                destination = root / "dist/AWSPlatform-0.2.0-arm64"
                destination.parent.mkdir()
                if existing_type == "directory":
                    destination.mkdir()
                else:
                    destination.symlink_to(root / "missing")
                with patch.object(distribution, "ROOT", root), patch.object(distribution, "run") as run:
                    with self.assertRaisesRegex(RuntimeError, "existing distribution"):
                        distribution.package(self.identity, self.team, "arm64")
                    run.assert_not_called()

    def test_publication_never_replaces_an_existing_empty_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output, destination = root / "output", root / "existing"
            output.mkdir()
            (output / "artifact.zip").write_bytes(b"new")
            destination.mkdir()
            with self.assertRaises(FileExistsError):
                distribution.publish_distribution(output, destination)
            self.assertEqual(list(destination.iterdir()), [])
            self.assertTrue((output / "artifact.zip").exists())

    def test_source_snapshot_covers_build_inputs_without_blocking_unrelated_agent_rules(self):
        calls = []
        with patch.object(distribution, "run", side_effect=self.fake_run("arm64", calls)):
            self.assertEqual(distribution.source_snapshot(), self.commit)
        checked = calls[0][calls[0].index("--") + 1:]
        for path in ("Sources", "Tests", "Package.swift", "Package.resolved", "scripts/build-universal.sh",
                     "scripts/package-distribution.py", "scripts/collect-licenses.py", "scripts/licenses"):
            self.assertIn(path, checked)
        self.assertNotIn("AGENTS.md", checked)

    def test_dirty_input_or_changed_commit_blocks_distribution(self):
        with patch.object(distribution, "run", return_value=" M scripts/build-universal.sh\n"):
            with self.assertRaisesRegex(RuntimeError, "Commit and verify"):
                distribution.source_snapshot()
        with patch.object(distribution, "run", side_effect=self.fake_run("arm64", [])):
            with self.assertRaisesRegex(RuntimeError, "Source commit changed"):
                distribution.source_snapshot("c" * 40)

    def test_bundle_must_match_version_and_build(self):
        for version, build in (("0.1.0", "2"), ("0.2.0", "1")):
            with self.subTest(version=version, build=build), tempfile.TemporaryDirectory() as directory:
                app = Path(directory) / "AWSPlatform.app"
                self.make_bundle(app, version, build)
                with patch.object(distribution, "run") as run:
                    with self.assertRaisesRegex(RuntimeError, "version or build number"):
                        distribution.verify_bundle(app, "arm64", "0.2.0", "2")
                    run.assert_not_called()

    def test_executable_and_embedded_library_must_have_exact_requested_architectures(self):
        for executable, library in (("x86_64", "arm64"), ("arm64", "arm64 x86_64"),
                                    ("arm64 arm64", "arm64"), ("arm64", "")):
            with self.subTest(executable=executable, library=library), tempfile.TemporaryDirectory() as directory:
                app = Path(directory) / "AWSPlatform.app"
                self.make_bundle(app)
                with patch.object(distribution, "run", side_effect=[executable, library]):
                    with self.assertRaisesRegex(RuntimeError, "Unexpected architectures"):
                        distribution.verify_bundle(app, "arm64", "0.2.0", "2")

    def test_each_architecture_is_forwarded_verified_and_recorded_in_manifest(self):
        for architecture in distribution.ARCHITECTURES:
            with self.subTest(architecture=architecture), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                calls = []
                with patch.object(distribution, "ROOT", root), \
                        patch.object(distribution, "run", side_effect=self.fake_run(architecture, calls)), \
                        patch.object(distribution, "verify_signature"), \
                        patch.object(distribution, "notarize", return_value={"status": "Accepted"}):
                    distribution.package(self.identity, self.team, architecture)
                stem = f"AWSPlatform-0.2.0-{architecture}"
                destination = root / "dist" / stem
                manifest = json.loads((destination / "distribution.json").read_text())
                self.assertEqual(manifest["architectures"], sorted(distribution.ARCHITECTURES[architecture]))
                self.assertEqual((manifest["version"], manifest["build"]), ("0.2.0", "2"))
                self.assertEqual(manifest["sourceCommit"], self.commit)
                self.assertEqual(set(manifest["sha256"]), {f"{stem}.zip", f"{stem}.dmg"})
                for filename, digest in manifest["sha256"].items():
                    self.assertEqual(distribution.sha256(destination / filename), digest)
                build = next(call for call in calls if call[0].endswith("build-universal.sh"))
                self.assertEqual(build[1:7], ["--architecture", architecture, "--version", "0.2.0", "--build-number", "2"])
                self.assertEqual(len([call for call in calls if call[:2] == ["git", "rev-parse"]]), 3)
                self.assertEqual(len([call for call in calls if call[:3] == ["xcrun", "lipo", "-archs"]]), 2)
                self.assertEqual(list((root / ".tmp/distribution").iterdir()), [])

    def test_unknown_notarization_retains_staging_and_never_publishes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = root / "dist/AWSPlatform-0.1.0-universal"
            old.mkdir(parents=True)
            (old / "previous.zip").write_bytes(b"previous release")
            with patch.object(distribution, "ROOT", root), \
                    patch.object(distribution, "run", side_effect=self.fake_run("arm64", [])), \
                    patch.object(distribution, "verify_signature"), \
                    patch.object(distribution, "notarize", side_effect=RuntimeError("Unknown notarization status")):
                with self.assertRaisesRegex(RuntimeError, "Unknown"):
                    distribution.package(self.identity, self.team, "arm64")
            stages = list((root / ".tmp/distribution").iterdir())
            self.assertEqual(len(stages), 1)
            self.assertTrue((stages[0] / "AWSPlatform-notarization.zip").exists())
            self.assertFalse((root / "dist/AWSPlatform-0.2.0-arm64").exists())
            self.assertEqual((old / "previous.zip").read_bytes(), b"previous release")

    def test_signature_requires_developer_id_team_timestamp_and_runtime(self):
        valid = "Authority=Developer ID Application: Example\nTeamIdentifier=ABCDEFGHIJ\nTimestamp=now\nflags=0x10000(runtime)"
        with patch.object(distribution, "run"):
            with patch.object(distribution, "signing_details", return_value=valid):
                distribution.verify_signature(Path("Example.app"), "ABCDEFGHIJ", runtime=True)
            for value in [valid.replace("ABCDEFGHIJ", "OTHERTEAM1"), valid.replace("Timestamp=", "Time="),
                          valid.replace("(runtime)", "(adhoc)"), valid.replace("Developer ID Application:", "Apple Development:")]:
                with self.subTest(signature=value), patch.object(distribution, "signing_details", return_value=value):
                    with self.assertRaises(RuntimeError):
                        distribution.verify_signature(Path("Example.app"), "ABCDEFGHIJ", runtime=True)

    def test_notarization_requires_successful_exit_and_accepted_readback(self):
        identifier = "00000000-0000-0000-0000-000000000001"
        for exit_code, status in [(0, "Accepted"), (1, "Invalid"), (0, "In Progress"),
                                  (0, "Unknown"), (1, "Accepted")]:
            with self.subTest(exit_code=exit_code, status=status), tempfile.TemporaryDirectory() as directory:
                response = json.dumps({"data": {"id": identifier, "attributes": {"status": status}}})
                completed = subprocess.CompletedProcess([], exit_code, stdout=response, stderr="private upload progress")
                with patch.object(distribution.subprocess, "run", return_value=completed), patch.object(distribution, "run", return_value=response):
                    if exit_code == 0 and status == "Accepted":
                        self.assertEqual(distribution.notarize(Path("Example.zip"), Path(directory), "app")["status"], "Accepted")
                    else:
                        with self.assertRaises(RuntimeError):
                            distribution.notarize(Path("Example.zip"), Path(directory), "app")
                evidence = (Path(directory) / "notary-app.json").read_text()
                self.assertIn(identifier, evidence)
                self.assertNotIn("private upload progress", evidence)

    def test_missing_submission_result_stops_without_recording_success(self):
        with tempfile.TemporaryDirectory() as directory:
            completed = subprocess.CompletedProcess([], 1, stdout="", stderr="private authentication failure")
            with patch.object(distribution.subprocess, "run", return_value=completed):
                with self.assertRaisesRegex(RuntimeError, "inspect Apple history"):
                    distribution.notarize(Path("Example.zip"), Path(directory), "app")
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
