#!/usr/bin/env python3
"""Structural anonymity and packaging verification for AWS Platform releases."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile


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


def _verify_licenses_and_provenance(licenses_dir, frameworks_dir, package_resolved):
    manifest_path = licenses_dir / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise RuntimeError("Missing license manifest.json in Contents/Resources/Licenses")
    resolved_path = Path(package_resolved)
    if not resolved_path.is_file():
        raise RuntimeError(f"Missing Package.resolved for license verification: {resolved_path}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    resolved = json.loads(resolved_path.read_text(encoding="utf-8"))
    expected_pins = {pin["identity"]: pin["state"]["revision"] for pin in resolved.get("pins", [])}
    actual_pins = {pkg["identity"]: pkg["revision"] for pkg in manifest.get("packages", [])}
    if not expected_pins or actual_pins != expected_pins:
        raise RuntimeError("Bundled license manifest packages do not match Package.resolved")

    listed_files = manifest.get("files")
    if not isinstance(listed_files, dict) or not listed_files:
        raise RuntimeError("Bundled license manifest files index is missing or empty")

    actual_files = {}
    for entry in licenses_dir.rglob("*"):
        if entry.is_symlink():
            raise RuntimeError(f"Forbidden symlink inside bundled licenses: {entry.name}")
        if entry.is_dir():
            continue
        if not entry.is_file():
            raise RuntimeError(f"Unexpected non-regular file inside bundled licenses: {entry.name}")
        rel = entry.relative_to(licenses_dir).as_posix()
        if rel != "manifest.json":
            actual_files[rel] = entry

    if set(actual_files.keys()) != set(listed_files.keys()):
        raise RuntimeError("Bundled license files do not match manifest.json file list")
    for rel, expected_sha in listed_files.items():
        actual_sha = hashlib.sha256(actual_files[rel].read_bytes()).hexdigest()
        if actual_sha != expected_sha:
            raise RuntimeError(f"Bundled license checksum mismatch: {rel}")

    provenance_path = licenses_dir / "swift-runtime/PROVENANCE.json"
    if not provenance_path.is_file():
        raise RuntimeError("Missing swift-runtime/PROVENANCE.json in bundled licenses")
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    provenance_libs = [item.get("name") for item in provenance.get("embedded_libraries", [])]
    embedded_libs = [p.name for p in sorted(frameworks_dir.glob("libswift*.dylib"))]
    if provenance_libs != embedded_libs:
        raise RuntimeError(
            f"PROVENANCE.json embedded_libraries mismatch: expected {embedded_libs}, found {provenance_libs}"
        )


def verify_anonymous_app(app_path, run=_default_run, check_privacy=True, patterns_file=None,
                         package_resolved=ROOT / "Package.resolved"):
    """Run structural anonymity, universal arch, and privacy assertions on AWSPlatform.app."""
    app = Path(app_path)
    if not app.is_dir():
        raise RuntimeError(f"Missing application bundle: {app}")

    licenses = app / "Contents/Resources/Licenses"
    if not licenses.is_dir() or not any(licenses.iterdir()):
        raise RuntimeError("Missing bundled third-party licenses in Contents/Resources/Licenses")
    frameworks = app / "Contents/Frameworks"
    _verify_licenses_and_provenance(licenses, frameworks, package_resolved)

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
        for arch in sorted(archs):
            arc_rc, arc_out, arc_err = run("codesign", "--arch", arch, "-dvvv", str(binary))
            if arc_rc != 0:
                raise RuntimeError(f"codesign --arch {arch} inspect failed for {binary.name}")
            assert_anonymous_signature_text(
                arc_out + "\n" + arc_err, f"{binary.name} ({arch})", require_adhoc=True
            )

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
    if "Signature=" in combined:
        raise RuntimeError(f"Unexpected Signature field in DMG container: {dmg.name}")
    for line in combined.splitlines():
        if line.startswith("TeamIdentifier=") and line != "TeamIdentifier=not set":
            raise RuntimeError(f"Non-empty TeamIdentifier leaked in DMG container: {dmg.name}")
    if "not signed at all" not in combined:
        raise RuntimeError(f"DMG container did not report unsigned status: {dmg.name}")


ALLOWED_DMG_SYSTEM_ENTRIES = {
    ".hfs+ private directory data\r",
    ".hfs+ private directory data",
    ".journal",
    ".journal_info_block",
    ".trashes",
    ".fseventsd",
}


def verify_zip_container(zip_path, expected_root="AWSPlatform.app"):
    """Ensure the ZIP archive has no archive/entry comments or entries outside expected_root."""
    archive = Path(zip_path)
    if not archive.is_file():
        raise RuntimeError(f"Missing ZIP file: {archive}")
    with zipfile.ZipFile(archive, "r") as zf:
        if zf.comment:
            raise RuntimeError(f"Unexpected archive comment in {archive.name}")
        infos = zf.infolist()
        if not infos:
            raise RuntimeError(f"Empty ZIP archive: {archive.name}")
        for info in infos:
            if info.comment:
                raise RuntimeError(f"Unexpected entry comment in {archive.name}: {info.filename}")
            if "\\" in info.filename or info.filename.startswith("/"):
                raise RuntimeError(f"Unsafe ZIP entry path in {archive.name}: {info.filename}")
            parts = info.filename.rstrip("/").split("/")
            if not parts or parts[0] != expected_root or any(p in ("", ".", "..") for p in parts):
                raise RuntimeError(f"Unexpected ZIP entry in {archive.name}: {info.filename}")


def verify_mounted_dmg_root(mount_dir):
    """Ensure mounted DMG root contains only AWSPlatform.app and symlink Applications -> /Applications."""
    root = Path(mount_dir)
    if not root.is_dir():
        raise RuntimeError(f"Missing mounted DMG directory: {root}")
    visible = {}
    with os.scandir(root) as entries:
        for entry in entries:
            if entry.name.casefold() in ALLOWED_DMG_SYSTEM_ENTRIES:
                continue
            visible[entry.name] = entry
    if set(visible.keys()) != {"AWSPlatform.app", "Applications"}:
        raise RuntimeError(f"Unexpected entries in DMG root: {sorted(visible.keys())}")
    app_entry = visible["AWSPlatform.app"]
    if app_entry.is_symlink() or not app_entry.is_dir(follow_symlinks=False):
        raise RuntimeError("DMG root AWSPlatform.app must be a directory")
    apps_entry = visible["Applications"]
    if not apps_entry.is_symlink() or os.readlink(apps_entry.path) != "/Applications":
        raise RuntimeError("DMG root Applications must symlink to /Applications")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", type=Path, help="Path to AWSPlatform.app, .zip, .dmg, or mounted DMG directory")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dmg", action="store_true", help="Verify DMG container carries no signing identity")
    mode.add_argument("--zip", action="store_true", help="Verify ZIP container metadata and root entries")
    mode.add_argument("--dmg-mount", action="store_true", help="Verify mounted DMG root and bundled AWSPlatform.app")
    parser.add_argument("--patterns-file", type=Path, help="Optional private patterns JSON file")
    args = parser.parse_args(argv)
    if args.dmg:
        verify_unsigned_dmg(args.target)
    elif args.zip:
        verify_zip_container(args.target)
    elif args.dmg_mount:
        verify_mounted_dmg_root(args.target)
        verify_anonymous_app(args.target / "AWSPlatform.app", patterns_file=args.patterns_file)
    else:
        verify_anonymous_app(args.target, patterns_file=args.patterns_file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
