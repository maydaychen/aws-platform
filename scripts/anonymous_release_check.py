#!/usr/bin/env python3
"""Structural anonymity and packaging verification for AWS Platform releases."""

import argparse
import importlib.util
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("awsplatform_privacy", ROOT / "scripts/privacy_scan.py")
privacy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = privacy
spec.loader.exec_module(privacy)

FORBIDDEN_BUNDLE_NAMES = {"._*", ".DS_Store", "*.provisionprofile", "embedded.mobileprovision"}


def _default_run(*args):
    result = subprocess.run([str(arg) for arg in args], text=True, capture_output=True)
    return result.returncode, result.stdout, result.stderr


def assert_anonymous_signature_text(info_text, label, require_adhoc=True):
    """Verify codesign output contains no Authority or non-empty TeamIdentifier."""
    for line in info_text.splitlines():
        if line.startswith("Authority="):
            raise RuntimeError(f"Signing Authority leaked in {label}")
        if line.startswith("TeamIdentifier=") and line != "TeamIdentifier=not set":
            raise RuntimeError(f"Non-empty TeamIdentifier leaked in {label}")
    if require_adhoc and "Signature=adhoc" not in info_text:
        raise RuntimeError(f"Expected Signature=adhoc in {label}")


def verify_anonymous_app(app_path, run=_default_run, check_privacy=True, patterns_file=None):
    """Run structural anonymity, universal arch, and privacy assertions on AWSPlatform.app."""
    app = Path(app_path)
    if not app.is_dir():
        raise RuntimeError(f"Missing application bundle: {app}")

    licenses = app / "Contents/Resources/Licenses"
    if not licenses.is_dir() or not any(licenses.iterdir()):
        raise RuntimeError("Missing bundled third-party licenses in Contents/Resources/Licenses")

    sparkle = app / "Contents/Frameworks/Sparkle.framework"
    if sparkle.exists() or sparkle.is_symlink():
        raise RuntimeError("Unexpected Sparkle.framework in anonymous release bundle")

    for entry in app.rglob("*"):
        name = entry.name
        if (name.startswith("._") or name == ".DS_Store"
                or name.endswith(".provisionprofile") or name == "embedded.mobileprovision"):
            raise RuntimeError(f"Forbidden metadata or provisioning entry inside bundle: {entry.name}")

    executable = app / "Contents/MacOS/AWSPlatform"
    if not executable.is_file():
        raise RuntimeError("Missing main executable AWSPlatform")

    binaries = [executable, *sorted((app / "Contents/Frameworks").glob("*.dylib"))]
    for binary in binaries:
        rc, out, err = run("xcrun", "lipo", "-archs", str(binary))
        if rc != 0:
            raise RuntimeError(f"Failed to inspect architectures for {binary.name}: {err.strip()}")
        archs = set(out.split())
        if not {"arm64", "x86_64"}.issubset(archs):
            raise RuntimeError(f"Expected universal arm64+x86_64 in {binary.name}; found {sorted(archs)}")

    for library in sorted((app / "Contents/Frameworks").glob("*.dylib")):
        rc, out, err = run("codesign", "-dvvv", str(library))
        if rc != 0:
            raise RuntimeError(f"codesign inspect failed for {library.name}")
        assert_anonymous_signature_text(out + "\n" + err, library.name, require_adhoc=True)

    rc, out, err = run("codesign", "-dvvv", str(app))
    if rc != 0:
        raise RuntimeError(f"codesign inspect failed for {app.name}")
    assert_anonymous_signature_text(out + "\n" + err, app.name, require_adhoc=True)

    rc, _, err = run("codesign", "--verify", "--deep", "--strict", str(app))
    if rc != 0:
        raise RuntimeError(f"codesign --verify failed for {app.name}: {err.strip()}")

    if check_privacy:
        patterns = privacy.load_patterns(patterns_file)
        privacy.require_clean(app, patterns)


def verify_unsigned_dmg(dmg_path, run=_default_run):
    """Ensure the DMG container itself carries no Developer ID signature."""
    dmg = Path(dmg_path)
    if not dmg.is_file():
        raise RuntimeError(f"Missing DMG file: {dmg}")
    _, out, err = run("codesign", "-dvvv", str(dmg))
    combined = out + "\n" + err
    if re.search(r"^Authority=", combined, re.M):
        raise RuntimeError(f"Signing Authority leaked in DMG container: {dmg.name}")
    for line in combined.splitlines():
        if line.startswith("TeamIdentifier=") and line != "TeamIdentifier=not set":
            raise RuntimeError(f"Non-empty TeamIdentifier leaked in DMG container: {dmg.name}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", type=Path, help="Path to AWSPlatform.app or .dmg")
    parser.add_argument("--dmg", action="store_true", help="Verify DMG container carries no signing identity")
    parser.add_argument("--patterns-file", type=Path, help="Optional private patterns JSON file")
    args = parser.parse_args(argv)
    if args.dmg:
        verify_unsigned_dmg(args.target)
    else:
        verify_anonymous_app(args.target, patterns_file=args.patterns_file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
