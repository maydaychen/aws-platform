"""Sparkle bundle embedding, configuration and inside-out signing."""

import argparse
import base64
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parent.parent
SPARKLE_VERSION = "2.10.0"
SPARKLE_REVISION = "eef1a539a373c1f1a320624b1130fc5de7b2e100"
# From the upstream Package.swift at SPARKLE_REVISION, reviewed with Package.resolved.
SPARKLE_SHA256 = "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
SPARKLE_URL = f"https://github.com/sparkle-project/Sparkle/releases/download/{SPARKLE_VERSION}/Sparkle-for-Swift-Package-Manager.zip"
FEED_PREFIX = "https://raw.githubusercontent.com/maydaychen/aws-platform/main/updates/appcast-"
KEY_ACCOUNT = "aws-platform-updates"
COMPONENTS = (
    "Versions/B/XPCServices/Installer.xpc",
    "Versions/B/XPCServices/Downloader.xpc",
    "Versions/B/Autoupdate",
    "Versions/B/Updater.app",
    ".",
)
BINARIES = (
    "Versions/B/Sparkle",
    "Versions/B/Autoupdate",
    "Versions/B/Updater.app/Contents/MacOS/Updater",
    "Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
    "Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
)


def verify_dependency():
    pins = json.loads((ROOT / "Package.resolved").read_text())["pins"]
    sparkle = next(pin for pin in pins if pin["identity"] == "sparkle")
    if sparkle["state"] != {"revision": SPARKLE_REVISION, "version": SPARKLE_VERSION}:
        raise RuntimeError("Review Sparkle checksum and revision before changing the pinned dependency")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def extract_verified_archive(archive, destination):
    # Verify the private copy, not a path into a mutable SwiftPM cache.
    if digest(archive) != SPARKLE_SHA256:
        raise RuntimeError("Sparkle archive checksum mismatch; refusing to copy or execute components")
    with zipfile.ZipFile(archive) as bundle:
        if sum(item.file_size for item in bundle.infolist()) > 512 * 1024 * 1024:
            raise RuntimeError("Unexpected Sparkle archive size")
        seen = set()
        for item in bundle.infolist():
            path = Path(item.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in item.filename or item.filename in seen:
                raise RuntimeError("Invalid Sparkle archive path")
            seen.add(item.filename)
            target = destination / path
            mode = item.external_attr >> 16
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.parent.resolve().is_relative_to(destination.resolve()):
                raise RuntimeError("Sparkle archive parent escapes staging")
            if stat.S_ISLNK(mode):
                link = bundle.read(item).decode("utf-8")
                if Path(link).is_absolute() or not (target.parent / link).resolve().is_relative_to(destination.resolve()):
                    raise RuntimeError("Sparkle archive link escapes staging")
                target.symlink_to(link)
            else:
                if stat.S_IFMT(mode) not in (0, stat.S_IFREG):
                    raise RuntimeError("Unsupported Sparkle archive entry")
                with bundle.open(item) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
                target.chmod(0o500 if mode & 0o111 else 0o400)


@contextmanager
def trusted_artifact():
    verify_dependency()
    temporary = ROOT / ".tmp/update-tools"
    temporary.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="verified-", dir=temporary) as directory:
        stage = Path(directory)
        stage.chmod(0o700)
        archive = stage / "Sparkle.zip"
        request = urllib.request.Request(SPARKLE_URL, headers={"User-Agent": "AWSPlatform-release"})
        with urllib.request.urlopen(request, timeout=60) as response, archive.open("xb") as output:
            if not response.geturl().startswith("https://"):
                raise RuntimeError("Sparkle download must remain HTTPS")
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > 80 * 1024 * 1024:
                    raise RuntimeError("Sparkle download exceeds the pinned package budget")
                output.write(chunk)
        artifact = stage / "artifact"
        artifact.mkdir(mode=0o700)
        extract_verified_archive(archive, artifact)
        yield artifact


def public_key():
    key = (ROOT / "updates/public-ed25519-key.txt").read_text().strip()
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError("Expected a 32-byte Ed25519 public key")
    return key


def feed_url(architecture):
    if architecture not in ("arm64", "x86_64", "universal"):
        raise ValueError("Invalid update architecture")
    return FEED_PREFIX + ("arm64" if architecture == "universal" else architecture) + ".xml"


def verify_config(info, architecture):
    if info.get("SUPublicEDKey") != public_key() or info.get("SUFeedURL") != feed_url(architecture):
        raise RuntimeError("Update public key or architecture feed does not match the source")
    for setting in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates"):
        if info.get(setting) is not False:
            raise RuntimeError("Automatic update defaults must require user opt-in and explicit installation")
    if info.get("SURequireSignedFeed") is not True or info.get("SUVerifyUpdateBeforeExtraction") is not True:
        raise RuntimeError("Signed feeds and archive verification before extraction are required")
    if info.get("SUSignedFeedFailureExpirationInterval") != 0:
        raise RuntimeError("Feed signing failures must not silently expire")


def framework_path(app):
    return app / "Contents/Frameworks/Sparkle.framework"


def verify_framework(app, architecture, run):
    framework = framework_path(app)
    expected = {"arm64", "x86_64"} if architecture == "universal" else {architecture}
    for name in BINARIES:
        binary = framework / name
        if not binary.is_file():
            raise RuntimeError(f"Missing Sparkle component: {name}")
        actual = run("xcrun", "lipo", "-archs", binary, capture=True).split()
        if not expected.issubset(actual) or not set(actual).issubset({"arm64", "x86_64"}):
            raise RuntimeError(f"Sparkle component does not support requested architecture: {name}")
        for target in expected:
            output = run("xcrun", "vtool", "-arch", target, "-show-build", binary, capture=True)
            versions = [line.split()[1] for line in output.splitlines() if line.strip().startswith("minos ")]
            if not versions or any(tuple(int(part) for part in version.split(".")) > (13, 0, 0) for version in versions):
                raise RuntimeError(f"Sparkle component requires newer than macOS 13: {name}")


def sign_framework(app, identity, run, verify=None):
    framework = framework_path(app)
    for name in COMPONENTS:
        target = framework / name
        options = ["--force", "--sign", identity]
        if identity != "-":
            options += ["--timestamp", "--options", "runtime"]
        if name.endswith("Downloader.xpc"):
            options += ["--preserve-metadata=entitlements"]
        run("codesign", *options, target)
        if verify is not None:
            verify(target)


def verify_archive(path, signature, run):
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Expected a 64-byte Ed25519 signature")
    run("swift", ROOT / "scripts/verify-update-signature.swift", public_key(), signature, path, capture=True)


def sign_archive(path, run):
    with trusted_artifact() as artifact:
        key = verify_signing_key(artifact, run)
        output = run(artifact / "bin/sign_update", "--account", KEY_ACCOUNT, path, capture=True)
    signature = re.search(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"', output)
    length = re.search(r'length="([0-9]+)"', output)
    if signature is None or length is None or int(length.group(1)) != path.stat().st_size:
        raise RuntimeError("Sparkle did not return a matching signed archive length")
    verify_archive(path, signature.group(1), run)
    return {"edSignature": signature.group(1), "length": path.stat().st_size, "publicKey": key}


def verify_signing_key(artifact, run):
    key = run(artifact / "bin/generate_keys", "--account", KEY_ACCOUNT, "-p", capture=True).strip()
    if key != public_key():
        raise RuntimeError("Keychain key differs from the application public key; refusing to rotate")
    return key


def verify_feed(path, run):
    data = path.read_bytes()
    block = re.search(rb'<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\n\Z', data)
    if block is None or int(block.group(2)) != block.start():
        raise ValueError("Missing or invalid Sparkle feed signature block")
    with tempfile.NamedTemporaryFile(dir=path.parent, suffix=".feed-content", delete=False) as content:
        content_path = Path(content.name)
        content.write(data[:block.start()])
    try:
        verify_archive(content_path, block.group(1).decode("ascii"), run)
    finally:
        content_path.unlink(missing_ok=True)


def sign_feed(path, run):
    with trusted_artifact() as artifact:
        verify_signing_key(artifact, run)
        run(artifact / "bin/sign_update", "--account", KEY_ACCOUNT, path, capture=True)
    verify_feed(path, run)


def embed(app, architecture, run):
    with trusted_artifact() as artifact:
        source = artifact / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
        run("ditto", source, framework_path(app))
    # Keep the authenticated source read-only; the app copy must allow re-signing.
    framework = framework_path(app)
    for entry in (framework, *framework.rglob("*")):
        if not entry.is_symlink():
            entry.chmod(0o755 if entry.is_dir() or entry.stat().st_mode & 0o111 else 0o644)
    path = app / "Contents/Info.plist"
    info = plistlib.loads(path.read_bytes())
    info.update(SUPublicEDKey=public_key(), SUFeedURL=feed_url(architecture),
                SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
                SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                SUSignedFeedFailureExpirationInterval=0)
    path.write_bytes(plistlib.dumps(info))
    verify_framework(app, architecture, run)
    sign_framework(app, "-", run)


def command(*args, capture=False):
    result = subprocess.run([str(arg) for arg in args], capture_output=capture, text=True, check=True)
    return result.stdout if capture else None


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("architecture", choices=("arm64", "x86_64", "universal"))
    args = parser.parse_args()
    embed(args.app, args.architecture, command)
