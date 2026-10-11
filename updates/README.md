# Application update feeds

This directory contains the public Ed25519 verification key and separate Sparkle appcasts for Apple Silicon and Intel. The signing private key stays in the login Keychain under the dedicated `aws-platform-updates` account. Never export or commit it.

The app reads `appcast-arm64.xml` or `appcast-x86_64.xml` from this repository's public `main` branch over HTTPS. These files start empty; existing installers without Sparkle are not advertised as in-app updates. A release must upload and verify its final signed/notarized ZIP assets before its appcast entry is generated and published. Builds increase monotonically, and each feed references only its own architecture.

Implementation and release commands are documented in [the packaging guide](../scripts/README.md). Do not edit an enclosure URL, size, version or signature independently of its verified installer.
