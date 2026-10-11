"""Sparkle bundle embedding, configuration and inside-out signing."""

import argparse
import base64
from pathlib import Path
import plistlib
import re
import subprocess


ROOT = Path(__file__).resolve().parent.parent
ARTIFACT = ROOT / ".build/artifacts/sparkle/Sparkle"
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
    key = run(ARTIFACT / "bin/generate_keys", "--account", KEY_ACCOUNT, "-p", capture=True).strip()
    if key != public_key():
        raise RuntimeError("Keychain key differs from the application public key; refusing to rotate")
    output = run(ARTIFACT / "bin/sign_update", "--account", KEY_ACCOUNT, path, capture=True)
    signature = re.search(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"', output)
    length = re.search(r'length="([0-9]+)"', output)
    if signature is None or length is None or int(length.group(1)) != path.stat().st_size:
        raise RuntimeError("Sparkle did not return a matching signed archive length")
    verify_archive(path, signature.group(1), run)
    return {"edSignature": signature.group(1), "length": path.stat().st_size, "publicKey": key}


def embed(app, architecture, run):
    source = ARTIFACT / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    run("ditto", source, framework_path(app))
    path = app / "Contents/Info.plist"
    info = plistlib.loads(path.read_bytes())
    info.update(SUPublicEDKey=public_key(), SUFeedURL=feed_url(architecture),
                SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False)
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
