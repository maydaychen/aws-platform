"""Offline checks for distribution safety gates; no signing or Apple requests."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("distribution", Path(__file__).parents[1] / "package-distribution.py")
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)


class DistributionTests(unittest.TestCase):
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
        for exit_code, status in [(0, "Accepted"), (1, "Invalid"), (0, "In Progress"), (1, "Accepted")]:
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
