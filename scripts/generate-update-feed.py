#!/usr/bin/env python3
"""Generate a Sparkle appcast only after the final ZIP is publicly downloadable."""

import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("distribution", ROOT / "scripts/package-distribution.py")
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)
updates = distribution.updates
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def field(name):
    return "{" + SPARKLE + "}" + name


class HTTPSRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith("https://"):
            raise ValueError("Update download redirected outside HTTPS")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def verify_public_download(url, archive):
    digest = hashlib.sha256()
    size = 0
    expected_size = archive.stat().st_size
    opener = urllib.request.build_opener(HTTPSRedirects())
    request = urllib.request.Request(url, headers={"User-Agent": "AWSPlatform-release-verifier"})
    with opener.open(request, timeout=30) as response:
        for chunk in iter(lambda: response.read(1024 * 1024), b""):
            size += len(chunk)
            if size > expected_size:
                raise ValueError("Published archive is larger than the verified local archive")
            digest.update(chunk)
    if size != expected_size or digest.hexdigest() != distribution.sha256(archive):
        raise ValueError("Published archive does not match the verified local archive")


def verify_zip(archive, manifest, architecture, stage):
    # Reject archive paths or symlinks that could escape the isolated staging directory.
    with zipfile.ZipFile(archive) as source:
        total = 0
        for entry in source.infolist():
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != "AWSPlatform.app":
                raise ValueError("Unsafe update archive path")
            total += entry.file_size
            if total > 512 * 1024 * 1024 or len(source.infolist()) > 20000:
                raise ValueError("Update archive exceeds verification limits")
            if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                target = PurePosixPath(source.read(entry).decode())
                if target.is_absolute() or ".." in target.parts:
                    raise ValueError("Unsafe update archive symlink")
    distribution.run("ditto", "-x", "-k", archive, stage)
    app = stage / "AWSPlatform.app"
    distribution.verify_bundle(app, architecture, manifest["version"], manifest["build"])
    distribution.verify_signature(app, manifest["teamID"], runtime=True)
    for component in updates.COMPONENTS:
        distribution.verify_signature(updates.framework_path(app) / component, manifest["teamID"], runtime=True)
    distribution.run("xcrun", "stapler", "validate", app, capture=True)
    distribution.run("spctl", "--assess", "--type", "execute", app, capture=True)


def generate(directory, output):
    manifest = json.loads((directory / "distribution.json").read_text())
    architectures = manifest["architectures"]
    if architectures not in (["arm64"], ["x86_64"]):
        raise ValueError("Update feeds require a separate single-architecture distribution")
    architecture = architectures[0]
    version, build = manifest["version"], manifest["build"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Invalid update version or build")
    if manifest.get("bundleID") != "AWSPlatform" or manifest.get("minimumMacOS") != "13.0":
        raise ValueError("Invalid application identity or minimum system")
    if not re.fullmatch(r"[A-Z0-9]{10}", manifest["teamID"]):
        raise ValueError("Invalid Developer ID team")
    if manifest["appNotarization"].get("status") != "Accepted":
        raise ValueError("Only notarized updates may be advertised")
    archive = directory / f"AWSPlatform-{version}-{architecture}.zip"
    signature = manifest["sparkle"]
    if signature["publicKey"] != updates.public_key() or signature["feedURL"] != updates.feed_url(architecture):
        raise ValueError("Update key or feed differs from the application")
    if archive.stat().st_size != signature["length"] or distribution.sha256(archive) != manifest["sha256"][archive.name]:
        raise ValueError("Update archive changed after distribution signing")
    updates.verify_archive(archive, signature["edSignature"], distribution.run)
    previous = ROOT / "updates" / f"appcast-{architecture}.xml"
    tree = ET.parse(previous)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise ValueError("Missing appcast channel")
    for item in channel.findall("item"):
        old_build = item.findtext(field("version"))
        if old_build is None or not old_build.isdigit() or int(old_build) >= int(build):
            raise ValueError("Update build must increase monotonically")
        old_version = item.findtext(field("shortVersionString"))
        if old_version is None or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", old_version):
            raise ValueError("Existing feed contains an invalid release version")
        if tuple(map(int, old_version.split("."))) > tuple(map(int, version.split("."))):
            raise ValueError("Update release version must not decrease")
    url = f"https://github.com/maydaychen/aws-platform/releases/download/v{version}/{archive.name}"
    temporary = ROOT / ".tmp/update-feed"
    temporary.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=temporary) as stage:
        verify_zip(archive, manifest, architecture, Path(stage))
        verify_public_download(url, archive)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"AWSPlatform {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, field("version")).text = build
    ET.SubElement(item, field("shortVersionString")).text = version
    ET.SubElement(item, field("minimumSystemVersion")).text = "13.0"
    ET.SubElement(item, "link").text = f"https://github.com/maydaychen/aws-platform/releases/tag/v{version}"
    ET.SubElement(item, "enclosure", url=url, length=str(signature["length"]),
                  type="application/octet-stream", **{field("edSignature"): signature["edSignature"]})
    channel.insert(0, item)
    ET.indent(tree, space="  ")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, suffix=".xml", delete=False) as candidate:
        candidate_path = Path(candidate.name)
    try:
        tree.write(candidate_path, encoding="utf-8", xml_declaration=True)
        updates.sign_feed(candidate_path, distribution.run)
        candidate_path.replace(output)
    finally:
        candidate_path.unlink(missing_ok=True)
    return architecture


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("distribution", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        architecture = generate(args.distribution, args.output)
        print(f"Verified {architecture} update feed generated; review and publish it separately")
    except (ValueError, RuntimeError, OSError, KeyError, ET.ParseError) as error:
        parser.exit(1, f"Update feed generation stopped: {type(error).__name__}\n")
