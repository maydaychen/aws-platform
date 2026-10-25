#!/usr/bin/env python3
"""Collect offline license materials for the pinned macOS distribution."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
LICENSE_NAME = re.compile(r"^(?:licen[cs]e|copying|notice|copyright)(?:[._-].*)?$", re.I)
SOURCE_SUFFIXES = {".c", ".cc", ".cpp", ".h", ".hpp", ".inc", ".m", ".mm", ".s", ".swift"}
LEGAL_MARKER = re.compile(r"copyright|licen[cs]e|permission is (?:hereby )?granted|redistribution and use", re.I)
LEADING_COMMENT = re.compile(r"\s*(/\*.*?\*/|(?://[^\n]*(?:\n|$))+)", re.S)


def command(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def leading_notices(source):
    """Retain complete leading legal comments, never executable source bodies."""
    notices = []
    offset = 0
    while match := LEADING_COMMENT.match(source, offset):
        comment = match.group(1)
        if LEGAL_MARKER.search(comment):
            notices.append(comment)
        offset = match.end()
    return "\n\n".join(notices)


def checked_file(root, relative):
    path = root / relative
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Expected a regular file within its source: {relative}")
    return path.read_bytes()


def collect_package(pin, checkouts):
    identity = pin["identity"]
    if identity in {".", ".."} or not re.fullmatch(r"[a-z0-9_.-]+", identity):
        raise ValueError("Invalid package identity")
    checkout = checkouts / identity
    revision = pin["state"]["revision"]
    if command("git", "rev-parse", "HEAD", cwd=checkout) != revision:
        raise ValueError(f"Checkout does not match Package.resolved: {identity}")
    if command("git", "status", "--porcelain", "--untracked-files=no", cwd=checkout):
        raise ValueError(f"Checkout has modified tracked files: {identity}")
    tracked = command("git", "ls-files", "-z", cwd=checkout).split("\0")
    licenses = [name for name in tracked if name and LICENSE_NAME.fullmatch(Path(name).name)]
    if not any("/" not in name and re.match(r"^(?:licen[cs]e|copying)(?:[._-]|$)", name, re.I) for name in licenses):
        raise ValueError(f"Missing root license: {identity}")
    files = {name: checked_file(checkout, name) for name in licenses}
    comments = {}
    for name in tracked:
        if not name.startswith("Sources/") or Path(name).suffix.lower() not in SOURCE_SUFFIXES:
            continue
        if (checkout / name).is_symlink():
            # Swift Async Algorithms aliases a tracked source file. Its target
            # is scanned once at the real path; never follow external links.
            target = (checkout / name).resolve().relative_to(checkout.resolve()).as_posix()
            if target not in tracked or not target.startswith("Sources/"):
                raise ValueError(f"Source alias is not a tracked source: {identity}/{name}")
            continue
        content = checked_file(checkout, name).decode("utf-8")
        notice = leading_notices(content)
        if notice:
            comments.setdefault(notice, []).append(name)
    if comments:
        sections = ["Leading copyright and license comments from Sources/ at the pinned revision.\n"
                    "Repeated comment text is included once with all corresponding source paths.\n"
                    "This is a conservative package-source inventory, not a linker reachability report.\n"]
        for notice, names in comments.items():
            sections.extend(["\n" + "=" * 72, "Source files:\n" + "\n".join(names), "\n" + notice])
        files["SOURCE-COPYRIGHT-NOTICES.txt"] = ("\n".join(sections) + "\n").encode()
    metadata = {"identity": identity, "version": pin["state"].get("version"),
                "revision": revision, "repository": pin["location"],
                "license_files": licenses, "source_notice_groups": len(comments)}
    return files, metadata


def collect(root, output):
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise ValueError("Output must be a new or empty directory; existing materials are never removed")
    pins = json.loads((root / "Package.resolved").read_text())["pins"]
    files = {name: checked_file(root, name) for name in ("LICENSE", "THIRD_PARTY_NOTICES.md")}
    packages = []
    for pin in pins:
        package_files, metadata = collect_package(pin, root / ".build/checkouts")
        files.update({f"packages/{pin['identity']}/{name}": data for name, data in package_files.items()})
        packages.append(metadata)

    # These fixed upstream texts supplement vendored files that contain only a
    # license URL. Fail on dependency updates so attribution is reviewed again.
    snapshots = json.loads((root / "scripts/licenses/sources.json").read_text())
    revisions = {pin["identity"]: pin["state"]["revision"] for pin in pins}
    for entry in snapshots:
        if entry["package"] and revisions.get(entry["package"]) != entry["package_revision"]:
            raise ValueError(f"Review supplemental licenses after updating {entry['package']}")
        data = checked_file(root / "scripts/licenses", entry["file"])
        if sha256(data) != entry["sha256"]:
            raise ValueError(f"Supplemental license checksum mismatch: {entry['file']}")
        files[f"supplemental/{entry['file']}"] = data
    files["supplemental/sources.json"] = checked_file(root / "scripts/licenses", "sources.json")
    files["supplemental/README.md"] = checked_file(root / "scripts/licenses", "README.md")

    swift = Path(command("xcrun", "--find", "swift")).resolve()
    toolchain = swift.parents[2]
    acknowledgments = toolchain.parent.parent.parent / "Resources/Acknowledgments.pdf"
    if not acknowledgments.is_file():
        raise ValueError("The selected Xcode must include Resources/Acknowledgments.pdf for runtime attribution")
    files["swift-runtime/Xcode-Acknowledgments.pdf"] = acknowledgments.read_bytes()
    runtime_candidates = sorted(toolchain.glob("usr/lib/swift*/macosx/libswiftCompatibilitySpan.dylib"))
    if not runtime_candidates:
        raise ValueError("The selected toolchain has no macOS Swift Span compatibility runtime")
    runtime = {"swift_version": command(str(swift), "--version"),
               "xcode_version": command("xcodebuild", "-version"),
               "acknowledgments_source": "Xcode.app/Contents/Resources/Acknowledgments.pdf",
               "toolchain_candidates": [{"path": str(path.relative_to(toolchain)),
                                          "sha256": sha256(path.read_bytes())}
                                         for path in runtime_candidates],
               "embedded_libraries": []}
    frameworks = output.parent.parent / "Frameworks"
    if frameworks.is_dir():
        runtime["embedded_libraries"] = [{"name": path.name, "sha256_before_signing": sha256(path.read_bytes())}
                                         for path in sorted(frameworks.glob("libswift*.dylib"))]
    files["swift-runtime/PROVENANCE.json"] = (json.dumps(runtime, indent=2) + "\n").encode()

    index = ["# AWSPlatform distribution licenses", "",
             "The original application is licensed under MIT. Third-party components retain their own terms.",
             "This directory includes all resolved packages as a conservative superset of linked components.",
             "Full license and NOTICE files are preserved under each package's original relative path.",
             "SOURCE-COPYRIGHT-NOTICES.txt preserves leading legal comments without executable source bodies.",
             "Supplemental upstream texts fill gaps in vendored attribution; see supplemental/sources.json.", "",
             "## Swift runtime", "",
             "The original local Xcode Acknowledgments PDF includes Apple's Swift attribution.",
             "The Swift 6.2 release license is included as an upstream reference; it is not a claim that",
             "the selected Apple toolchain was built from that open-source tag. Runtime provenance records",
             "the selected toolchain and binary hashes; signing may subsequently change embedded dylib hashes.", "",
             "## Resolved packages", "", "| Package | Version | Revision |", "| --- | --- | --- |"]
    index.extend(f"| {item['identity']} | {item['version']} | `{item['revision']}` |" for item in packages)
    files["README.md"] = ("\n".join(index) + "\n").encode()
    manifest = {"packages": packages, "supplemental_sources": snapshots,
                "files": {name: sha256(data) for name, data in sorted(files.items())}}
    files["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    output.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        destination = output / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    return len(packages), len(files), sum(len(data) for data in files.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="New or empty license directory")
    args = parser.parse_args()
    try:
        packages, count, size = collect(ROOT, args.output.resolve())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"License collection failed: {error}", file=sys.stderr)
        return 1
    print(f"Collected {packages} pinned packages; {count} files; {size} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
