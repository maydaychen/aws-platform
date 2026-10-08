import subprocess
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "build-universal.sh"


class BuildArgumentTests(unittest.TestCase):
    def test_help_documents_architecture_and_version_without_building(self):
        result = subprocess.run([str(SCRIPT), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("universal|arm64|x86_64", result.stdout)
        self.assertIn("--version", result.stdout)
        self.assertIn("--build-number", result.stdout)

    def test_invalid_arguments_stop_before_build_or_directory_creation(self):
        for arguments in (
            ["--architecture", "intel"], ["--architecture"],
            ["--version", "0.2"], ["--version", "0.2.0</string>"],
            ["--build-number", "0"], ["--build-number", "1.2"],
            ["--output-dir"], ["--unknown"],
        ):
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(SCRIPT), *arguments], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn("Building", result.stdout)


if __name__ == "__main__":
    unittest.main()
