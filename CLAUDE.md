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
- **`ModelTester`**: Test harness. Wraps a model with `TestAccess` and exhaustively tracks state changes, events, tasks, and probe calls. Create via `model.andTester(options:)` (internal, requires `@testable import`) or use `withAnchor()` inside `@Test(.modelTesting)` (public API).
- **`ModelOption`**: **Internal** `OptionSet` (not public API). Used only in tests via `@testable import` to enable specific behaviours like `disableObservationRegistrar` or `disableMemoizeCoalescing`.
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
- **Never introduce new compiler warnings.** The build must remain warning-free. Fix any warnings introduced by your changes before committing.

## Testing conventions

- Test framework: Swift Testing (`import Testing`), not XCTest.
- UI tests: XCUIAutomation.
- Macro expansion tests live in `SwiftModelMacroTests/` and use `MacroTesting`.

### Preferred pattern — `@Test(.modelTesting)` (most tests)

Use `@Test(.modelTesting)` + `model.withAnchor()` + `expect { }` / `require(_:)`. This applies to both example tests and internal `@testable import` tests.

```swift
@Suite(.modelTesting)
struct MyTests {
    @Test func testSomething() async {
        let model = MyModel().withAnchor()
        model.doSomething()
        await expect(model.value == "expected")
    }
}
```

- `expect { }` waits for all predicates to become true, similar to `assertNow`.
- `settle()` waits for activation tasks, runs an idle cycle, then resets exhaustivity. Use after `withAnchor()` to skip past activation side effects. Supports `resetting:` for selective category reset (e.g., `settle(resetting: .full.removing(.events)) { ... }`).
- Per-suite exhaustivity: `@Suite(.modelTesting(exhaustivity: .off))` when individual tests use `#expect` directly (bypasses exhaustivity). Opt specific tests back in with `@Test(.modelTesting(exhaustivity: .preference))`.
- Tests that exercise both observation mechanisms use `options: [.disableObservationRegistrar]` inside `withAnchor(options:)`.

### `andTester` — only for specific cases

`andTester(options:)` (requires `@testable import SwiftModel`) is reserved for two scenarios:

1. **Post-deallocation verification**: Tests that need the model to actually be released to observe lifecycle behavior — teardown logs (`"d:tag"`), `onCancel` callbacks, stream termination. `@Suite(.modelTesting)` holds a strong reference for the full test duration, preventing deallocation. Use the `waitUntilRemoved` pattern:

   ```swift
   // Do NOT put this in @Suite(.modelTesting) — it would hold the context alive.
   struct MyLifetimeTests {
       @Test func testTeardown() async {
           let testResult = TestResult()
           await waitUntilRemoved {
               let (model, _) = MyModel().andTester(options: [], withDependencies: {
                   $0.testResult = testResult
               })
               return model
           }
           // Assert post-deallocation behavior
           #expect(testResult.value.contains("d:tag"))
       }
   }
   ```

   Files currently in this category: `UniquelyReferencedTests`, `ModelDependencyTests`, `ModelDependencyBehaviourTests`, `ObserveAnyModificationLifetimeTests`.

2. **Testing the testing framework itself**: `OutputSnapshotTests` uses `withModelTesting` + `assertIssueSnapshot` to capture and snapshot the failure messages produced by the framework. The `didSendOnUnanchoredModel` test requires direct access to `TestAccess.TesterAssertContext` internals.

## Building and testing with MCP

**ALWAYS use the xcode-tools MCP server for building and running tests. Never fall back to `swift build` or `swift test` in Bash.**

- Use `BuildProject` to build.
- Use `RunAllTests` to run the full suite, or `RunSomeTests` for specific tests.
- **If a test target returns 0 results, it means it failed to compile — immediately call `GetBuildLog` to see the errors.**

### Reading test output

`print()` output is not in `results`, but `RunSomeTests` returns a `fullConsoleLogsPath` — read that file to see all stdout. To surface a value inline without an extra file read, call `reportIssue("message")`: the message appears directly in `errorMessages` (test will be marked Failed). File-based logging to `/tmp` offers no advantage over `print()` + `fullConsoleLogsPath` and should be avoided.

### Macro tests and destination

`SwiftModelMacroTests` depends on `SwiftModelMacros`, which is a `.macro` target (a compiler plugin that only builds for the macOS host). When Xcode's active test destination is an iOS/tvOS/watchOS simulator, Xcode cannot build the test target for that platform and marks all 17 macro tests as **disabled** — this is expected. The tests run normally when:

- The destination is **macOS**, or
- Tests are run via the **`swift test` CLI** (always targets the host).

Do not treat disabled macro tests as a failure when the destination is a simulator.

## CI

GitHub Actions (`.github/workflows/ci.yml`):
- **macOS**: `macos-15`, default Xcode, `swift test`.
- **Linux**: `ubuntu-latest`, Swift 6.0 and 6.1 containers, `swift test`.
