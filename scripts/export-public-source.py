#!/usr/bin/env python3
"""Export reviewed source without copying Git history or local-only files."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("public_source_privacy_scan", ROOT / "scripts/privacy_scan.py")
privacy_scan = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = privacy_scan
spec.loader.exec_module(privacy_scan)
PRIVATE_COMPONENTS = {
    ".git", ".tmp", "dist", ".aws", ".build", ".build-local", ".swiftpm",
    "DerivedData", ".DerivedData", "__pycache__", ".codex", ".DS_Store",
}
PRIVATE_SUFFIXES = {".pem", ".key", ".p12", ".pfx", ".pyc", ".pyo"}


def git(source, *arguments):
    result = subprocess.run(["git", "-C", str(source), *arguments], capture_output=True)
    if result.returncode:
        raise RuntimeError("Source Git validation failed")
    return result.stdout


def source_head(source):
    if Path(os.fsdecode(git(source, "rev-parse", "--show-toplevel")).strip()).resolve() != source:
        raise RuntimeError("Source must be the repository root")
    if git(source, "status", "--porcelain", "-z", "--untracked-files=normal"):
        raise RuntimeError("Commit or preserve pending source changes before export")
    commit = git(source, "rev-parse", "--verify", "HEAD").decode("ascii").strip()
    if not re.fullmatch(r"[0-9a-f]{40,64}", commit):
        raise RuntimeError("Could not identify a fixed source commit")
    return commit


def checked_path(name):
    parts = name.rstrip("/").split("/")
    if not name or name.startswith("/") or "\\" in name or any(part in ("", ".", "..") for part in parts):
        raise RuntimeError("Archive contains an unsafe path")
    path = PurePosixPath(*parts)
    if (any(part in PRIVATE_COMPONENTS or part.startswith(".env") for part in parts)
            or path.suffix.lower() in PRIVATE_SUFFIXES):
        raise RuntimeError("Source contains a private or generated path")
    return path


def source_files(source, commit):
    files = {}
    for entry in git(source, "ls-tree", "-r", "-z", commit).split(b"\0"):
        if not entry:
            continue
        metadata, raw_name = entry.split(b"\t", 1)
        mode, kind, object_id = metadata.split(b" ", 2)
        if kind != b"blob" or mode not in (b"100644", b"100755"):
            raise RuntimeError("Public source must contain only regular tracked files")
        name = os.fsdecode(raw_name)
        checked_path(name)
        files[name] = (0o755 if mode == b"100755" else 0o644, object_id.decode("ascii"))
    if not files:
        raise RuntimeError("Source has no tracked files")
    return files


def extract_archive(stream, destination, expected_files):
    seen = set()
    with tarfile.open(fileobj=stream, mode="r|") as archive:
        for member in archive:
            relative = checked_path(member.name)
            name = str(relative)
            target = destination.joinpath(*relative.parts)
            if member.isdir():
                target.mkdir(mode=0o755, parents=True, exist_ok=True)
                continue
            if not member.isreg() or name not in expected_files or name in seen:
                raise RuntimeError("Archive contains an unsupported or unexpected entry")
            target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            data = archive.extractfile(member)
            if data is None:
                raise RuntimeError("Archive entry cannot be read")
            mode, object_id = expected_files[name]
            digest = hashlib.new("sha1" if len(object_id) == 40 else "sha256")
            digest.update(f"blob {member.size}\0".encode("ascii"))
            with data, target.open("xb") as output:
                while chunk := data.read(1024 * 1024):
                    output.write(chunk)
                    digest.update(chunk)
            if target.stat().st_size != member.size:
                raise RuntimeError("Archive entry is incomplete")
            if digest.hexdigest() != object_id:
                raise RuntimeError("Archive content differs from tracked source")
            target.chmod(mode)
            seen.add(name)
    if seen != set(expected_files):
        raise RuntimeError("Archive does not contain every tracked source file")
    return len(seen)


def export_public_source(source, output, patterns_file=None):
    source = Path(source).resolve()
    output = Path(output).absolute()
    if os.path.lexists(output):
        raise RuntimeError("Public source destination already exists")
    git_directory = Path(os.fsdecode(git(source, "rev-parse", "--absolute-git-dir")).strip()).resolve()
    resolved_output = output.resolve()
    if resolved_output == git_directory or git_directory in resolved_output.parents:
        raise RuntimeError("Public source destination cannot be inside Git metadata")
    commit = source_head(source)
    expected_files = source_files(source, commit)
    patterns = privacy_scan.load_patterns(patterns_file)
    manifest = output.with_name(output.name + ".manifest.json")
    if os.path.lexists(manifest):
        raise RuntimeError("Public source manifest already exists")
    output.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".public-source-", dir=output.parent))
    reserved_output = None
    manifest_created = False
    published = False
    try:
        process = subprocess.Popen(
            ["git", "-C", str(source), "archive", "--format=tar", commit],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        try:
            with process.stdout:
                count = extract_archive(process.stdout, stage, expected_files)
        except BaseException:
            process.terminate()
            process.wait()
            raise
        if process.wait() != 0:
            raise RuntimeError("Source archive failed")
        privacy_scan.require_clean(stage, extra_patterns=patterns)
        if source_head(source) != commit:
            raise RuntimeError("Source commit changed during export")
        record = {"schema_version": 1, "source_commit": commit, "file_count": count,
                  "includes_git_history": False, "privacy_scan": "passed"}
        descriptor = os.open(manifest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        manifest_created = True
        with os.fdopen(descriptor, "w") as stream:
            json.dump(record, stream, indent=2)
            stream.write("\n")
        output.mkdir(mode=0o700)
        reserved_output = output.stat()
        os.rename(stage, output)
        published = True
        return record
    finally:
        if not published:
            shutil.rmtree(stage)
            if reserved_output is not None and output.is_dir():
                current = output.stat()
                if (current.st_dev, current.st_ino) == (reserved_output.st_dev, reserved_output.st_ino):
                    output.rmdir()
            if manifest_created:
                manifest.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, default=ROOT)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--patterns-file", type=Path)
    options = parser.parse_args()
    try:
        record = export_public_source(options.source_dir, options.output_dir, options.patterns_file)
    except (RuntimeError, OSError, tarfile.TarError, UnicodeError, ValueError):
        # Never echo private root paths or the contents of matching files/configuration.
        print("Public source export failed; source and existing destinations were preserved.", file=sys.stderr)
        return 1
    print(json.dumps(record))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
