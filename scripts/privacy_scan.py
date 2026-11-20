#!/usr/bin/env python3
"""Scan staged source or app trees without logging matched personal values."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import struct
import sys
from typing import NamedTuple


CHUNK_SIZE = 1024 * 1024
EMAIL_MARKER_GUARD_BYTES = 256
PATTERNS_ENV = "AWSPLATFORM_PRIVACY_PATTERNS_FILE"
MAX_PATTERN_FILE_BYTES = 1024 * 1024
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
S_ATTR_PURE_INSTRUCTIONS = 0x80000000
MAX_FAT_SLICES = 16
MAX_LOAD_COMMANDS = 4096
MAX_SIZEOF_CMDS = 4 * 1024 * 1024
MAX_CS_BLOBS = 64
HOME_PATH = re.compile(r"(?:/(?:Users|home)/|[a-z]:\\+Users\\+)([^/\\\x00\s\"'<>:]{1,255})[/\\]", re.I)
EMAIL_PATTERN = r"[a-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@([a-z0-9-]{1,63}(?:\.[a-z0-9-]{1,63})+)"
EMAIL = re.compile(EMAIL_PATTERN, re.I)
EMAIL_BYTES = re.compile(EMAIL_PATTERN.encode("ascii"), re.I)
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


def _pread_exact(fd, size, offset):
    chunks = []
    remaining = size
    cursor = offset
    while remaining > 0:
        piece = os.pread(fd, remaining, cursor)
        if not piece:
            return None
        chunks.append(piece)
        remaining -= len(piece)
        cursor += len(piece)
    return b"".join(chunks)


def _code_signature_hash_ranges(fd, s_off, s_size, cmds_end, dataoff, datasize):
    """Return byte intervals for CodeDirectory cryptographic hash arrays in LC_CODE_SIGNATURE."""
    if datasize < 12 or dataoff < cmds_end or dataoff + datasize > s_size:
        return ()
    sig_off = s_off + dataoff
    sb_hdr = _pread_exact(fd, 12, sig_off)
    if not sb_hdr:
        return ()
    sb_magic, sb_len, sb_count = struct.unpack(">III", sb_hdr)
    if (sb_magic != CSMAGIC_EMBEDDED_SIGNATURE or sb_len < 12 or sb_len > datasize
            or not (0 < sb_count <= MAX_CS_BLOBS) or 12 + sb_count * 8 > sb_len):
        return ()
    index_bytes = _pread_exact(fd, sb_count * 8, sig_off + 12)
    if not index_bytes:
        return ()
    ranges = []
    min_blob_off = 12 + sb_count * 8
    for blob_index in range(sb_count):
        _, b_off = struct.unpack_from(">II", index_bytes, blob_index * 8)
        if b_off < min_blob_off or b_off + 8 > sb_len:
            return ()
        cd_abs = sig_off + b_off
        cd_hdr = _pread_exact(fd, min(52, sb_len - b_off), cd_abs)
        if not cd_hdr or len(cd_hdr) < 8:
            return ()
        b_magic, cd_len = struct.unpack_from(">II", cd_hdr, 0)
        if b_magic != CSMAGIC_CODEDIRECTORY:
            continue
        if len(cd_hdr) < 44 or cd_len < 44 or b_off + cd_len > sb_len:
            return ()
        ver, _, hash_off, ident_off, n_special, n_code, _, hash_size, _ = struct.unpack_from(
            ">IIIIIIIBB", cd_hdr, 8
        )
        if not (0x20000 <= ver < 0x30000) or hash_size not in (20, 32, 48, 64):
            return ()
        team_off = struct.unpack_from(">I", cd_hdr, 48)[0] if ver >= 0x20200 and cd_len >= 52 and len(cd_hdr) >= 52 else 0
        hash_rel_start = hash_off - n_special * hash_size
        hash_rel_end = hash_off + n_code * hash_size
        if (hash_rel_start < 44 or not (44 <= ident_off < hash_rel_start)
                or (team_off != 0 and not (44 <= team_off < hash_rel_start))
                or hash_rel_start >= hash_rel_end or hash_rel_end > cd_len):
            return ()
        ranges.append((cd_abs + hash_rel_start, cd_abs + hash_rel_end))
    return tuple(ranges)


def _macho_non_string_ranges(fd, file_size):
    """Return sorted file byte intervals for Mach-O machine instructions and CodeDirectory hash arrays."""
    if file_size < 32:
        return ()
    try:
        top = _pread_exact(fd, 8, 0)
        if not top:
            return ()
        le_magic = struct.unpack("<I", top[:4])[0]
        be_magic = struct.unpack(">I", top[:4])[0]
        slices = []
        if le_magic == MH_MAGIC_64:
            slices.append((0, file_size))
        elif be_magic in (FAT_MAGIC, FAT_MAGIC_64):
            nfat = struct.unpack(">I", top[4:8])[0]
            if not (1 <= nfat <= MAX_FAT_SLICES):
                return ()
            entry_fmt = ">IIQQII" if be_magic == FAT_MAGIC_64 else ">IIIII"
            entry_size = struct.calcsize(entry_fmt)
            table_end = 8 + nfat * entry_size
            if table_end > file_size:
                return ()
            table = _pread_exact(fd, nfat * entry_size, 8)
            if not table:
                return ()
            for index in range(nfat):
                fields = struct.unpack_from(entry_fmt, table, index * entry_size)
                s_off, s_size = fields[2], fields[3]
                if s_off < table_end or s_size < 32 or s_off + s_size > file_size:
                    return ()
                slices.append((s_off, s_size))
        else:
            return ()

        ranges = []
        for s_off, s_size in slices:
            hdr = _pread_exact(fd, 32, s_off)
            if not hdr:
                return ()
            smagic, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack("<IIIIIIII", hdr)
            if smagic != MH_MAGIC_64 or ncmds > MAX_LOAD_COMMANDS or sizeofcmds > MAX_SIZEOF_CMDS:
                return ()
            if 32 + sizeofcmds > s_size:
                return ()
            cmds = _pread_exact(fd, sizeofcmds, s_off + 32)
            if cmds is None:
                return ()
            pos = 0
            for _ in range(ncmds):
                if pos + 8 > sizeofcmds:
                    return ()
                cmd, cmdsize = struct.unpack_from("<II", cmds, pos)
                if cmdsize < 8 or pos + cmdsize > sizeofcmds:
                    return ()
                if cmd == LC_SEGMENT_64 and cmdsize >= 72:
                    nsects = struct.unpack_from("<I", cmds, pos + 64)[0]
                    if 72 + nsects * 80 > cmdsize:
                        return ()
                    for sect_index in range(nsects):
                        sect_pos = pos + 72 + sect_index * 80
                        size, offset, _, _, _, flags = struct.unpack_from("<QIIIII", cmds, sect_pos + 40)
                        if (flags & S_ATTR_PURE_INSTRUCTIONS) and size > 0 and offset + size <= s_size:
                            ranges.append((s_off + offset, s_off + offset + size))
                elif cmd == LC_CODE_SIGNATURE and cmdsize >= 16:
                    dataoff, datasize = struct.unpack_from("<II", cmds, pos + 8)
                    ranges.extend(_code_signature_hash_ranges(fd, s_off, s_size, 32 + sizeofcmds, dataoff, datasize))
                pos += cmdsize
        return tuple(sorted(ranges))
    except OSError:
        return ()


def _raw_instruction_boundary(byte):
    return byte >= 0x80 or byte == 0x7F or (byte < 0x20 and byte not in (0x00, 0x09, 0x0A, 0x0D))


def _email_candidate(text, match):
    domain = match.group(1)
    # Versions and short random binary runs are not Internet mail domains.
    if not re.fullmatch(r"[a-z]{2,63}|xn--[a-z0-9-]{2,59}", domain.rsplit(".", 1)[-1], re.I):
        return False
    if re.fullmatch(r"[123]x\.(?:png|jpe?g|gif|icns|pdf|svg|webp)", domain, re.I):
        return False
    local = match.group().rsplit("@", 1)[0]
    if (local.startswith("//") and local[2:].casefold() in PLACEHOLDER_USERS
            and text[max(0, match.start() - 6):match.start()].endswith(("http:", "https:"))):
        return False
    return True


def _email_scan_data(data, prefix=b"", window_offset=0, instruction_ranges=()):
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
    if instruction_ranges and b"@" in combined:
        comb_offset = window_offset - len(prefix)
        comb_end = comb_offset + len(combined)
        if any(r_end > comb_offset and r_start < comb_end for r_start, r_end in instruction_ranges):
            buf = None
            for match in EMAIL_BYTES.finditer(combined):
                if match.end() - match.start() >= 12 or match.start() == 0 or match.end() == len(combined):
                    continue
                abs_start = comb_offset + match.start()
                abs_end = comb_offset + match.end()
                if not any(r_start <= abs_start and abs_end <= r_end for r_start, r_end in instruction_ranges):
                    continue
                if _raw_instruction_boundary(combined[match.start() - 1]) and _raw_instruction_boundary(combined[match.end()]):
                    if buf is None:
                        buf = bytearray(combined)
                    buf[match.start():match.end()] = b"\0" * (match.end() - match.start())
                    changed = True
            if buf is not None:
                combined = bytes(buf)
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


def _rules_in(data, patterns, license_file, final, email_prefix=b"", window_offset=0, instruction_ranges=()):
    found = set()
    email_data = (
        _email_scan_data(data, email_prefix, window_offset=window_offset, instruction_ranges=instruction_ranges)
        if not license_file else data
    )
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
            bytes_read = 0
            license_file = _license_file(relative)
            instruction_ranges = _macho_non_string_ranges(source.fileno(), before.st_size) if not license_file else ()
            while True:
                tail = carry[-overlap:]
                email_prefix = carry[:-overlap]
                chunk = source.read(CHUNK_SIZE)
                if not chunk:
                    found.update(_rules_in(
                        tail, patterns, license_file, final=True, email_prefix=email_prefix,
                        window_offset=bytes_read - len(tail), instruction_ranges=instruction_ranges,
                    ))
                    break
                window_offset = bytes_read - len(tail)
                bytes_read += len(chunk)
                window = tail + chunk
                found.update(_rules_in(
                    window, patterns, license_file, final=False, email_prefix=email_prefix,
                    window_offset=window_offset, instruction_ranges=instruction_ranges,
                ))
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
