"""Offline staged-source and binary privacy checks; fixtures contain no real identity."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).parents[1] / "privacy_scan.py"
spec = importlib.util.spec_from_file_location("privacy_scan", SCRIPT)
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)
HOME_PREFIX = "/" + "Users" + "/"
PRIVATE_HOME = HOME_PREFIX + "fixture-person" + "/workspace/main.c"
PRIVATE_EMAIL = "fixture-owner" + "@" + "fixture-company" + ".com"


class PrivacyScanTests(unittest.TestCase):
    def write(self, root, name, content):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content if isinstance(content, bytes) else content.encode())
        return path

    def test_private_home_paths_in_regular_files_and_binary_strings_fail_without_value_in_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(root, "Contents/MacOS/app", b"\x01\xff\0" + PRIVATE_HOME.encode() + b"\0")
            self.write(root, "source.c", "/" + "home/fixture-person/workspace/main.c")
            findings = privacy.scan_tree(root)
            self.assertEqual({item.rule for item in findings}, {"private-home-path"})
            self.assertEqual(len(findings), 2)
            with self.assertRaises(RuntimeError) as caught:
                privacy.require_clean(root)
            self.assertNotIn("fixture-person", str(caught.exception))
            self.assertNotIn(str(root), str(caught.exception))

    def test_placeholder_home_paths_and_reserved_example_email_domains_are_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(root, "examples.md", "\n".join([
                HOME_PREFIX + "username/project", HOME_PREFIX + "Shared/public",
                "user@example.com", "user@sub.example.net", "user@example.org",
                "user@company.test", "user@company.example", "user@company.invalid",
                "123+nickname@users.noreply.github.com",
            ]))
            self.assertEqual(privacy.scan_tree(root), [])
            self.assertIsNone(privacy.require_clean(root))

    def test_real_email_is_rejected_in_text_and_binary_without_broad_domain_exemptions(self):
        for value in (PRIVATE_EMAIL, "user@" + "sub.users.noreply.github.com",
                      "user@" + "notexample.com", "user@" + "example.com.evil"):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.write(root, "message.txt", value)
                self.assertEqual(privacy.scan_tree(root)[0].rule, "non-example-email")

    def test_versions_retina_filenames_and_placeholder_url_userinfo_are_not_emails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(root, "fixtures.txt", "\n".join([
                "@vendor/tool" + "@" + "0.4.0",
                "icon_512x512" + "@" + "2x.png",
                "picture" + "@" + "3x.webp",
                "https://user" + "@" + "fixture-provider.com/version.txt",
            ]))
            self.assertEqual(privacy.scan_tree(root), [])
            # These exclusions do not allow a normal mailbox at another real domain.
            self.write(root, "mailbox.txt", "owner" + "@" + "retina-provider.com")
            self.assertEqual(privacy.scan_tree(root), [privacy.Finding("mailbox.txt", "non-example-email")])

    def test_short_random_binary_tokens_do_not_hide_real_binary_mailboxes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(root, "icon.png", b"\x89PNG\r\n\x1a\n\xff\xffr" + b"@" + b"x.y\xfe\xff")
            self.assertEqual(privacy.scan_tree(root), [])
            self.write(root, "app", b"\xff\0" + PRIVATE_EMAIL.encode() + b"\0\xfe")
            self.assertEqual(privacy.scan_tree(root), [privacy.Finding("app", "non-example-email")])

    def test_project_license_copies_only_exempt_attribution_mailboxes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(root, "scripts/licenses/vendor-license.txt", PRIVATE_EMAIL)
            self.assertEqual(privacy.scan_tree(root), [])
            self.write(root, "scripts/licenses/vendor-license.txt", PRIVATE_EMAIL + "\n" + PRIVATE_HOME)
            self.assertEqual({item.rule for item in privacy.scan_tree(root)}, {"private-home-path"})
            self.assertIn("private-pattern", {item.rule for item in privacy.scan_tree(root, [PRIVATE_EMAIL])})
            self.write(root, "scripts/licenses/source.json", PRIVATE_EMAIL)
            self.assertIn("non-example-email", {item.rule for item in privacy.scan_tree(root)})

    def test_exact_pinned_assembly_attribution_is_preserved_without_allowing_other_mailboxes(self):
        address = "appro" + "@" + "openssl.org"
        marker = "CRYPTOGAMS by <"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = marker + address + ">"
            self.write(root, "app", b"\xff\0" + payload.encode() + b"\0")
            self.assertEqual(privacy.scan_tree(root), [])
            self.write(root, "utf16", payload.encode("utf-16-le"))
            self.assertEqual(privacy.scan_tree(root), [])
            self.write(root, "ghash", ("GHASH for ARMv8, derived from ARMv4 version by <"
                                        + address + ">").encode())
            self.assertEqual(privacy.scan_tree(root), [])
            self.assertIn("private-pattern", {item.rule for item in privacy.scan_tree(root, [address])})
            self.write(root, "home", payload + "\n" + PRIVATE_HOME)
            self.assertIn("private-home-path", {item.rule for item in privacy.scan_tree(root)})
            self.write(root, "mixed", payload + "\n" + PRIVATE_EMAIL)
            self.assertIn("non-example-email", {item.rule for item in privacy.scan_tree(root)})
            self.write(root, "mixed-utf16", (payload + "\n" + PRIVATE_EMAIL).encode("utf-16-be"))
            self.assertIn(privacy.Finding("mixed-utf16", "non-example-email"), privacy.scan_tree(root))
        for value in (address, marker + address, marker.lower() + address + ">",
                      marker + PRIVATE_EMAIL + ">", marker + "other" + "@" + "openssl.org" + ">"):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.write(root, "app", b"\0" + value.encode() + b"\0")
                self.assertEqual(privacy.scan_tree(root), [privacy.Finding("app", "non-example-email")])

    def test_third_party_license_emails_are_preserved_but_private_paths_and_patterns_still_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(root, "LICENSE.txt", PRIVATE_EMAIL)
            self.write(root, "Contents/Resources/Licenses/vendor/attribution", PRIVATE_EMAIL)
            self.assertEqual(privacy.scan_tree(root), [])
            self.write(root, "NOTICE", PRIVATE_HOME + "\n" + "Hidden" + " Organization")
            rules = {item.rule for item in privacy.scan_tree(root, ["Hidden" + " Organization"])}
            self.assertEqual(rules, {"private-home-path", "private-pattern"})
            self.write(root, "license-unrelated.md", PRIVATE_EMAIL)
            self.assertIn("non-example-email", {item.rule for item in privacy.scan_tree(root)})

    def test_utf16_strings_at_both_binary_offsets_and_endian_encodings_are_scanned(self):
        for encoding in ("utf-16-le", "utf-16-be"):
            for offset in (b"", b"\xff"):
                with self.subTest(encoding=encoding, offset=offset), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    payload = PRIVATE_HOME + "\n" + PRIVATE_EMAIL + "\n" + "私有" + "组织"
                    self.write(root, "binary", offset + payload.encode(encoding))
                    rules = {item.rule for item in privacy.scan_tree(root, ["私有" + "组织"])}
                    self.assertEqual(rules, {"private-home-path", "non-example-email", "private-pattern"})

    def test_rules_and_literal_patterns_cross_chunk_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            literal = "Private" + " Token"
            self.write(root, "binary", b"\0" * 4090 + (PRIVATE_HOME + "\n" + PRIVATE_EMAIL
                                                     + "\n" + literal).encode())
            with patch.object(privacy, "CHUNK_SIZE", 4096):
                rules = {item.rule for item in privacy.scan_tree(root, [literal])}
            self.assertEqual(rules, {"private-home-path", "non-example-email", "private-pattern"})

    def test_example_email_split_before_last_domain_character_does_not_false_positive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(root, "text", "person@example.com ")
            with patch.object(privacy, "CHUNK_SIZE", len("person@" + "example.co")):
                self.assertEqual(privacy.scan_tree(root), [])

    def test_internal_framework_links_are_allowed_and_target_is_scanned(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = self.write(root, "Example.framework/Versions/A/Example", "safe")
            (target.parents[1] / "Current").symlink_to("A", target_is_directory=True)
            (target.parents[2] / "Example").symlink_to("Versions/Current/Example")
            self.assertEqual(privacy.scan_tree(root), [])
            target.write_text(PRIVATE_EMAIL)
            self.assertIn("non-example-email", {item.rule for item in privacy.scan_tree(root)})

    def test_external_or_broken_links_and_special_files_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "scan"
            root.mkdir()
            outside = self.write(base, "outside", "private")
            (root / "external").symlink_to(outside)
            (root / "broken").symlink_to(root / "absent")
            os.mkfifo(root / "pipe")
            findings = privacy.scan_tree(root)
            self.assertEqual({item.rule for item in findings},
                             {"external-symlink", "unreadable-file", "special-file"})

    def test_unreadable_file_and_directory_are_reported_without_raw_os_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(root, "private", "safe")
            with patch.object(privacy.os, "open", side_effect=PermissionError(PRIVATE_HOME)):
                self.assertEqual(privacy.scan_tree(root), [privacy.Finding("private", "unreadable-file")])
            with patch.object(privacy.os, "scandir", side_effect=PermissionError(PRIVATE_HOME)):
                self.assertEqual(privacy.scan_tree(root), [privacy.Finding(".", "unreadable-directory")])
            self.assertEqual(privacy.scan_tree(root / "absent"), [privacy.Finding(".", "missing-directory")])

    def test_load_patterns_uses_cli_file_before_environment_and_reports_invalid_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = self.write(root, "first.json", json.dumps(["first"] ))
            second = self.write(root, "second.json", json.dumps(["second"]))
            with patch.dict(os.environ, {privacy.PATTERNS_ENV: str(first)}):
                self.assertEqual(privacy.load_patterns(), ("first",))
                self.assertEqual(privacy.load_patterns(second), ("second",))
            for value in ("broken", "{}", '[""]', '[1]', '"text"'):
                second.write_text(value)
                with self.subTest(value=value), self.assertRaises(RuntimeError) as caught:
                    privacy.load_patterns(second)
                self.assertNotIn(value, str(caught.exception))
                self.assertNotIn(str(second), str(caught.exception))
            with patch.dict(os.environ, {}, clear=True):
                self.assertEqual(privacy.load_patterns(), ())

    def test_pattern_configuration_rejects_special_files_and_oversized_or_invalid_unicode_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pipe = root / "pipe"
            os.mkfifo(pipe)
            with self.assertRaises(RuntimeError):
                privacy.load_patterns(pipe)
            config = self.write(root, "patterns.json", "x" * (privacy.MAX_PATTERN_FILE_BYTES + 1))
            with self.assertRaises(RuntimeError):
                privacy.load_patterns(config)
            config.write_text('["\\ud800"]')
            with self.assertRaises(RuntimeError):
                privacy.load_patterns(config)

    def test_private_literal_is_case_insensitive_and_findings_do_not_reveal_values_in_file_names(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            literal = "Private" + " Person"
            self.write(root, literal + ".txt", literal.swapcase())
            findings = privacy.scan_tree(root, [literal])
            self.assertEqual(findings, [privacy.Finding("[private].txt", "private-pattern")])
            self.assertNotIn(literal, str(findings))

    def test_cli_clean_failure_and_configuration_errors_have_distinct_exit_codes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            clean = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True)
            self.assertEqual(clean.returncode, 0)
            self.write(root, "app", PRIVATE_EMAIL)
            failed = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True)
            self.assertEqual(failed.returncode, 1)
            self.assertNotIn(PRIVATE_EMAIL, failed.stdout + failed.stderr)
            bad = subprocess.run([sys.executable, str(SCRIPT), str(root), "--patterns-file", str(root / "absent")],
                                 capture_output=True, text=True)
            self.assertEqual(bad.returncode, 2)
            self.assertNotIn(str(root), bad.stdout + bad.stderr)

    def test_large_non_email_run_does_not_cause_unbounded_regex_backtracking(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(root, "binary", b"x" * 131072 + b"@\0")
            result = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True,
                                    text=True, timeout=5)
            self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
