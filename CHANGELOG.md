# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [1.0.0] — `@Model` Layout Redesign, Performance Overhaul + API Cleanup

### Changed

- **`@Model` generated code restructured** — tracked `var` properties are now stored in a nested `_State` struct inside the macro expansion rather than as individual backing fields directly on the value type. The model struct itself stores only `_$modelAccess` (8 bytes) and `_$modelSource` (8 bytes).

- **`@Model` no longer synthesises an `Observable` conformance** — the generated `extension MyModel: Observation.Observable { … }` block is removed. Observation tracking for SwiftUI and `TestAccess` is handled internally through typed key paths without requiring `Observable` conformance. Explicit `Observable` conformance on `@Model` types is now redundant.

- **`ContainerVisitor<State>` → `ContainerVisitor<V: ModelVisitor>`** — the generic parameter is now the concrete visitor type rather than the raw state type. `@ModelContainer`-generated `visit(with:)` bodies are updated automatically. Any hand-written `visit(with:)` that spells out `ContainerVisitor<…>` by type-parameter name must be updated; call sites of `visitStatically` / `visitDynamically` are otherwise unchanged.

- **Custom `@Model` inits must use `self.property = value`** — the init-accessor storage layout has no underscore-prefixed backing fields. The old `_property = value` pattern no longer compiles; all properties in user-written initialisers must be assigned through `self.property =`.

### Added

- **`MutableCollection` of `Model` or `ModelContainer` elements handled automatically** — any `var` property whose type is a `MutableCollection` with `Model & Identifiable & Sendable` elements (e.g. a custom sorted-array type) is now traversed and activated by the framework without requiring an explicit `ModelContainer` conformance on the collection type. The same applies to collections of `ModelContainer & Identifiable` elements.

- **Benchmark target** — new `SwiftModelBenchmarks` executable target (`scripts/benchmark`) covers activation, property reads/writes, hierarchy update, event dispatch, and `reduceHierarchy`. Used to track and validate performance improvements.

### Performance

- **`@Model` struct size is now 16 bytes + `let` fields** — tracked `var` properties live in a `_State` struct inside the reference-counted context and no longer contribute to the value-type size. Only `let` properties remain as direct stored fields.

- **Lazy child context creation** — `Context<M>` instances for child models are allocated only on first access. Models with many rarely-reached children pay no upfront cost.

- **Cached key-path → registrar path mapping** — per-property `ObservationRegistrar` key paths are cached after first use, eliminating a per-read heap allocation that dominated property-read cost (~1,910 ns → ~730 ns, ~2.5× faster reads).

- **Shared observation registrar** — all models rooted at the same anchor share a single `RegistrarBox`, reducing per-model allocation and `withObservationTracking` overhead.

- **Reduced lock contention** — `AnyContext.parentsLock` decouples the parents-path lock from the main context lock, reducing contention in read-heavy hierarchies.

- **Cursor-based `ModelContainer` updates** — `ContainerCursor` is now a `struct`; `shouldSkipElement` lets the traversal short-circuit unchanged children, avoiding unnecessary context-lookup work on large stable collections.

- **Lazy dependency capture** — child contexts that have no dependency overrides no longer copy the parent's dependency stack, saving allocations in the common case.

- **Faster `reduceHierarchy` and event dispatch** — internal iteration no longer boxes each step through an existential; ~30–40% faster for wide hierarchies.

### Added

- **Swift 6.2 `defaultIsolation: MainActor` support** — `@Model`-annotated types now compile and behave correctly in modules that use Xcode 26's default project setting `defaultIsolation: MainActor`. All conformance extensions (`Model`, `Sendable`, `Identifiable`, `CustomReflectable`, `CustomStringConvertible`) and all framework-facing member declarations (`visit(with:)`, `_State`, `_makeState`, `_modelState`, `_modelStateKeyPath`, `_$modelContext`, `_context`, `_updateContext`) are now generated with explicit `nonisolated`. This is a no-op in modules without a default isolation; it is required so that SwiftModel's non-`@MainActor` internals can access model state without compile errors when the user module injects `@MainActor` as the default. See `Docs/Dependencies.md` for the companion patterns needed on dependency types and plain domain structs in such modules.

- **`SwiftModelMainActorTests` test target** — new conditional target (Swift 6.2+, `#if swift(>=6.2)`) that validates the full `@Model` feature set under `defaultIsolation: MainActor` module isolation: tracked properties, `@ModelDependency`, `node.task`, optional child models, and arrays of child models.

### Fixed

- **Dep context instance mismatch** — when a `@Model` dependency (dep context) resolves another dependency via `node[Dep.self]`, `nearestDependencyContext` now starts its search from the parent rather than the dep context itself. This ensures the root's explicit `withAnchor { $0[Dep.self] = … }` override wins over the dep model's own `testValue` dep defaults, regardless of dep-loop ordering. Previously, non-deterministic dictionary iteration could cause the dep context to find its own dep instance (D1) while root writes went to a different instance (D2), resulting in `Observed { … }` streams that never fired.

- **Stored-child read-modify-write dep pollution** — when a stored child's `withDependencies` closure performed a read-modify-write on an inherited dep model (e.g. `$0.envProp.state = "childDefault"`), the mutation bypassed `ModelDependencies.subscript` and mutated the shared `Reference` in place, contaminating the parent's `dependencyModels` entry. The parent's dep loop then hit the `_PendingDepKey` cache (same `modelID`) and reused the child's dep context, causing the parent to see the child's overridden value instead of the anchor's explicit two-step override. Fix: dep model entries are snapshotted via `initialDependencyCopy` before `withContextAdded` runs. If the snapshot's `_stateVersion` differs after `withContextAdded`, the clone (correct pre-RMW state, independent `modelID`) is used for the parent's dep context instead.

- **Swift exclusivity violation when replaced property deinits read sibling properties** — in three call paths (`Context._modify`, `_threadLocalStoreOrLatest`, `Reference.clear`), the old property value could be destroyed while `Reference.state` was still exclusively held. If the value's `deinit` (e.g. a stored closure) read any model property on the same model, it triggered a fatal "Simultaneous accesses" exclusivity violation. Fixed by pinning the old value alive until after exclusive access ends (`defer { _fixLifetime(oldValue) }` / `withExtendedLifetime`).

- **Crash at construction and teardown for models with class-reference-containing properties** — `Reference._genesisState` was previously initialised via `_zeroInit()` (all-zero bytes). For property types whose value representation uses a class reference (e.g. `SwiftUI.ScrollPosition`, any struct with a `class` field), all-zero memory is not a valid Swift value; accessing or retaining it crashes. Fixed by initialising `_genesisState` to `state` (the model's actual initial value) in `Reference.init`. `Reference.clear()` now stores genesis into `state` instead of calling `_zeroInit()`, ensuring all reads on a cleared reference return valid values.

- **`@Model` macro: duplicate conformance extensions** — when a user declared `CustomStringConvertible` on their `@Model` type (in the inheritance clause or a separate extension), the macro would still emit an `extension MyType: CustomStringConvertible, CustomDebugStringConvertible { … }` block. The compiler rejected duplicate conformances. Fixed by checking the real compiler's `protocols` parameter (which only lists unsatisfied conformances) instead of inspecting the inheritance clause; `CustomStringConvertible` and `CustomDebugStringConvertible` are now synthesised independently so a user-provided `description` suppresses only the description extension, not `debugDescription`.

### Removed

All APIs that were deprecated in prior releases have been removed:

- **`node.uniquelyReferenced() -> AsyncStream<Bool>`** — use `node.isUniquelyReferenced` instead. The property participates in the full observation system (`Observed { node.isUniquelyReferenced }`, `node.onChange(of: node.isUniquelyReferenced)`, `node.memoize`, SwiftUI views) and fires only on parent-relationship changes rather than on every modification in the hierarchy.

- **`UsingModel`** — use `ModelScope { … }` instead, capturing models from the enclosing scope.
- **`observeAnyModification()`** — use `observeModifications()` for identical behaviour; the new API adds scope, kind, and predicate filtering.
- **`model.andTester(exhaustivity:withDependencies:)`** — use `model.withAnchor()` inside `@Test(.modelTesting)` instead.
- **`tester.assert { }` / `tester.assert(_:)` / `tester.unwrap(_:)`** — use the global `expect { }` and `require(_:)` functions instead.
- **`TestProbe.install()`** — probes auto-register on creation and on every call.
- **`expect(timeoutNanoseconds:)` / `require(_:timeoutNanoseconds:)`** — timeout is no longer configurable; remove the `timeoutNanoseconds` parameter.
- **`ExpectMode` / `expect(.settling) { }`** — use `settle { }` instead.
- **`_ModelTestingTrait`** typealias — use `ModelTestingTrait` directly.
- **`node.context`** — use `node.local` or `node.environment` depending on the desired propagation.
- **`node.removeContext(_:)`** — use `node.removeLocal(_:)` or `node.removeEnvironment(_:)`.
- **`ContextKeys` / `ContextValues`** — use `LocalKeys` / `LocalStorage` or `EnvironmentKeys` / `EnvironmentStorage`.
- **`node.transaction(_:) rethrows`** — transactions do not roll back on error; compute values outside the transaction, then apply them in a non-throwing `transaction { }` closure.
- **`model.andAnchor(function:andDependencies:)`** — use `model.returningAnchor(withDependencies:)` instead.
- **`model._printChanges(name:to:)`** — use `model.debug()` instead.
- **`model._withPrintChanges(name:to:)`** — use `model.withDebug()` instead.

### Tests

- **Memory layout regression tests** — `MemoryTests` verifies that `_ModelSourceBox` is 8 bytes, `_ModelAccessBox` is 8 bytes, and a zero-field `@Model` struct is 16 bytes total.
- **Init accessor sequencing tests** — `ModelInitAccessorTests` covers init-accessor ordering, zero-init fallbacks, nested models, property-default capture sequencing, and custom inits with child-model collections (regression guard for the `self.property` requirement).
- **Lazy context field tests** — `LazyContextFieldTests` verifies that lazy backing stores (`cancellations`, `memoizeCache`, `contextStorage`, `preferenceStorage`, `observationRegistrar`) remain `nil` until first use.
- **Benchmark harness** — `LazyContextBenchmarks` provides a repeatable in-process benchmark for CI performance regression detection.

---

## [0.15.0] — observeModifications() with Scope, Kind, and Predicate Filtering

### Added
- **`observeModifications(scope:kinds:where:debug:)`** — replaces `observeAnyModification()` with rich filtering options:
  - `scope: ModificationScope` — narrow or widen which hierarchy levels trigger: `.self`, `.children`, `.descendants`, or combinations (default: `[.self, .descendants]`)
  - `kinds: ModificationKind` — filter by change category: `.properties`, `.environment`, `.preferences`, `.parentRelationship`, or `.all` (default). Use `kinds: .properties` to skip environment/preference noise in autosave scenarios
  - `where: (@Sendable (Any) -> Bool)?` — model-type predicate; return `true` to include the emission. Useful for filtering to a specific protocol or type in large hierarchies
  - `debug: DebugOptions?` — pass `.triggers()` to print a line for each emission with model name, kind, and depth. Only active in DEBUG builds
- **`node.excludeFromModifications(_ paths:)`** — declares specific properties of a model as "transient": their changes will not trigger any `observeModifications()` registered on this model or its ancestors. Useful for caches, scroll positions, and other volatile state. Declared in `onActivate()`, mirrors the `trackUndo(_ paths:)` API. Only affects `observeModifications()` — other observation mechanisms are unaffected
- **`ModificationKind`** — new `OptionSet` type categorising modification kinds (`.properties`, `.environment`, `.preferences`, `.parentRelationship`, `.all`)
- **`ModificationScope`** — new `OptionSet` type describing hierarchy depth (`.self`, `.children`, `.descendants`)

### Deprecated
- **`observeAnyModification()`** — superseded by `observeModifications()`. Replace `observeAnyModification()` with `observeModifications()` for identical behaviour; use the new parameters to filter as needed

---

## [0.14.1] — ModelScope + iOS 16 Bug Fixes

### Added
- **`ModelScope`** — new SwiftUI view that scopes observation to its content, preventing unnecessary parent re-renders. Wrapping reactive content in `ModelScope` confines observation to that sub-tree: only `ModelScope` re-renders when its accessed properties change, leaving the parent unaffected. Also fixes an iOS 16 issue where model properties accessed inside lazy `@ViewBuilder` closures (`.sheet`, `.popover`, `GeometryReader`, `NavigationStack` destinations) were not observed. On iOS 17 and later, `ModelScope` is a transparent pass-through — the platform already scopes observation per view boundary.

### Deprecated
- **`UsingModel`** — superseded by `ModelScope`. Replace `UsingModel(model) { model in … }` with `ModelScope { … }`, capturing the model from the enclosing scope. `ModelScope` naturally handles multiple models accessed in the same closure.

### Fixed
- **`@MainActor` missing from `mainCallQueueDrainLoop`** — on iOS 16, `objectWillChange.send()` could fire off the main thread after the drain loop's first `Task.yield()` suspension, breaking the `AccessCollector` observation path. Adding `@MainActor` ensures every batch — including post-yield batches — runs on the main thread.
- **`containerIsSame` for `@ModelContainer` enums** — when an enum conforming to `Equatable` (via `@ModelContainer` synthesis or explicitly) was written with the same value, the write was incorrectly treated as a mutation, triggering spurious view re-renders and `onChange` callbacks. The equality check is now performed before recording a modification.

---

## [0.14.0] — Exhaustivity Improvements + Convenience Helpers

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
- **Lock-ordering inversion in `Context.rootPaths`** — fixed a lock-ordering inversion that could deadlock when accessing root paths concurrently with context teardown.
- **Exhaustivity tracking races** — each `@Test(.modelTesting)` test now receives an isolated `BackgroundCallQueue`, preventing exhaustivity assertions from leaking between concurrent tests.

### Performance
- `@inlinable` annotations added to hot paths in the observation and context subsystems.
- Lazy allocation of cancellations, observation registrars, and context dictionaries — reduces memory footprint for models that don't use every feature.

### Documentation
- README restructured into a ~200-line landing page. Full reference content lives in `Docs/` subdocuments: `Models.md`, `Lifecycle.md`, `Events.md`, `Dependencies.md`, `Navigation.md`, `HierarchyAndPreferences.md`, `Testing.md`, `Undo.md`, `Debugging.md`, `TransitionsDesign.md`.

---

## [0.13.1] — Concurrency Fixes, Cross-Platform CI & README Badges

### Fixed
- **Memoize stale cache after concurrent reset** — fixed a race in the `withObservationTracking` (async) path where `performUpdate`'s `onUpdate` could recreate a cache entry removed by `resetMemoization`, leaving a stale value with no active subscription. Also preserved the `isDirty` flag when a concurrent mutation occurs between `observe()` and `onUpdate()`.
- **Memoize dirty flag lost in sync path** — fixed `wrappedOnUpdate` unconditionally clearing `isDirty` to `false`, losing dirty flags set by concurrent mutations between `produce()` and the cache write. Also added a guard against re-creating entries removed by `resetMemoization`.
- **ARC race in `onRemoval`** — deferred release of memoize cache entries to outside the context lock, preventing a crash when GCD-dispatched `performUpdate` closures raced with `_memoizeCache.removeAll()` during teardown.
- **TestAccess race** — fixed a race condition in `TestAccess`.

### Changed
- **CI Linux tests run serially** (`--no-parallel`) to avoid cooperative thread pool saturation on 2-vCPU runners.
- **BackgroundCallQueue** reverted to GCD-based drain on Apple/Linux for more predictable scheduling.
- Several flaky tests restricted to `AccessCollector`-only path where `withObservationTracking` async timing caused spurious failures.

### Added
- **WASM support** — library compiles for `wasm32-unknown-wasip1` (compile-check in CI).
- **Android support** — test target compiles for `aarch64-unknown-linux-android28` (build-check in CI).
- **CI badges** — per-platform badges in README: macOS and Linux (tests), Android and WASM (build).

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

[Unreleased]: https://github.com/bitofmind/swift-model/compare/1.0.0...HEAD
[1.0.0]: https://github.com/bitofmind/swift-model/compare/0.14.0...1.0.0
[0.14.0]: https://github.com/bitofmind/swift-model/compare/0.13.1...0.14.0
[0.13.1]: https://github.com/bitofmind/swift-model/compare/0.13.0...0.13.1
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
