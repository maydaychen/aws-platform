# Binary distribution license supplements

This directory contains complete upstream license texts missing from the vendored Swift Package files, plus a Swift runtime license reference. It contains no dependency source code or credentials. `collect-licenses.py` copies these files into the application together with license materials from the pinned checkouts.

- `sources.json` records each fixed upstream URL, SHA-256, and applicable `Package.resolved` revision. The collector fails if a pinned dependency changes or a snapshot checksum differs; review the updated upstream materials before updating this manifest.
- `swift-nio-cpp-magic.txt` is the uSHET license at the revision identified by SwiftNIO's `cpp_magic.h`. It retains both licenses included in the original file.
- `swift-nio-ssl-boringssl.txt` and `swift-crypto-boringssl.txt` are the distinct BoringSSL licenses at the exact revisions recorded in each package's vendored `hash.txt`.
- `swift-runtime-reference.txt` is the official `swift-6.2-RELEASE` license, including the Runtime Library Exception. It is an upstream reference, not a claim that the installed Apple toolchain was built from that tag. The collector also includes the installed Xcode's original `Acknowledgments.pdf`, which supplies Apple's Swift attribution, and records toolchain and runtime provenance.

Root package licenses, nested standalone licenses, and leading source copyright/license comments are collected locally. The source-header inventory is deliberately broader than the final link graph; no application feature is inferred from a component's inclusion here. When dependencies change, also inspect their NOTICE files and vendored source directories for new components that require a supplement.
