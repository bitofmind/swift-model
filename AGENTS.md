# AGENTS.md — SwiftModel

Instructions for AI coding agents (and a quick orientation for human
contributors). `CLAUDE.md` imports this file. It's kept short on purpose, and
the deeper notes live in `Docs/Contributing/` (see
[Further reading](#further-reading)). Read those only when your task touches
their area.

## What is this project?

SwiftModel is a Swift library for composing models that drive SwiftUI views. It uses `@Model` macros, observation tracking, lifetime management (anchors), exhaustive testing tooling (`ModelTester`), dependency injection (via `swift-dependencies`), and async task management.

The library targets Apple platforms (macOS 11+, iOS 14+, tvOS 14+, watchOS 6+) and Linux. It also compiles for Android and WASM (build only; CI checks both).

## Repository layout

```
Sources/
  SwiftModel/           # Main library target
    Internal/           # Non-public implementation details
    Testing/            # ModelTester, the .modelTesting trait, expect/settle
    SwiftUI/            # SwiftUI-specific code (guarded with #if canImport(SwiftUI))
    Documentation.docc/ # DocC catalog
  SwiftModelMacros/     # @Model macro implementation (SwiftSyntax-based)
  SwiftModelBenchmarks/ # Release-mode benchmark executable
Tests/
  SwiftModelTests/           # Main test suite (default for regular runs)
  SwiftModelMainActorTests/  # Tests that need a MainActor-isolated module
  SwiftModelSnapshotTests/   # InlineSnapshotTesting-based output / diff tests
  SwiftModelBenchmarkTests/  # Performance benchmarks (skipped from regular runs)
  SwiftModelMacroTests/      # Macro expansion tests (MacroTesting)
Examples/                    # Standalone example apps (each embeds a copy of the library)
Docs/                        # User-facing guides (linked from README)
Docs/Contributing/           # Contributor / agent deep-dives
```

## Build & test

```bash
swift build

# Full suite: --parallel plus CI's --skip set.
scripts/test

# One test (forwards --filter to swift test).
scripts/test --filter SwiftModelTests.SomeTestName

# Stress loop. Use after touching observation / coalescing / settling code.
scripts/test --loop 100

# Reproduce CI's serial job (for CI-only failures).
scripts/test --no-parallel
```

CI runs both `--parallel` and `--no-parallel` on macOS and Linux, and both
are required. Serial is the deterministic regression gate; parallel checks the
framework's claim that tests can run in parallel. See
[Docs/Contributing/CI.md](Docs/Contributing/CI.md).

`swift-tools-version` is 6.1 and the language mode is Swift 6. All code must be
strict-concurrency-safe.

Macro tests only build for the macOS host. In Xcode with a simulator
destination they show as *disabled*, which is expected and not a failure.

## Key architectural concepts

- **`@Model`** macro: Applied to a struct. Generates `@Observable`-compatible storage, `ModelContainer` conformance, and property access tracking.
- **`ModelAnchor`** / **`withAnchor()`**: Activates a model hierarchy and keeps it alive. `withAnchor()` stores the anchor on `ModelAccess.retainedObject`; `returningAnchor()` returns it separately for explicit lifetime control.
- **`Context`**: Internal reference type that backs each live model instance. Holds the lock, dependency overrides, child contexts, and task lifetime.
- **`ModelAccess`**: Base class for all observation/access strategies (SwiftUI's `@Observable`, test access, etc.).
- **`ModelTester`**: Test harness. Wraps a model with `TestAccess` and exhaustively tracks state changes, events, tasks, and probe calls. Created via `ModelTester(model, ...)` (requires `@testable import`) or anchored via `withAnchor()` inside `@Test(.modelTesting)` (public API).
- **`ModelOption`**: **Internal** `OptionSet` (not public API). Used only in tests via `@testable import` to enable specific behaviours like `disableObservationRegistrar` or `disableMemoizeCoalescing`.

Tracked property reads are the hot path (~0.5–1 μs each, even in Release).
Before changing accessors, `Context` read/write paths or observation
registration, read
[Docs/Contributing/ReadPathPerformance.md](Docs/Contributing/ReadPathPerformance.md).

## Platform guards

- `#if canImport(SwiftUI)`: gates all SwiftUI-specific code in `Sources/SwiftModel/SwiftUI/`.
- `#if canImport(ObjectiveC)`: gates `ModelNode+UndoManager.swift` (`UndoManager`, `NSObject`, `NotificationCenter`).
- `#if canImport(Combine)`: gates `Sources/SwiftModel/Combine/` (interop extensions only).
- `NSLock`, `NSRecursiveLock`, `NotificationCenter`, `DispatchQueue` and `NSObject` are available on Linux via swift-corelibs-foundation/libdispatch, so they need no guard.
- `objc_setAssociatedObject`, `NSClassFromString`, `NSSelectorFromString` and `UndoManager` are **not** available on Linux and must be guarded.

## Code style

- Swift 6 strict concurrency throughout.
- PascalCase for types, camelCase for members.
- 4-space indentation.
- No Combine in the core; prefer `async`/`await` and `AsyncStream`. (The `Combine/` folder is opt-in interop only.)
- Avoid `@unchecked Sendable` except where the locking discipline is manually maintained and documented.
- Internal symbols use no access modifier (defaulting to `internal`). Reserve `public` for the deliberate public API surface.
- **Never introduce new compiler warnings.** The build must remain warning-free.

## Testing conventions

Use Swift Testing (`import Testing`), not XCTest.

### Preferred pattern: `@Test(.modelTesting)`

Use `.modelTesting` + `model.withAnchor()` + `expect { }` / `require(_:)`, for
both example tests and internal `@testable import` tests.

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

- **`expect { }`** is the assertion verb. It is purely reactive: it resolves the
  moment the predicate first becomes true, and wakes on `@Model` writes,
  `node.send(...)` events and `TestProbe` calls. Use it for a state that a user
  action reaches directly.
- **`settle()` / `settle { … }`** is the phase-and-chain verb. It waits until the
  model is quiet (and, if given, the predicate holds), *then* resets exhaustivity
  tracking. `settle(resetting: .off)` waits without resetting. Use it when an
  action starts an async chain the *next* line depends on: `expect` can resolve
  on the initial state before that chain has run. Example:
  `Examples/Onboarding/OnboardingTests/OnboardingTests.swift:sendsEventOnValidUsername`.
  Also use `settle()` after `withAnchor()` to get past activation side effects,
  and before `TestClock.advance` so the consumer's `clock.sleep` is registered first.
- **`.modelTesting(.adding(.transitions))`** (per suite) makes `expect` match the
  recorded sequence of writes instead of the live value. Use it when the
  initial state already satisfies the predicate and you want the real transition.
- **`waitUntil(condition)`** (`Tests/SwiftModelTests/Utilities.swift`) polls
  explicitly. It is only for framework-internal tests whose predicates read
  off-model state (`TestResult`, `LockIsolated`). Never pass a `timeout:`
  shorter than the 5 s default.
- `@Suite(.modelTesting(exhaustivity: .off))` for suites that use `#expect`
  directly; opt individual tests back in with `@Test(.modelTesting(exhaustivity: .preference))`.
- Tests covering both observation mechanisms use `options: [.disableObservationRegistrar]` in `withAnchor(options:)`.
- The trait caps each test at 30 s (`[TRAIT timeout]`). `SWIFT_MODEL_TIMEOUT_SCALE`
  multiplies every test-infra timeout (CI uses 3, TSan uses 6).

Using `ModelTester` directly is reserved for post-deallocation tests and for
testing the test framework itself. For that, and for timeouts, the
`GlobalTickScheduler`, the executor drive and the known load-sensitive tests,
read [Docs/Contributing/TestInfrastructure.md](Docs/Contributing/TestInfrastructure.md).
**Never fix a flaky test by raising a timeout.** Test-infra verdicts must be
based on evidence and progress, not wall-clock time.

## Pull requests

- Every PR that changes the library adds its entries under `## [Unreleased]` in
  `CHANGELOG.md`, so a release only has to stamp that section.
- Run `scripts/test` (and `--no-parallel` for anything touching
  observation or settling) before pushing.

## Further reading

| File | Read when |
|---|---|
| [Docs/Contributing/ReadPathPerformance.md](Docs/Contributing/ReadPathPerformance.md) | Touching accessors, `Context`, observation registration, `withUntrackedModelReads`, benchmarks |
| [Docs/Contributing/TestInfrastructure.md](Docs/Contributing/TestInfrastructure.md) | Touching `Sources/SwiftModel/Testing/`, writing lifecycle tests, investigating a flaky or timing-out test |
| [Docs/Contributing/CI.md](Docs/Contributing/CI.md) | A CI job fails, or changing the workflow, platform conditions or `scripts/ci-test` |
| [Docs/Contributing/Releasing.md](Docs/Contributing/Releasing.md) | Cutting a release |
| [Docs/test-determinism-executor-drain.md](Docs/test-determinism-executor-drain.md) | Deep history of the executor-drive test design |
