#!/usr/bin/env python3
"""Scan staged source or app trees without logging matched personal values."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys
from typing import NamedTuple


CHUNK_SIZE = 1024 * 1024
EMAIL_MARKER_GUARD_BYTES = 256
PATTERNS_ENV = "AWSPLATFORM_PRIVACY_PATTERNS_FILE"
MAX_PATTERN_FILE_BYTES = 1024 * 1024
HOME_PATH = re.compile(r"(?:/(?:Users|home)/|[a-z]:\\+Users\\+)([^/\\\x00\s\"'<>:]{1,255})[/\\]", re.I)
EMAIL = re.compile(r"[a-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@([a-z0-9-]{1,63}(?:\.[a-z0-9-]{1,63})+)", re.I)
PLACEHOLDER_USERS = {"user", "username", "your_user", "your_username", "your_name", "example",
                     "example-user", "test", "testuser", "placeholder", "shared", "public"}
EXAMPLE_DOMAINS = {"example.com", "example.net", "example.org"}
LICENSE_NAMES = {"license", "licence", "copying", "copyright", "notice"}
LICENSE_FILES = {"third_party_notices.md", "source-copyright-notices.txt"}


class Finding(NamedTuple):
    path: str
    rule: str


def _validated_patterns(value):
    if not isinstance(value, (list, tuple)) or any(
        not isinstance(item, str) or not item.strip() for item in value
    ):
        raise RuntimeError("Privacy patterns must be an array of nonempty strings")
    try:
        encoded_size = sum(len(item.encode("utf-8")) for item in value)
    except UnicodeError:
        raise RuntimeError("Privacy patterns must contain valid Unicode strings") from None
    if encoded_size > MAX_PATTERN_FILE_BYTES:
        raise RuntimeError("Privacy pattern configuration is too large")
    return tuple(dict.fromkeys(item.casefold() for item in value))


def load_patterns(path=None):
    """Read private local literals; never include their contents in errors."""
    selected = path if path is not None else os.environ.get(PATTERNS_ENV)
    if not selected:
        return ()
    try:
        target = Path(selected).resolve(strict=True)
        descriptor = os.open(target, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(descriptor, "rb") as source:
            if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                raise ValueError()
            raw = source.read(MAX_PATTERN_FILE_BYTES + 1)
        if len(raw) > MAX_PATTERN_FILE_BYTES:
            raise ValueError()
        return _validated_patterns(json.loads(raw))
    except (OSError, ValueError, UnicodeError, RuntimeError):
        raise RuntimeError("Privacy pattern configuration could not be read or is invalid") from None


def _example_email(domain):
    domain = domain.casefold()
    return (domain == "users.noreply.github.com"
            or domain.endswith((".test", ".example", ".invalid"))
            or any(domain == item or domain.endswith("." + item) for item in EXAMPLE_DOMAINS))


def _binary_boundary(char):
    return bool(char) and (
        char == "\ufffd" or (ord(char) < 32 and char not in "\0\t\n\r") or ord(char) == 127
    )


def _email_candidate(text, match):
    domain = match.group(1)
    # Versions and short random binary runs are not Internet mail domains.
    if not re.fullmatch(r"[a-z]{2,63}|xn--[a-z0-9-]{2,59}", domain.rsplit(".", 1)[-1], re.I):
        return False
    if re.fullmatch(r"[123]x\.(?:png|jpe?g|gif|icns|pdf|svg|webp)", domain, re.I):
        return False
    before = text[match.start() - 1] if match.start() > 0 else ""
    after = text[match.end()] if match.end() < len(text) else ""
    if len(match.group()) < 12 and _binary_boundary(before) and _binary_boundary(after):
        return False
    local = match.group().rsplit("@", 1)[0]
    if (local.startswith("//") and local[2:].casefold() in PLACEHOLDER_USERS
            and text[max(0, match.start() - 6):match.start()].endswith(("http:", "https:"))):
        return False
    return True


def _email_scan_data(data, prefix=b""):
    # These exact public author markers are retained by the pinned BoringSSL ASM.
    # Mask only for mailbox detection; home paths and deny literals use raw data.
    address = "appro" + "@" + "openssl.org"
    combined = prefix + data if prefix else data
    changed = False
    for marker in ("CRYPTOGAMS by <", "GHASH for ARMv8, derived from ARMv4 version by <"):
        for encoding in ("utf-8", "utf-16-le", "utf-16-be"):
            value = (marker + address + ">").encode(encoding)
            if value in combined:
                combined = combined.replace(value, b"\0" * len(value))
                changed = True
    if not changed:
        return data
    return combined[len(prefix):]


def _license_file(relative):
    parts = [part.casefold() for part in relative.parts]
    if any(parts[index:index + 3] == ["contents", "resources", "licenses"]
           for index in range(max(0, len(parts) - 2))):
        return True
    name = parts[-1]
    if parts[:2] == ["scripts", "licenses"] and relative.suffix.casefold() == ".txt":
        return True
    return name in LICENSE_FILES or any(name == item or name in (item + ".txt", item + ".md")
                                        for item in LICENSE_NAMES)


def _display_path(relative, patterns):
    value = relative.as_posix()
    value = EMAIL.sub("[email]", value)
    value = HOME_PATH.sub("[home]/", value)
    for pattern in patterns:
        if pattern in value.casefold():
            redacted = re.sub(re.escape(pattern), "[private]", value, flags=re.I)
            value = redacted if redacted != value else "[private-file]"
    return value.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")


def _text_views(data):
    yield data.decode("utf-8", errors="replace")
    # Embedded UTF-16 strings need not start at an even byte offset in a binary.
    if b"\0" in data:
        for offset in (0, 1):
            value = data[offset:len(data) - ((len(data) - offset) % 2)]
            for encoding in ("utf-16-le", "utf-16-be"):
                yield value.decode(encoding, errors="replace")


def _rules_in(data, patterns, license_file, final, email_prefix=b""):
    found = set()
    email_data = _email_scan_data(data, email_prefix) if not license_file else data
    for text in _text_views(data):
        if any(match.group(1).casefold() not in PLACEHOLDER_USERS for match in HOME_PATH.finditer(text)):
            found.add("private-home-path")
        if not license_file and email_data is data and "@" in text and any(
            (final or match.end() < len(text)) and _email_candidate(text, match)
            and not _example_email(match.group(1))
            for match in EMAIL.finditer(text)
        ):
            found.add("non-example-email")
        if patterns:
            folded = text.casefold()
            if any(pattern in folded for pattern in patterns):
                found.add("private-pattern")
    if not license_file and email_data is not data:
        for text in _text_views(email_data):
            if "@" in text and any(
                (final or match.end() < len(text)) and _email_candidate(text, match)
                and not _example_email(match.group(1)) for match in EMAIL.finditer(text)
            ):
                found.add("non-example-email")
    return found


def _scan_file(path, relative, patterns):
    found = set()
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as source:
            before = os.fstat(source.fileno())
            if not stat.S_ISREG(before.st_mode):
                return {"special-file"}
            overlap = max(4096, max((len(item.encode("utf-8")) * 4 for item in patterns), default=0))
            carry = b""
            license_file = _license_file(relative)
            while True:
                tail = carry[-overlap:]
                email_prefix = carry[:-overlap]
                chunk = source.read(CHUNK_SIZE)
                if not chunk:
                    found.update(_rules_in(tail, patterns, license_file, final=True, email_prefix=email_prefix))
                    break
                window = tail + chunk
                found.update(_rules_in(window, patterns, license_file, final=False, email_prefix=email_prefix))
                carry = (email_prefix + window)[-(overlap + EMAIL_MARKER_GUARD_BYTES):]
            after = os.fstat(source.fileno())
            if (before.st_size, before.st_mtime_ns, before.st_ino) != (
                after.st_size, after.st_mtime_ns, after.st_ino
            ):
                found.add("changed-during-scan")
    except OSError:
        found.add("unreadable-file")
    return found


def scan_tree(root, extra_patterns=()):
    """Return findings for a staged directory; do not silently skip unreadable data."""
    patterns = _validated_patterns(extra_patterns)
    try:
        root = Path(root).resolve(strict=True)
        if not root.is_dir():
            return [Finding(".", "missing-directory")]
    except (OSError, RuntimeError):
        return [Finding(".", "missing-directory")]
    findings = set()
    scanned = set()

    def add(relative, rule):
        findings.add(Finding(_display_path(relative, patterns), rule))

    def visit(directory):
        try:
            with os.scandir(directory) as entries:
                paths = sorted((Path(entry.path) for entry in entries), key=lambda item: item.name)
        except OSError:
            add(directory.relative_to(root), "unreadable-directory")
            return
        for path in paths:
            relative = path.relative_to(root)
            for rule in _rules_in(relative.as_posix().encode("utf-8", errors="surrogateescape"),
                                  patterns, False, final=True):
                add(relative, rule)
            try:
                target = path.resolve(strict=True)
                if not target.is_relative_to(root):
                    add(relative, "external-symlink")
                    continue
                entry_stat = path.lstat()
                if stat.S_ISLNK(entry_stat.st_mode):
                    if target.is_dir():
                        # Its actual in-root directory is traversed by its normal path.
                        continue
                    target_stat = target.stat()
                    if not stat.S_ISREG(target_stat.st_mode):
                        add(relative, "special-file")
                        continue
                elif stat.S_ISDIR(entry_stat.st_mode):
                    visit(path)
                    continue
                elif not stat.S_ISREG(entry_stat.st_mode):
                    add(relative, "special-file")
                    continue
                if target not in scanned:
                    scanned.add(target)
                    for rule in _scan_file(target, target.relative_to(root), patterns):
                        add(relative, rule)
            except (OSError, RuntimeError):
                add(relative, "unreadable-file")

    visit(root)
    return sorted(findings)


def require_clean(root, extra_patterns=()):
    findings = scan_tree(root, extra_patterns)
    if findings:
        summary = ", ".join(f"{item.path}: {item.rule}" for item in findings[:10])
        raise RuntimeError(f"Privacy scan failed ({len(findings)} findings): {summary}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="Staged source directory or app bundle to scan")
    parser.add_argument("--patterns-file", type=Path, help="Private JSON array of additional denied literals")
    arguments = parser.parse_args(argv)
    try:
        findings = scan_tree(arguments.root, load_patterns(arguments.patterns_file))
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        return 2
    for finding in findings:
        print(json.dumps(finding._asdict()))
    if findings:
        print(f"Privacy scan failed: {len(findings)} findings", file=sys.stderr)
        return 1
    print("Privacy scan passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
