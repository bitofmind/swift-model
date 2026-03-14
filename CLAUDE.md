# CLAUDE.md — SwiftModel

This file gives Claude Code the context it needs to work effectively in this repository.

## What is this project?

SwiftModel is a Swift library for composing models that drive SwiftUI views. It uses `@Model` macros, observation tracking, lifetime management (anchors), exhaustive testing tooling (`ModelTester`), dependency injection (via `swift-dependencies`), and async task management.

The library targets Apple platforms (macOS 11+, iOS 14+, tvOS 14+, watchOS 6+) and Linux.

## Repository layout

```
Sources/
  SwiftModel/           # Main library target
    Internal/           # Non-public implementation details
    Testing/            # ModelTester and related test helpers
    SwiftUI/            # SwiftUI-specific code (guarded with #if canImport(SwiftUI))
  SwiftModelMacros/     # @Model macro implementation (SwiftSyntax-based)
Tests/
  SwiftModelTests/      # Main test suite
  SwiftModelMacroTests/ # Macro expansion tests
Examples/               # Standalone example apps (each embeds a copy of the library)
```

## Build & test

```bash
# Build
swift build

# Run all tests
swift test

# Run a specific test
swift test --filter SwiftModelTests.SomeTestName
```

The project uses Swift 6 (`swiftLanguageModes: [.v6]`). All code must be strict-concurrency-safe.

## Key architectural concepts

- **`@Model`** macro: Applied to a struct. Generates `@Observable`-compatible storage, `ModelContainer` conformance, and property access tracking.
- **`ModelAnchor`** / **`withAnchor()`**: Activates a model hierarchy and keeps it alive. `withAnchor()` stores the anchor on `ModelAccess.retainedObject`; `andAnchor()` returns it separately for explicit lifetime control.
- **`Context`**: Internal reference type that backs each live model instance. Holds the lock, dependency overrides, child contexts, and task lifetime.
- **`ModelAccess`**: Base class for all observation/access strategies (SwiftUI's `@Observable`, test access, etc.).
- **`ModelTester`**: Test harness. Wraps a model with `TestAccess` and exhaustively tracks state changes, events, tasks, and probe calls. Create via `model.andTester()`.
- **`ModelOption`**: **Internal** `OptionSet` (not public API). Used only in tests via `@testable import` to enable specific behaviours like `disableObservationRegistrar` or `disableMemoizeCoalescing`.
- **`DebugHook`**: **Internal** task-local hook for routing debug output during testing. Not part of the public API.

## Platform guards

- `#if canImport(SwiftUI)` — gates all SwiftUI-specific code in `Sources/SwiftModel/SwiftUI/`.
- `#if canImport(ObjectiveC)` — gates `ModelNode+UndoManager.swift` (uses `UndoManager`, `NSObject`, `NotificationCenter`) and the ObjC-runtime parts of `_XCTExpectFailure` in `TestUtilties.swift`.
- `NSLock`, `NSRecursiveLock`, `NotificationCenter`, `DispatchQueue`, `NSObject` — all available on Linux via swift-corelibs-foundation/libdispatch; no guard needed.
- `objc_setAssociatedObject`, `NSClassFromString`, `NSSelectorFromString`, `UndoManager` — **not** available on Linux; must be guarded.

## Code style

- Swift 6 strict concurrency throughout.
- PascalCase for types, camelCase for members.
- 4-space indentation.
- No Combine; prefer `async`/`await` and `AsyncStream`.
- Avoid `@unchecked Sendable` except where the locking discipline is manually maintained and documented.
- Internal symbols use no access modifier (defaulting to `internal`). Reserve `public` for the deliberate public API surface.

## Testing conventions

- Test framework: Swift Testing (`import Testing`), not XCTest.
- UI tests: XCUIAutomation.
- Use `model.andTester()` to get a `ModelTester`; call `await tester.assert { }` to consume expected side-effects.
- Macro expansion tests live in `SwiftModelMacroTests/` and use `MacroTesting`.
- Tests that exercise both observation mechanisms pass `options: .disableObservationRegistrar` to the internal `andTester(options:)` overload (requires `@testable import SwiftModel`).

## CI

GitHub Actions (`.github/workflows/ci.yml`):
- **macOS**: `macos-15`, default Xcode, `swift test`.
- **Linux**: `ubuntu-latest`, Swift 6.0 and 6.1 containers, `swift test`.
