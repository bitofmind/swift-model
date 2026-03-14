# Contributing to SwiftModel

Thank you for your interest in contributing!

## Getting started

1. Fork the repository and clone your fork.
2. Open `swift-model.xcworkspace` in Xcode, or work from the command line with `swift build` / `swift test`.
3. Create a branch for your change: `git checkout -b my-feature`.

## Requirements

- Swift 6 / Xcode 16 or later.
- All code must compile with strict concurrency (`swiftLanguageModes: [.v6]`).
- Changes must build and pass tests on both macOS and Linux.

## Making changes

- Keep changes focused. One logical change per pull request.
- Follow the existing code style (4-space indentation, PascalCase types, camelCase members).
- Do not add public API that is not yet needed. The library is pre-1.0 and the public surface is intentionally kept small.
- Internal symbols use no access modifier (defaulting to `internal`). Only add `public` when deliberately extending the public API.
- Avoid Combine; use `async`/`await` and `AsyncStream`.
- Platform compatibility: Apple-platform-only APIs (`UndoManager`, `objc_setAssociatedObject`, etc.) must be guarded with `#if canImport(ObjectiveC)`. SwiftUI-only code with `#if canImport(SwiftUI)`.

## Running tests

```bash
swift test
```

Tests use the Swift Testing framework (`import Testing`). Macro expansion tests are in `SwiftModelMacroTests/`.

## Pull requests

- Target the `main` branch.
- Include a short description of what changed and why.
- Ensure CI passes (macOS + Linux).
- For significant changes, open an issue first to discuss the approach.

## Reporting issues

Please open a GitHub issue with a minimal reproduction case.
