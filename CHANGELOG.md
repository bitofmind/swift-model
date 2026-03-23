# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased] — Context Storage API Split

### Added
- **`node.local`** — new accessor for node-private storage. Reads and writes are isolated to the node; descendants do not inherit the value.
- **`node.environment`** — new accessor for top-down propagating storage. Writes are visible to all descendants (equivalent to the old `.environment` propagation).
- **`LocalKeys` / `LocalStorage`** — namespace and descriptor type for declaring node-private storage keys.
- **`EnvironmentKeys` / `EnvironmentStorage`** — namespace and descriptor type for declaring top-down propagating storage keys.
- **`node.removeLocal(_:)`** — removes a local storage value back to default.
- **`node.removeEnvironment(_:)`** — removes a local override, causing the node to inherit from its nearest ancestor again.
- **`Exhaustivity.environment`** — new exhaustivity category for `node.environment` writes (separate from `.local`).

### Deprecated
- **`node.context`** — use `node.local` or `node.environment` depending on the desired propagation.
- **`node.removeContext(_:)`** — use `node.removeLocal(_:)` or `node.removeEnvironment(_:)`.
- **`ContextKeys` / `ContextValues`** — use `LocalKeys` / `LocalStorage` or `EnvironmentKeys` / `EnvironmentStorage`.
- **`Exhaustivity.context`** — use `[.local, .environment]` to cover both, or target one specifically.

### Changed
- Debug trigger output now shows `ModelType.local.keyName` / `ModelType.environment.keyName` instead of the generic `ModelType.context.keyName`.
- Exhaustion failure messages now say "Local not exhausted" / "Environment not exhausted" instead of "Context not exhausted".

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
