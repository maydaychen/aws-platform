#!/usr/bin/env python3
"""Behavior checks for the distribution license collector (no network)."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("collect_licenses", Path(__file__).parents[1] / "collect-licenses.py")
COLLECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COLLECTOR)


class LicenseCollectorTests(unittest.TestCase):
    def test_only_complete_leading_legal_comments_are_retained(self):
        source = "/* edit history */\n/* Copyright Example\n * Redistribution is allowed. */\n\nint secret = 42;\n/* Copyright later */"
        self.assertEqual(COLLECTOR.leading_notices(source),
                         "/* Copyright Example\n * Redistribution is allowed. */")

    def test_cpp_notice_and_swift_headers_are_preserved(self):
        source = "// Copyright Example\n// Licensed under MIT\n\nimport Foundation\n"
        self.assertEqual(COLLECTOR.leading_notices(source),
                         "// Copyright Example\n// Licensed under MIT\n")

    def test_license_names_exclude_service_code_and_private_keys(self):
        for name in ("LICENSE", "LICENSE.txt", "COPYING", "NOTICE.txt", "LICENSE-APACHE"):
            self.assertIsNotNone(COLLECTOR.LICENSE_NAME.fullmatch(name))
        for name in ("LicenseManager_api.swift", "private.key", "certificate.pem"):
            self.assertIsNone(COLLECTOR.LICENSE_NAME.fullmatch(name))

    def test_revision_mismatch_fails_before_collecting(self):
        pin = {"identity": "example", "state": {"revision": "expected"}}
        with patch.object(COLLECTOR, "command", return_value="other"):
            with self.assertRaisesRegex(ValueError, "does not match"):
                COLLECTOR.collect_package(pin, Path(".tmp"))

    def test_missing_root_license_fails(self):
        pin = {"identity": "example", "state": {"revision": "expected"}}
        with patch.object(COLLECTOR, "command", side_effect=["expected", "", "Sources/vendor/LICENSE\0"]):
            with self.assertRaisesRegex(ValueError, "Missing root license"):
                COLLECTOR.collect_package(pin, Path(".tmp"))

    def test_dirty_dependency_fails(self):
        pin = {"identity": "example", "state": {"revision": "expected"}}
        with patch.object(COLLECTOR, "command", side_effect=["expected", " M LICENSE"]):
            with self.assertRaisesRegex(ValueError, "modified tracked files"):
                COLLECTOR.collect_package(pin, Path(".tmp"))

    def test_existing_output_is_not_overwritten(self):
        parent = COLLECTOR.ROOT / ".tmp/distribution"
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as temp:
            output = Path(temp)
            original = output / "keep.txt"
            original.write_text("existing")
            with self.assertRaisesRegex(ValueError, "new or empty"):
                COLLECTOR.collect(COLLECTOR.ROOT, output)
            self.assertEqual(original.read_text(), "existing")

    def test_symlink_source_is_rejected(self):
        parent = COLLECTOR.ROOT / ".tmp/distribution"
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as temp:
            root = Path(temp)
            (root / "real").write_text("license")
            (root / "LICENSE").symlink_to("real")
            with self.assertRaisesRegex(ValueError, "regular file"):
                COLLECTOR.checked_file(root, "LICENSE")


if __name__ == "__main__":
    unittest.main()
