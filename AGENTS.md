# Repository Guidelines

## Project Structure & Module Organization

This repository is a Swift Package for a macOS SwiftUI app, `AWSPlatform`.

- `Package.swift` defines the executable target, macOS 13 minimum, Swift 5.9 tools, and Soto dependencies.
- `Sources/AWSPlatform/App.swift` is the app entry point; `ContentView.swift` hosts the main shell.
- `Sources/AWSPlatform/Models/` contains lightweight domain models for AWS profiles, EC2, Lambda, and S3.
- `Sources/AWSPlatform/Services/` owns AWS client/provider integration.
- `Sources/AWSPlatform/ViewModels/` contains observable UI state.
- `Sources/AWSPlatform/Views/` contains SwiftUI views, grouped by AWS service plus shared shell components.
- `Tests/AWSPlatformTests/` contains config parsing and view model unit tests.
- `docs/superpowers/` contains design specs and implementation planning notes.
- `ROADMAP.md` is the source of truth for current progress and validation status.

Keep non-trivial parsing and view model state transitions covered by the existing test target.

## Build, Test, and Development Commands

```bash
swift build
```
Builds the Swift package and resolves Soto dependencies.

```bash
swift run
```
Builds and launches the macOS app from the command line.

```bash
swift test
```
Runs the package test suite.

```bash
open Package.swift
```
Opens the package in Xcode for interactive SwiftUI development and Cmd+R runs.

## Coding Style & Naming Conventions

Use standard Swift API Design Guidelines: types in `UpperCamelCase`, methods and properties in `lowerCamelCase`, and clear nouns for models/view models. Keep SwiftUI view files focused on composition; move AWS calls and async state into services or view models. Use 4-space indentation, prefer `let` over `var`, and keep service-specific UI inside `Views/<Service>/`.

## Testing Guidelines

When adding tests, create a `Tests/AWSPlatformTests/` target in `Package.swift`. Name test files after the unit under test, such as `ConfigReaderTests.swift`, and use behavior-focused `test...` method names. Prefer unit tests for parsing, model mapping, and view model state transitions. Avoid live AWS calls; inject mock service providers.

## Commit & Pull Request Guidelines

Recent history uses concise messages with either Conventional Commit style (`docs: add README.md...`) or a short imperative summary (`Initial commit: ...`). Continue with messages like `feat: add EC2 refresh action` or `fix: handle missing AWS region`.

Pull requests should include a short description, verification steps (`swift build`, `swift test` when available), screenshots for UI changes, and notes for AWS credential, region, or permission assumptions.

## Security & Configuration Tips

Do not commit AWS credentials, generated local config, or Xcode user state. The app expects AWS CLI profiles in `~/.aws/config` and `~/.aws/credentials`; keep examples sanitized and use profile names rather than secrets in docs and tests.
