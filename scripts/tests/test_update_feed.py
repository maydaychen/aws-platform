"""Offline update publication gates; no AWS, GitHub writes or Apple requests."""

import base64
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile


spec = importlib.util.spec_from_file_location("feed", Path(__file__).parents[1] / "generate-update-feed.py")
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)


class UpdateFeedTests(unittest.TestCase):
    def test_public_download_requires_exact_bytes_and_size(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "update.zip"
            archive.write_bytes(b"exact archive")
            for data in (b"exact archive", b"other archive", b"short", b"exact archive-extra"):
                with self.subTest(data=data), patch.object(feed.urllib.request, "build_opener") as build_opener:
                    build_opener.return_value.open.return_value = io.BytesIO(data)
                    if data == b"exact archive": feed.verify_public_download("https://example.com/update.zip", archive)
                    else:
                        with self.assertRaises(ValueError): feed.verify_public_download("https://example.com/update.zip", archive)

    def test_archive_paths_and_symlinks_cannot_escape_staging(self):
        for path, target in (("../outside", None), ("/absolute", None), ("Other.app/file", None),
                             ("AWSPlatform.app/link", "../../outside")):
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive = root / "update.zip"
                with zipfile.ZipFile(archive, "w") as output:
                    if target:
                        item = zipfile.ZipInfo(path)
                        item.external_attr = 0o120777 << 16
                        output.writestr(item, target)
                    else: output.writestr(path, "data")
                with patch.object(feed.distribution, "run") as command:
                    with self.assertRaises(ValueError): feed.verify_zip(archive, {}, "arm64", root)
                command.assert_not_called()

    def test_update_configuration_rejects_wrong_key_feed_or_automatic_install_defaults(self):
        valid = {"SUPublicEDKey": feed.updates.public_key(), "SUFeedURL": feed.updates.feed_url("arm64"),
                 "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False, "SUAllowsAutomaticUpdates": False}
        feed.updates.verify_config(valid, "arm64")
        for key, value in (("SUPublicEDKey", "wrong"), ("SUFeedURL", feed.updates.feed_url("x86_64")),
                           ("SUEnableAutomaticChecks", True), ("SUAutomaticallyUpdate", True), ("SUAllowsAutomaticUpdates", True)):
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                feed.updates.verify_config({**valid, key: value}, "arm64")

    def test_framework_must_include_every_helper_for_requested_architecture_and_system(self):
        for case in ("missing", "wrong-architecture", "newer-system"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                app = Path(directory)
                for name in feed.updates.BINARIES:
                    path = feed.updates.framework_path(app) / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b"mock executable")
                if case == "missing":
                    (feed.updates.framework_path(app) / feed.updates.BINARIES[-1]).unlink()
                def command(*args, capture=False):
                    if args[1] == "lipo": return "x86_64" if case == "wrong-architecture" else "arm64 x86_64"
                    return "minos 14.0\n" if case == "newer-system" else "minos 12.0\n"
                with self.assertRaises(RuntimeError): feed.updates.verify_framework(app, "arm64", command)

    def fixture(self, root, architecture="arm64"):
        directory = root / "distribution"
        directory.mkdir()
        archive = directory / f"AWSPlatform-0.3.1-{architecture}.zip"
        archive.write_bytes(b"verified final ZIP")
        (root / "updates").mkdir()
        channel = '<rss version="2.0"><channel><title>AWSPlatform</title></channel></rss>'
        (root / "updates" / f"appcast-{architecture}.xml").write_text(channel)
        manifest = {"architectures": [architecture], "version": "0.3.1", "build": "7",
                    "bundleID": "AWSPlatform", "minimumMacOS": "13.0", "teamID": "ABCDEFGHIJ",
                    "appNotarization": {"status": "Accepted"},
                    "sha256": {archive.name: feed.distribution.sha256(archive)},
                    "sparkle": {"publicKey": feed.updates.public_key(), "feedURL": feed.updates.feed_url(architecture),
                                "length": archive.stat().st_size, "edSignature": base64.b64encode(bytes(64)).decode()}}
        (directory / "distribution.json").write_text(json.dumps(manifest))
        return directory, manifest, archive

    def test_both_architecture_feeds_bind_final_archive_and_signature(self):
        for architecture in ("arm64", "x86_64"):
            with self.subTest(architecture=architecture), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                package, manifest, archive = self.fixture(root, architecture)
                calls = []
                with patch.object(feed, "ROOT", root), \
                     patch.object(feed.updates, "verify_archive", side_effect=lambda *args: calls.append("signature")), \
                     patch.object(feed, "verify_zip", side_effect=lambda *args: calls.append("bundle")), \
                     patch.object(feed, "verify_public_download", side_effect=lambda *args: calls.append("public")) as public:
                    output = root / "candidate.xml"
                    self.assertEqual(feed.generate(package, output), architecture)
                self.assertEqual(calls, ["signature", "bundle", "public"])
                enclosure = ET.parse(output).find("channel/item/enclosure")
                self.assertIn(f"v0.3.1/{archive.name}", enclosure.attrib["url"])
                self.assertEqual(enclosure.attrib["length"], str(manifest["sparkle"]["length"]))
                self.assertEqual(enclosure.attrib[feed.field("edSignature")], manifest["sparkle"]["edSignature"])
                self.assertEqual(public.call_count, 1)

    def test_changed_zip_wrong_feed_key_and_unnotarized_bundle_never_replace_output(self):
        for case in ("changed", "feed", "key", "notarization", "universal", "version", "length"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                package, manifest, archive = self.fixture(root)
                if case == "changed": archive.write_bytes(b"modified final ZIP")
                if case == "feed": manifest["sparkle"]["feedURL"] = feed.updates.feed_url("x86_64")
                if case == "key": manifest["sparkle"]["publicKey"] = "other key"
                if case == "notarization": manifest["appNotarization"]["status"] = "Unknown"
                if case == "universal": manifest["architectures"] = ["arm64", "x86_64"]
                if case == "version": manifest["version"] = "../0.3.1"
                if case == "length": manifest["sparkle"]["length"] += 1
                (package / "distribution.json").write_text(json.dumps(manifest))
                output = root / "candidate.xml"
                output.write_bytes(b"previous feed")
                with patch.object(feed, "ROOT", root), patch.object(feed, "verify_public_download") as public:
                    with self.assertRaises(ValueError): feed.generate(package, output)
                public.assert_not_called()
                self.assertEqual(output.read_bytes(), b"previous feed")

    def test_signature_failure_public_mismatch_and_downgrade_preserve_previous_feed(self):
        for case in ("signature", "public", "downgrade", "version-downgrade"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                package, _, _ = self.fixture(root)
                output = root / "candidate.xml"
                output.write_bytes(b"previous feed")
                if case == "downgrade":
                    (root / "updates/appcast-arm64.xml").write_text(
                        f'<rss xmlns:sparkle="{feed.SPARKLE}"><channel><item><sparkle:version>7</sparkle:version></item></channel></rss>')
                if case == "version-downgrade":
                    (root / "updates/appcast-arm64.xml").write_text(
                        f'<rss xmlns:sparkle="{feed.SPARKLE}"><channel><item><sparkle:version>6</sparkle:version>'
                        '<sparkle:shortVersionString>0.4.0</sparkle:shortVersionString></item></channel></rss>')
                with patch.object(feed, "ROOT", root), patch.object(feed, "verify_zip"), \
                     patch.object(feed.updates, "verify_archive", side_effect=ValueError("bad signature") if case == "signature" else None), \
                     patch.object(feed, "verify_public_download", side_effect=ValueError("bad download") if case == "public" else None):
                    with self.assertRaises(ValueError): feed.generate(package, output)
                self.assertEqual(output.read_bytes(), b"previous feed")

    def test_https_redirect_does_not_allow_downgrade(self):
        with self.assertRaises(ValueError):
            feed.HTTPSRedirects().redirect_request(None, None, 302, "", {}, "http://example.com/update.zip")

    def test_framework_signing_keeps_downloader_entitlements_and_signs_inside_out(self):
        calls = []
        feed.updates.sign_framework(Path("app"), "A" * 40, lambda *args: calls.append(args))
        self.assertTrue(str(calls[0][-1]).endswith("Installer.xpc"))
        self.assertTrue(str(calls[1][-1]).endswith("Downloader.xpc"))
        self.assertIn("--preserve-metadata=entitlements", calls[1])
        self.assertTrue(str(calls[-1][-1]).endswith("Sparkle.framework"))
        self.assertTrue(all("--deep" not in call and "runtime" in call and "--timestamp" in call for call in calls))
