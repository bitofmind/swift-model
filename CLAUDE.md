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
  SwiftModelTests/           # Main test suite (default for regular runs)
  SwiftModelSnapshotTests/   # InlineSnapshotTesting-based output / diff tests
  SwiftModelBenchmarkTests/  # Performance benchmarks (skipped from regular runs)
  SwiftModelMacroTests/      # Macro expansion tests
Examples/                    # Standalone example apps (each embeds a copy of the library)
```

## Build & test

```bash
# Build
swift build

# Run all tests — `scripts/test` defaults to `--parallel` (unbounded) plus the
# `--skip` set used in CI. Use this locally where the machine has cores to
# spare; it's also what stress-tests cross-test scheduling diversity for
# race-finding purposes.
scripts/test

# Run a specific test (forwards `--filter` to swift-test).
scripts/test --filter SwiftModelTests.SomeTestName

# Stress loop — run the full suite N times, summarising any failures. Use to
# verify test stability after touching observation/coalescing/settling code.
scripts/test --loop 100

# Reproduce CI's exact serial run (use when investigating a CI-only failure):
scripts/test --no-parallel
```

CI runs **both** `--parallel` and `--no-parallel` on macOS and Linux as a
matrix. The parallel job validates the framework's parallel-test claim
(a real differentiator vs. e.g. TCA's enforced `@MainActor`); the serial
job is the deterministic regression gate that has historically caught
serialization-only races (e.g. the OR-path race fixed in 497c2ab).
Settle's `.deferential` priority + 25 s budget (just under the 30 s trait
cap) gives the parallel job enough headroom to absorb cooperative-pool
saturation on the small 2–3 core CI runners. See the macOS-job comment in
`.github/workflows/ci.yml` for the full story.

The project uses Swift 6 (`swiftLanguageModes: [.v6]`). All code must be strict-concurrency-safe.

## Key architectural concepts

- **`@Model`** macro: Applied to a struct. Generates `@Observable`-compatible storage, `ModelContainer` conformance, and property access tracking.
- **`ModelAnchor`** / **`withAnchor()`**: Activates a model hierarchy and keeps it alive. `withAnchor()` stores the anchor on `ModelAccess.retainedObject`; `returningAnchor()` returns it separately for explicit lifetime control.
- **`Context`**: Internal reference type that backs each live model instance. Holds the lock, dependency overrides, child contexts, and task lifetime.
- **`ModelAccess`**: Base class for all observation/access strategies (SwiftUI's `@Observable`, test access, etc.).
- **`ModelTester`**: Test harness. Wraps a model with `TestAccess` and exhaustively tracks state changes, events, tasks, and probe calls. Created via `ModelTester(model, ...)` (requires `@testable import`) or anchored via `withAnchor()` inside `@Test(.modelTesting)` (public API).
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

- `expect { }` waits for all predicates to become true, similar to `assertNow`. **Reactive only** — wakes on `@Model` writes, `node.send(...)` events, and `TestProbe` calls. Predicates that read state *outside* the reactive system (e.g. a `LockIsolated` counter mutated from a `forEach` callback) will not wake `expect` and should use `waitUntil` (see below).
- `settle()` waits for the model to be quiet for a short debounce window (50 ms in-test), then resets exhaustivity. Use after `withAnchor()` to skip past activation side effects. Supports `resetting:` for selective category reset (e.g., `settle(resetting: .full.removing(.events)) { ... }`).
- `waitUntil(condition)` (in `Tests/SwiftModelTests/Utilities.swift`) is the **explicit polling** helper for framework-internal lifecycle tests whose predicates read `TestResult` / `LockIsolated` state. Not appropriate in typical user tests — use `expect` / `require` / `settle` instead.
- Per-suite exhaustivity: `@Suite(.modelTesting(exhaustivity: .off))` when individual tests use `#expect` directly (bypasses exhaustivity). Opt specific tests back in with `@Test(.modelTesting(exhaustivity: .preference))`.
- Tests that exercise both observation mechanisms use `options: [.disableObservationRegistrar]` inside `withAnchor(options:)`.
- A per-test 30 s wall-clock cap is enforced by the `.modelTesting` trait. Hangs surface as `[TRAIT timeout]` rather than freezing CI. Override per-process via the `SWIFT_MODEL_TEST_TIMEOUT` env var (seconds, float).

### `ModelTester` directly — only for specific cases

Direct use of `ModelTester(model, ...)` (requires `@testable import SwiftModel`) is reserved for two scenarios:

1. **Post-deallocation verification**: Tests that need the model to actually be released to observe lifecycle behavior — teardown logs (`"d:tag"`), `onCancel` callbacks, stream termination. `@Suite(.modelTesting)` holds a strong reference for the full test duration, preventing deallocation. Use the `waitUntilRemoved` pattern with `withAnchor()`:

   ```swift
   // Do NOT put this in @Suite(.modelTesting) — it would hold the context alive.
   struct MyLifetimeTests {
       @Test func testTeardown() async {
           let testResult = TestResult()
           await waitUntilRemoved {
               MyModel().withAnchor {
                   $0.testResult = testResult
               }
           }
           // Assert post-deallocation behavior
           #expect(testResult.value.contains("d:tag"))
       }
   }
   ```

   Files currently in this category: `UniquelyReferencedTests`, `ModelDependencyTests`, `ModelDependencyBehaviourTests`, `ObserveAnyModificationLifetimeTests`.

2. **Testing the testing framework itself**: `OutputSnapshotTests` uses `withModelTesting` + `assertIssueSnapshot` to capture and snapshot the failure messages produced by the framework. The `didSendOnUnanchoredModel` test requires direct access to `TestAccess.TesterAssertContext` internals.

### `GlobalTickScheduler` (GTS) — settle's deadline source

`Sources/SwiftModel/Internal/GlobalTickScheduler.swift` is the GCD-backed deadline scheduler that every wait primitive (`expect`, `settle`, `waitUntil`, the per-test trait cap) routes through. Key design points worth knowing before touching it:

- **One-shot timer source, not periodic.** The timer is armed for the soonest pending deadline; after each fire it re-arms to the next-soonest, or stops if no deadlines remain. Zero idle CPU; natural coalescing when many deadlines cluster within tens of ms.
- **Timer fires at `.userInitiated` QoS** so deadlines surface promptly regardless of cooperative-pool load.
- **Per-callback execution priority.** Each scheduled entry carries a `CallbackPriority`:
  - `.responsive` (default) — callback runs inline on the timer's `.userInitiated` GCD queue. Used for the 30 s trait cap and polling (`waitUntil`) where firing-close-to-deadline is the contract.
  - `.deferential` — callback hops to `DispatchQueue.global(qos: .background)` before executing. Used by **in-test** settle's quiet-window check AND by `expect`'s 25 s budget callback. In both cases, the failure signal should only fire once higher-priority cooperative-pool work has drained — otherwise we'd declare "stuck" based on wall-clock without consulting the scheduler signal we built the mechanism to listen for. Under parallel test execution, fast-fail on wall-clock provides no benefit (the test slot would have been busy with other tests' work regardless), so deferring to `.background` is strictly an improvement. Predicate evaluation itself stays inline on every `_noteActivity`, so the happy-path latency is unchanged.
- **Cleanup settle uses `.responsive`** — by the time `checkExhaustion` runs, `cancelAllRecursively` has torn down active tasks and the 200 ms cleanup window absorbs cancel-handler writes naturally. Deferring here would stall every test's teardown behind the `.background` queue's drain cadence, producing visible test-bunching clusters.
- **No load-aware scaling, no multipliers.** `GTS` doesn't track or apply a `load_factor`. Adaptation under load lives entirely in the OS scheduler's QoS prioritisation of `.background` work. This is deliberate — earlier iterations with scaling caused either feedback loops (2024 "congestion debt") or fragile one-spike-pins-a-deadline-for-seconds patterns.
- **Diagnostic tracing**: set `SWIFT_MODEL_GTS_TRACE=1` to write per-event logs to `/tmp/swift-model-gts-trace.log` and `/tmp/swift-model-settle-trace.log`. Tags every `schedule`, `armTimer`, `fire`, `_quietDeadline` call with absolute monotonic-ns timestamps for correlating settle latency with GTS scheduling.

### Known load-sensitive tests under extreme parallel stress

The full suite is **clean on both serial and parallel CI**, and clean on local sub-x100 parallel runs. A small set of tests can flake at extreme parallel stress on a developer machine (x1000+) — typically because the test asserts a timing property that depends on the cooperative pool's scheduling cadence, which we don't control. None block CI.

The 25 s `settleTotalBudgetNs` (bumped from 5 s when the dual-mode CI matrix landed) absorbs most of these under reasonable load — settle's `.deferential` priority gets enough wall-clock to actually let the cooperative pool drain before the wait fails. The remaining flake surface is tests whose assertion runs *after* settle returns and reads state set by an `ImmediateClock` / `onActivate` task that hasn't been given a pool slot yet:

  • `ClockTests.testImmediateClock` — `await expect(model.secondsElapsed > 0)` against an `ImmediateClock`-driven timer.
  • `ChildActivationTaskTests.childTasksCompleteBeforeTeardown` — `await expect(parent.items.allSatisfy { $0.loaded })` where each child's `onActivate` task sets `loaded = true` after an `ImmediateClock` sleep.
  • `MemoizeDirtyObservationTests.testDirtyPathWithOnModifyCallback` — `#expect(updateCount.value >= 1)` after a 5 s poll for a memoize-coalesced `performUpdate` to fire its `onModify` callback.
  • `SearchTests.toggleExpanded` (Examples/Search) — rare flake where an `onActivate` task's write to `detailLine` lands after settle's quiet window.

When investigating new load flakes, check first whether the test matches this pattern (cooperative-pool-scheduled async work + reactive `expect` / wall-clock poll budget) before chasing a library bug.

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
- **macOS** (matrix: `parallel` | `serial`): `macos-15`, default Xcode, `swift test`.
- **Linux** (matrix: `parallel` | `serial`): `ubuntu-latest`, `swift:6.3.0` container, `swift test`.
- **Android**: compile-only cross-compile to `aarch64-unknown-linux-android28`.
- **WASM**: compile-only build to `wasm32-unknown-wasip1`.

Both `parallel` and `serial` test modes run for macOS and Linux. Parallel
validates the framework's parallel-test claim; serial is the deterministic
regression gate (caught the OR-path race fixed in 497c2ab). `fail-fast: false`
on the matrices so one mode's flake doesn't suppress the other's signal.

`swift-tools-version` is **6.1** — minimum required for the `traits:` parameter
on `.package(...)`, used by the `swift-custom-dump` fork dependency. Pre-6.1
Swift toolchains can't read this manifest.
