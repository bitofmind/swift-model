# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased] — Exhaustivity Improvements + Convenience Helpers

### Added
- **`node.task(id:)`** — cancel-in-flight convenience. `node.task(id: query) { q in … }` restarts the async task whenever the expression changes and cancels the in-flight task first. Equivalent to `node.task { node.forEach(Observed { query }) { q in … } }` but more concise.
- **`node.onChange(of:)`** — lightweight helper to react to a value change without a full `forEach` loop.
- **Transitions exhaustivity** — new `Exhaustivity.transitions` category. When a `@Model` enum switches cases, the test framework tracks the transition and fails if it goes unasserted, just like state and event exhaustivity. Transitions within a transaction are grouped as a single update.
- **Private property exclusion from exhaustivity** — `private var` and `fileprivate var` properties are automatically excluded from exhaustivity tracking. Tests no longer fail for internal state that the test cannot observe. `private(set) var` (public getter) is still tracked normally.
- **`@ModelDependency(\.continuousClock) var clock: any Clock<Duration>`** — alternative property-wrapper form to `node.clock` for consistency with the general `@ModelDependency` pattern.
- Additional compile-time diagnostics in the `@Model` macro for common misuse patterns.

### Changed
- **`DebugOptions` API** — improved syntax for `model.withDebug(…)` / `model.debug(…)` options. Options are now more composable and self-documenting.
- **State not exhausted error messages** — failure messages now show a structured diff of the unexpected state changes instead of a raw description.
- **Exhaustivity type** — simplified option-set API; redundant overloads removed.
- **`swift-async-algorithms` removed from library target** — internal `eraseToStream()` and `removeDuplicates()` helpers replace the package dependency. `swift-async-algorithms` is kept as a test-only dependency (`AsyncChannel` is used in a small number of test files).
- **Pre-Swift 6.1 guard on `@Test(.modelTesting)`** — using `.modelTesting` on Swift 6.0 now calls `reportIssue` with a clear migration hint to `withModelTesting { }` instead of failing silently.

### Fixed
- **Deadlock in test infrastructure** — `invokeDidModify` now returns a `(() -> Void)?` callback that callers invoke *after* releasing the lock. Combined with per-test `BackgroundCallQueue` isolation (via `_BackgroundCallLocals` task-local), this eliminates a class of deadlock that could occur when multiple tests ran concurrently.
- **Exhaustivity tracking races** — each `@Test(.modelTesting)` test now receives an isolated `BackgroundCallQueue`, preventing exhaustivity assertions from leaking between concurrent tests.

### Performance
- `@inlinable` annotations added to hot paths in the observation and context subsystems.

### Documentation
- README restructured into a ~200-line landing page. Full reference content lives in `Docs/` subdocuments: `Models.md`, `Lifecycle.md`, `Events.md`, `Dependencies.md`, `Navigation.md`, `HierarchyAndPreferences.md`, `Testing.md`, `Undo.md`, `Debugging.md`, `TransitionsDesign.md`.

---

## [0.13.0] — Context Storage API Split + Named Tasks + Settle API

### Added
- **Named tasks** — `node.task` and `node.forEach` now accept an optional `_ name: String? = nil` parameter. When provided, the name is passed to Swift's `Task(name:)` and surfaced in test exhaustion failure messages so it's immediately clear which task was still running. When omitted, a name is synthesised automatically from the call site: `"onActivate() @ Counter.swift:42"`.
- **`forEach` unhandled error reporting** — when `catch:` is omitted from `node.forEach` and the upstream sequence throws (or the operation throws with `abortIfOperationThrows: true`), `reportIssue` is called at the call site. In test mode this fails the test; in debug production builds it triggers an `assertionFailure`. Per-element errors with `abortIfOperationThrows: false` (the default) remain intentionally swallowed as before.
- **`node.local`** — new accessor for node-private storage. Reads and writes are isolated to the node; descendants do not inherit the value.
- **`node.environment`** — new accessor for top-down propagating storage. Writes are visible to all descendants (equivalent to the old `.environment` propagation).
- **`LocalKeys` / `LocalStorage`** — namespace and descriptor type for declaring node-private storage keys.
- **`EnvironmentKeys` / `EnvironmentStorage`** — namespace and descriptor type for declaring top-down propagating storage keys.
- **`node.removeLocal(_:)`** — removes a local storage value back to default.
- **`node.removeEnvironment(_:)`** — removes a local override, causing the node to inherit from its nearest ancestor again.
- **`Exhaustivity.environment`** — new exhaustivity category for `node.environment` writes (separate from `.local`).
- **`settle()` function** — standalone function that waits for activation tasks to enter their body, runs an idle cycle until no state changes occur, then resets the exhaustivity baseline. Four overloads: builder, no-predicate, `Bool` autoclosure, and `TestPredicate`.
- **`settle(resetting:)` parameter** — controls which exhaustivity categories are reset after settling. Accepts an `Exhaustivity` value (default `.full`). Use `resetting: .full.removing(.events)` to keep tracking events across the settle boundary. Categories: `.state`, `.events`, `.tasks`, `.probes`, `.local`, `.environment`, `.preference`.
- **Rich settle timeout diagnostics** — when settle times out, the failure message now includes details about which activation tasks are still running, pending state changes, and the current model state.

### Deprecated
- **`node.context`** — use `node.local` or `node.environment` depending on the desired propagation.
- **`node.removeContext(_:)`** — use `node.removeLocal(_:)` or `node.removeEnvironment(_:)`.
- **`ContextKeys` / `ContextValues`** — use `LocalKeys` / `LocalStorage` or `EnvironmentKeys` / `EnvironmentStorage`.
- **`Exhaustivity.context`** — use `[.local, .environment]` to cover both, or target one specifically.
- **`timeoutNanoseconds` on `expect`/`require`/`tester.assert`** — timeout is no longer needed. The framework uses activity-relative idle detection with a fixed 5-second hard cap instead of user-configurable timeouts.

### Changed
- Debug trigger output now shows `ModelType.local.keyName` / `ModelType.environment.keyName` instead of the generic `ModelType.context.keyName`.
- Exhaustion failure messages now say "Local not exhausted" / "Environment not exhausted" instead of "Context not exhausted".
- Settling now uses `modificationCount`-based idle detection instead of configurable timeouts. A fixed 5-second hard cap replaces the previous 30-second cap.

---

## [0.12.0] — Testing Overhaul & Swift 6.1+

### Added
- **`@Test(.modelTesting)` trait** — new primary testing API. Annotate a `@Test` or `@Suite` with `.modelTesting`; call `model.withAnchor()` inside the body and the model automatically connects to the test scope. Use the global `expect { }` and `require(_:)` functions for assertions. Requires Swift 6.1+ (`TestScoping`).
- **`withModelTesting { }` scope function** — inline testing scope for tests that must observe post-deallocation side-effects (teardown logs, `onCancel` callbacks). Models anchored inside the closure are torn down when the closure returns, before the test function exits.
- **`withExhaustivity(_:)` / `withExhaustivity(_:_:)` functions** — temporarily adjust exhaustivity for a portion of a test body without affecting the enclosing scope.
- **`TestProbe` auto-registration** — probes now auto-register with the active `.modelTesting` scope at creation time and on every call; no explicit setup required.
- **`@ModelContainer` Hashable and Identifiable synthesis** — declare `Hashable` on a `@ModelContainer` enum and the macro synthesises `==` and `hash(into:)`; `Identifiable` is also synthesised with a stable `id`. `@Model` associated values compare and hash by identity; `Equatable`/`Hashable` value types use their natural equality. Manual implementations suppress synthesis.
- **GitHub Actions CI** — macOS (`macos-15`, latest Xcode) and Linux (Swift 6.1, 6.2, 6.3).
- `Documentation.docc` landing page and `.spi.yml` for Swift Package Index hosted docs.

### Changed
- **Minimum Swift version is now 6.1** — required for `TestScoping`, which makes the `.modelTesting` trait fully functional.
- **Linux is now a supported platform** — removed Apple-only `platforms:` restriction from `Package.swift`.
- `ModelID.description` now includes the raw integer value for easier debugging.
- `Model` is now `@unchecked Sendable` — the locking discipline is internally maintained.
- `node.transaction { }` no longer `rethrows` — transactions have no rollback; compute new values first, then apply them inside the transaction.
- Comprehensive `///` doc comments across all public API.

### Deprecated
- `model.andTester(options:withDependencies:)` — use `model.withAnchor()` inside `@Test(.modelTesting)` instead.
- `tester.assert { }` / `tester.unwrap { }` — use the global `expect { }` / `require(_:)` functions instead.
- `TestProbe.install()` — probes auto-register on creation and on every call; explicit `install()` is no longer needed.

---

## [0.11.0] — Debug API Overhaul

### Added
- **New debug API** — `model.withDebug([DebugOptions])` and `model.debug([DebugOptions])` replace `_printChanges` / `_withPrintChanges` with a composable, configurable system:
  - `.triggers()` — print which property triggered each update. Formats: `.name` (default), `.withValue` (old → new), `.withDiff` (structured diff of the triggering property).
  - `.changes()` — print the state diff after each update. Styles: `.compact` (default, only changed lines and structural ancestors), `.collapsed` (unchanged siblings shown as `… (N unchanged)`), `.full` (complete before/after context).
  - `.name("label")` — prefix all output with a custom label.
  - `.printer(stream)` — redirect output to a custom `TextOutputStream`.
  - `.shallow` — observe only the root model's own properties, not descendants.
  - Debug options accepted by `node.memoize(for:debug:)` and `Observed(debug:)` to trace individual computed values and observation-driven side effects.
  - Context and preference write triggers are now shown in debug output.

### Fixed
- Fixed races in `memoize` that caused it to stop observing updates after the first invalidation.
- Fixed two data races in context storage access.
- Fixed a regression in dependency forwarding inside `node.task` closures.
- Fixed an infinite loop in `TestAccess`.
- Fixed a deadlock in debug print diff.
- Improved observation and `memoize` to use model identity comparison, avoiding spurious re-evaluations.

---

## [0.10.1] — Bug Fix

### Fixed
- Fixed a deadlock in `TestAccess` when accessing property names concurrently.

## [0.10.0] — Context and Preferences

### Added
- **`node.context`** — top-down context propagation across the model hierarchy. Declare keys by extending `ContextKeys` with `ContextStorage` descriptors. Supports `.environment` propagation for values that automatically flow to all descendants.
- **`node.preference`** — bottom-up preference aggregation. Declare keys by extending `PreferenceKeys` with `PreferenceStorage` descriptors and a `reduce` closure.
- **`node.touch(\.property)`** — force observation notifications for a property, bypassing the `Equatable` deduplication check. Useful when external backing state mutates in-place.
- `Exhaustivity` now tracks `.context` and `.preference` writes in addition to state, events, tasks, and probes.

### Fixed
- Fixed recursive and deadlock bugs in preference storage.
- Fixed deadlock in `TestAccess` property name helper.

---

## [0.9.0] — Undo/Redo and `node` Visibility

### Added
- **Built-in undo/redo** via `node.trackUndo()`. Call from `onActivate()` to register which properties participate. Supports `ModelUndoStack` (programmatic), `UndoManagerBackend` (system Cmd+Z), selective tracking by key path, and exclusion.
- `Duration`-based timeout overloads for `tester.assert()` and `tester.unwrap()`.
- `showSkippedAssertions` on `ModelTester` — print unasserted effects without failing, for debugging.

### Changed
- `node` is now the primary way to access the model runtime; the underlying `_$modelContext` property is hidden.
- `@ModelIgnored` and `@ModelTracked` renamed to `@_ModelIgnored` and `@_ModelTracked` to make their internal nature explicit.

### Fixed
- Fixed a data race in the undo system.
- Improved `TestAccess` assertion wait behaviour for stressed test environments.
- Fixed forwarding of model dependencies inside `node.task` closures.

---

## [0.8.0] — Swift Testing, Samples, and Observation Polish

### Added
- All tests migrated from XCTest to Swift Testing (`import Testing`).
- `node` property made `public` with full doc comments.
- All example apps updated to compile on macOS and bundled in a workspace with a test plan.
- `node.transaction { }` — atomic multi-property mutations; observation callbacks deferred until completion.
- Extensive `memoize` documentation and test coverage.

### Changed
- `ObservedModel` now uses `withObservationTracking` on iOS 17+ / macOS 14+ when available.
- `Observed` coalesces updates by default.
- Removed deprecated `DebugHook.record` hooks.

### Fixed
- Fixed nested `memoize` crash.
- Fixed dirty-tracking race in memoized computed properties.
- Numerous flaky test fixes.

---

## [0.7.0] — Dictionary Support and Cleanup

### Added
- `Dictionary` conforms to `ModelContainer` when its values conform to `ModelContainer`.

### Removed
- Removed deprecated `change` and `update` key-path-based stream APIs (superseded by `Observed`).

### Changed
- `memoize` extended to accept any user-provided key string; `resetMemoization` added.

---

## [0.6.0] — `Observed` Stream

### Added
- **`Observed { ... }` stream** — observe any model properties accessed in a closure. Emits when any accessed property changes. Replaces the old `change`/`update` key-path APIs. Use with `node.forEach(Observed { count }) { ... }` or directly as an `AsyncSequence`.
- `Observed` deduplicates consecutive equal values for `Equatable` types.

### Deprecated
- Key-path-based `change` and `update` stream methods (removed in 0.7.0).

---

## [0.5.0] — Hierarchy Traversal and Memoization

### Added
- **`node.reduceHierarchy` / `node.mapHierarchy`** — traverse and query any portion of the model hierarchy by `ModelRelation` (`.self`, `.parent`, `.ancestors`, `.children`, `.descendants`, `.dependencies`).
- **`node.memoize(for:) { }` — cached computed properties that auto-invalidate when observed dependencies change.
- `node.forEach` with `cancelPrevious: true` — cancel the previous element's async work when a new value arrives.
- Equatable deduplication for model property writes — writing the same value is a no-op; no observers are notified.

---

## [0.4.0] — Swift 6 Strict Concurrency

### Changed
- **Swift 6 language mode** (`swiftLanguageModes: [.v6]`) — all code is strict-concurrency-safe.
- Replaced `XCTFail` with `reportIssue` from `IssueReporting` for runtime diagnostics in tests.
- `Cancellable` protocol now conforms to `Sendable`.

### Added
- `node` accessible from model extensions in separate files (changed to `internal`).
- `node.mapHierarchy` / `node.reduceHierarchy` — parent/ancestor access helpers.
- Events from types conforming to a protocol (not just concrete `Model` types) via `node.event(fromType:)`.

---

## [0.3.0] — Model Sharing and `@ModelDependency`

### Added
- **Model sharing** — the same model instance can live at multiple points in the hierarchy simultaneously. Events from shared models are coalesced; `onActivate` runs once; the model is deactivated when the last reference is removed.
- **`@Model` types as dependencies** — conform a model to `DependencyKey` to make it a shared dependency, automatically inserted into the hierarchy on first access.
- **`@ModelDependency` macro** — convenient shorthand for accessing model dependencies as computed properties.
- `ModelDependencies` wrapper — `@dynamicMemberLookup` over `DependencyValues`, used in `andTester { }` and `withAnchor { }` dependency override closures.
- Example apps: `SharedState`, `SignUpFlow`, `SignUpFlowUsingDependency`.

---

## [0.2.0] — Data Race Fixes

### Fixed
- Fixed data races in `Context`.
- Fixed `InternalCancellables` to hold weak reference to `Cancellations` (prevents retain cycles).
- Fixed regression with nested transactions.

---

## [0.1.0] — Initial Release

- `@Model` macro — synthesizes observable storage, `Model`/`Identifiable`/`Sendable`/`CustomStringConvertible` conformances, and the `node` property.
- `@ModelContainer` macro — synthesizes `visit(_:)` for hierarchy traversal.
- `ModelAnchor` / `withAnchor()` / `andAnchor()` — root lifetime management.
- `ModelNode` — access to `task`, `forEach`, `send`, `event`, `onActivate`, `cancelAll`, `cancellationContext`, `onCancel`, dependency access, and more.
- `ModelTester` / `TestProbe` / `Exhaustivity` — exhaustive testing of state, events, tasks, and callbacks.
- `@ObservedModel` — SwiftUI property wrapper providing bindings and fine-grained observation.
- `swift-dependencies` integration for dependency injection and overrides.
- `_printChanges()` / `_withPrintChanges()` — debug-build state change printing.
- Example apps: `CounterFact`, `Standups`, `TodoList`.

[Unreleased]: https://github.com/bitofmind/swift-model/compare/0.13.0...HEAD
[0.13.0]: https://github.com/bitofmind/swift-model/compare/0.12.0...0.13.0
[0.12.0]: https://github.com/bitofmind/swift-model/compare/0.11.0...0.12.0
[0.11.0]: https://github.com/bitofmind/swift-model/compare/0.10.1...0.11.0
[0.10.1]: https://github.com/bitofmind/swift-model/compare/0.10.0...0.10.1
[0.10.0]: https://github.com/bitofmind/swift-model/compare/0.9.5...0.10.0
[0.9.0]: https://github.com/bitofmind/swift-model/compare/0.8.1...0.9.0
[0.8.0]: https://github.com/bitofmind/swift-model/compare/0.7.2...0.8.0
[0.7.0]: https://github.com/bitofmind/swift-model/compare/0.6.4...0.7.0
[0.6.0]: https://github.com/bitofmind/swift-model/compare/0.5.2...0.6.0
[0.5.0]: https://github.com/bitofmind/swift-model/compare/0.4.8...0.5.0
[0.4.0]: https://github.com/bitofmind/swift-model/compare/0.3.13...0.4.0
[0.3.0]: https://github.com/bitofmind/swift-model/compare/0.2.2...0.3.0
[0.2.0]: https://github.com/bitofmind/swift-model/compare/0.1.9...0.2.0
[0.1.0]: https://github.com/bitofmind/swift-model/releases/tag/0.1.0
