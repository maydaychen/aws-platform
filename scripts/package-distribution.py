#!/usr/bin/env python3
"""Build and notarize a Universal ZIP and DMG using an existing Developer ID."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def run(*args, capture=False):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, text=True,
                            capture_output=capture)
    if result.returncode:
        # Captured authentication/upload output must not leak into build logs.
        raise RuntimeError(f"{Path(str(args[0])).name} {args[1]} failed ({result.returncode})")
    return result.stdout if capture else None


def signing_details(path):
    result = subprocess.run(["codesign", "-dvvv", str(path)], text=True,
                            capture_output=True, check=True)
    return result.stdout + result.stderr


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_signature(path, team, runtime=False):
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", path)
    details = signing_details(path)
    required = ["Authority=Developer ID Application:", f"TeamIdentifier={team}", "Timestamp="]
    if runtime:
        required.append("(runtime)")
    if any(value not in details for value in required):
        raise RuntimeError(f"Distribution signature requirements not met: {path.name}")


def notarize(path, evidence, name):
    print(f"Submitting {name} for Apple notarization...", flush=True)
    result = subprocess.run(["asc", "notarization", "submit", "--file", str(path), "--wait",
                             "--poll-interval", "20s", "--timeout", "30m", "--output", "json"],
                            cwd=ROOT, text=True, capture_output=True)
    if not result.stdout.strip():
        raise RuntimeError("Notarization returned no result; inspect Apple history before retrying")
    response = json.loads(result.stdout)
    submission = response.get("data", response)
    identifier = submission.get("id")
    if not isinstance(identifier, str) or not re.fullmatch(r"[0-9a-fA-F-]{36}", identifier):
        raise RuntimeError("No notarization submission ID returned; inspect Apple history before retrying")
    record = {"id": identifier, "status": submission.get("attributes", {}).get("status", "Unknown"),
              "file": path.name}
    (evidence / f"notary-{name}.json").write_text(json.dumps(record, indent=2) + "\n")
    status = json.loads(run("asc", "notarization", "status", "--id", identifier,
                            "--output", "json", capture=True))["data"]["attributes"]["status"]
    record["status"] = status
    (evidence / f"notary-{name}.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"{name}: {status} ({identifier})", flush=True)
    if result.returncode or status != "Accepted":
        raise RuntimeError(f"Apple notarization was not Accepted: {identifier}")
    return record


def package(identity, team):
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True)
    pattern = rf'^\s*\d+\) {re.escape(identity)} "Developer ID Application: .* \({re.escape(team)}\)"$'
    if not any(re.match(pattern, line) for line in identities.splitlines()):
        raise RuntimeError("Matching valid Developer ID Application identity and team not found")
    run("asc", "notarization", "list", "--limit", "1", "--output", "json", capture=True)
    if run("git", "status", "--porcelain", "--", "Sources", "Tests", "Package.swift",
           "Package.resolved", capture=True).strip():
        raise RuntimeError("Commit and verify application source changes before distribution")
    source_commit = run("git", "rev-parse", "HEAD", capture=True).strip()
    temporary_root = ROOT / ".tmp" / "distribution"
    temporary_root.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix="run-", dir=temporary_root))
    print(f"Staging distribution at {stage}", flush=True)
    try:
        build = stage / "build"
        run(ROOT / "scripts" / "build-universal.sh", "--output-dir", build)
        app = build / "AWSPlatform.app"
        info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
        version = info["CFBundleShortVersionString"]
        build_number = info["CFBundleVersion"]
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
            raise RuntimeError("Invalid application version")
        stem = f"AWSPlatform-{version}-universal"
        destination = ROOT / "dist" / stem
        if destination.exists():
            raise RuntimeError(f"Keep or move the existing distribution first: {destination}")
        output = stage / "output"
        output.mkdir()
        evidence = stage / "evidence"
        evidence.mkdir()
        run(sys.executable, ROOT / "scripts" / "collect-licenses.py", "--output",
            app / "Contents" / "Resources" / "Licenses")

        # Sign from the inside out; do not use --deep to apply signatures.
        for library in sorted((app / "Contents" / "Frameworks").glob("*.dylib")):
            run("codesign", "--force", "--sign", identity, "--timestamp", "--options", "runtime", library)
            verify_signature(library, team, runtime=True)
        run("codesign", "--force", "--sign", identity, "--timestamp", "--options", "runtime", app)
        verify_signature(app, team, runtime=True)
        submission_zip = stage / "AWSPlatform-notarization.zip"
        run("ditto", "-c", "-k", "--keepParent", app, submission_zip)
        app_notary = notarize(submission_zip, evidence, "app")
        run("xcrun", "stapler", "staple", app)
        run("xcrun", "stapler", "validate", app)
        verify_signature(app, team, runtime=True)
        run("spctl", "--assess", "--type", "execute", "--verbose=2", app)

        zip_path = output / f"{stem}.zip"
        run("ditto", "-c", "-k", "--keepParent", app, zip_path)
        run("unzip", "-t", "-q", zip_path)
        dmg_source = stage / "dmg-source"
        dmg_source.mkdir()
        run("ditto", app, dmg_source / "AWSPlatform.app")
        (dmg_source / "Applications").symlink_to("/Applications")
        dmg_path = output / f"{stem}.dmg"
        run("hdiutil", "create", "-volname", "AWS Platform", "-srcfolder", dmg_source,
            "-format", "UDZO", "-fs", "HFS+", dmg_path)
        run("codesign", "--force", "--sign", identity, "--timestamp", dmg_path)
        verify_signature(dmg_path, team)
        dmg_notary = notarize(dmg_path, evidence, "dmg")
        run("xcrun", "stapler", "staple", dmg_path)
        run("xcrun", "stapler", "validate", dmg_path)
        verify_signature(dmg_path, team)
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature",
            "--verbose=2", dmg_path)
        checksums = {path.name: sha256(path) for path in (zip_path, dmg_path)}
        (output / "SHA256SUMS.txt").write_text("".join(f"{value}  {name}\n" for name, value in checksums.items()))
        manifest = {"version": version, "build": build_number, "bundleID": info["CFBundleIdentifier"],
                    "sourceCommit": source_commit, "architectures": ["arm64", "x86_64"],
                    "minimumMacOS": "13.0", "teamID": team, "appNotarization": app_notary,
                    "dmgNotarization": dmg_notary, "sha256": checksums}
        (output / "distribution.json").write_text(json.dumps(manifest, indent=2) + "\n")
        shutil.move(str(app), output / "AWSPlatform.app")
        destination.parent.mkdir(exist_ok=True)
        os.rename(output, destination)
        print(f"Signed and notarized distribution: {destination}", flush=True)
        try:
            shutil.rmtree(stage)
        except OSError:
            print(f"Distribution is ready; temporary cleanup remains at {stage}", file=sys.stderr)
    except BaseException:
        print(f"Distribution stopped; previous artifacts are unchanged. Work retained at {stage}", file=sys.stderr)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", required=True, help="SHA-1 of a valid Developer ID Application identity")
    parser.add_argument("--team-id", required=True, help="Apple Developer team identifier")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.identity) or not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        parser.error("Expected a 40-character identity SHA-1 and 10-character team ID")
    package(args.identity.upper(), args.team_id)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, ValueError) as error:
        sys.exit(str(error))
