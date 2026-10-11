"""Authentication gates use disposable fixtures and never access Keychain."""

from contextlib import contextmanager
import importlib.util
import io
from pathlib import Path
import plistlib
import shutil
import stat
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

spec = importlib.util.spec_from_file_location("trusted_updates", Path(__file__).parents[1] / "update_support.py")
updates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updates)


class UpdateTrustTests(unittest.TestCase):
    def archive(self, root, path="bin/sign_update", data=b"offline fixture", mode=stat.S_IFREG | 0o755):
        archive = root / "Sparkle.zip"
        with zipfile.ZipFile(archive, "w") as output:
            entry = zipfile.ZipInfo(path)
            entry.external_attr = mode << 16
            output.writestr(entry, data)
        return archive

    def test_cached_or_downloaded_tampering_never_executes_key_helpers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.archive(root)
            destination = root / "artifact"
            destination.mkdir()
            @contextmanager
            def tampered_artifact():
                updates.extract_verified_archive(archive, destination)
                yield destination
            command = Mock()
            with patch.object(updates, "trusted_artifact", tampered_artifact):
                for operation in (updates.sign_archive, updates.sign_feed):
                    with self.assertRaises(RuntimeError): operation(root / "unused.zip", command)
            command.assert_not_called()
            self.assertEqual(list(destination.iterdir()), [])

    def test_verified_copy_keeps_executable_permissions_and_rejects_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.archive(root)
            digest = updates.digest(archive)
            destination = root / "artifact"
            destination.mkdir()
            with patch.object(updates, "SPARKLE_SHA256", digest):
                updates.extract_verified_archive(archive, destination)
                self.assertEqual((destination / "bin/sign_update").read_bytes(), b"offline fixture")
                self.assertEqual((destination / "bin/sign_update").stat().st_mode & 0o777, 0o500)
                archive.write_bytes(archive.read_bytes() + b"changed")
                with self.assertRaises(RuntimeError): updates.extract_verified_archive(archive, destination)

    def test_embed_prepares_only_copied_framework_for_resigning(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "artifact"
            source = artifact / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
            binary = source / "Versions/B/Sparkle"
            resource = source / "Versions/B/_CodeSignature/CodeResources"
            binary.parent.mkdir(parents=True)
            resource.parent.mkdir(parents=True)
            binary.write_bytes(b"verified executable")
            resource.write_bytes(b"verified signing resources")
            binary.chmod(0o500)
            resource.chmod(0o400)
            (source / "Versions/Current").symlink_to("B")
            (source / "Sparkle").symlink_to("Versions/Current/Sparkle")
            app = root / "App.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({}))
            @contextmanager
            def trusted():
                yield artifact
            def copy(*args):
                self.assertEqual(args[0], "ditto")
                shutil.copytree(args[1], args[2], symlinks=True)
            def sign(candidate, identity, run):
                copied = updates.framework_path(candidate)
                self.assertEqual(identity, "-")
                self.assertEqual((copied / "Versions/B/Sparkle").stat().st_mode & 0o777, 0o755)
                self.assertEqual((copied / "Versions/B/_CodeSignature/CodeResources").stat().st_mode & 0o777, 0o644)
                self.assertEqual((copied / "Sparkle").read_bytes(), binary.read_bytes())
                self.assertTrue((copied / "Sparkle").is_symlink())
                self.assertEqual(binary.stat().st_mode & 0o777, 0o500)
                self.assertEqual(resource.stat().st_mode & 0o777, 0o400)
            with patch.object(updates, "trusted_artifact", trusted), \
                 patch.object(updates, "verify_framework"), patch.object(updates, "sign_framework", side_effect=sign) as signer:
                updates.embed(app, "arm64", copy)
            signer.assert_called_once()

    def test_authenticated_archive_paths_types_and_links_remain_contained(self):
        for path, data, mode in [("../outside", b"x", stat.S_IFREG), ("/outside", b"x", stat.S_IFREG),
                                 ("bin/link", b"../../outside", stat.S_IFLNK), ("fifo", b"x", stat.S_IFIFO)]:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive = self.archive(root, path, data, mode)
                destination = root / "artifact"
                destination.mkdir()
                with patch.object(updates, "SPARKLE_SHA256", updates.digest(archive)), self.assertRaises(RuntimeError):
                    updates.extract_verified_archive(archive, destination)
                self.assertFalse((root / "outside").exists())

    def test_private_download_staging_is_cleaned_and_never_uses_swiftpm_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.archive(root)
            response = io.BytesIO(archive.read_bytes())
            response.geturl = lambda: "https://example.test/pinned.zip"
            with patch.object(updates, "ROOT", root), patch.object(updates, "verify_dependency"), \
                 patch.object(updates, "SPARKLE_SHA256", updates.digest(archive)), \
                 patch.object(updates.urllib.request, "urlopen", return_value=response):
                with updates.trusted_artifact() as artifact:
                    self.assertIn(".tmp/update-tools/verified-", str(artifact))
                    self.assertEqual(artifact.parent.stat().st_mode & 0o777, 0o700)
                    self.assertTrue((artifact / "bin/sign_update").is_file())
                self.assertFalse(artifact.exists())

    def test_dependency_revision_and_checksum_require_explicit_review(self):
        updates.verify_dependency()
        with patch.object(updates, "SPARKLE_REVISION", "different"), self.assertRaises(RuntimeError):
            updates.verify_dependency()

    def test_feed_signature_verifies_exact_prefix_and_rejects_missing_or_invalid_length(self):
        import base64
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            content = b"<rss><channel/></rss>\n"
            signature = base64.b64encode(bytes(64)).decode()
            block = f"<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {len(content)}\n-->\n".encode()
            for data, accepted in [(content + block, True), (content, False),
                                   (b"changed" + content + block, False), (content + block + b"extra", False)]:
                path.write_bytes(data)
                def verify(candidate, candidate_signature, run):
                    self.assertEqual(candidate.read_bytes(), content)
                    self.assertEqual(candidate_signature, signature)
                with patch.object(updates, "verify_archive", side_effect=verify) as verifier:
                    if accepted: updates.verify_feed(path, Mock())
                    else:
                        with self.assertRaises(ValueError): updates.verify_feed(path, Mock())
                        verifier.assert_not_called()
                self.assertEqual(list(Path(directory).iterdir()), [path])
