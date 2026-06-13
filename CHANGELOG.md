# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Fixed

- **`node.memoize` no longer degrades to recompute-per-access once a dependency changes — the produce-per-access thrash that blocked adopters from upgrading past 1.0.2.** Two defects compounded into "every read runs `produce()`": (1) a value-changing dependency write left the cache entry permanently dirty, because the coalesced `performUpdate` *preserved* the dirty flag when storing a recomputed value (it couldn't tell "the mutation this recompute already incorporates" from "a concurrent mutation during produce") — so after one write, every subsequent access found the entry dirty and recomputed inline forever, even on a fully idle machine; (2) while the async revalidation task lagged (saturated cooperative pool), each dirty read recomputed inline *and threw the result away*, so N accesses in the starvation window cost N produces instead of 1. The fix replaces the `isDirty` boolean with monotonic `dirtyVersion`/`cleanVersion` counters: a recompute captures `dirtyVersion` before running `produce()` and advances `cleanVersion` to exactly that value when it commits — so the dependency changes the recompute incorporated are cleared, while a change arriving *during* `produce()` (which bumps `dirtyVersion` further) correctly keeps the entry dirty. A dirty read now also writes its fresh value back into the cache (silently on the `withObservationTracking` path — the already-scheduled `performUpdate` remains the sole notifier and dedups against the last *notified* value, so a read never fires observer notifications), so subsequent accesses in a starvation window hit the cache. Net effect: produce-count is now O(1) per dependency change regardless of access count or pool load, on both the `withObservationTracking` and `AccessCollector` paths, for single and chained memoizes. (Adopters pinned to `exact: "1.0.2"` solely to avoid this can move to the normal `from:` requirement once this ships.)

- **Reading a memoized property inside `withUntrackedModelReads { }` now returns through the same cached fast path as a tracked read** instead of being materially slower. With the produce-per-access thrash fixed (above), an untracked cached memoize access is now ~0.9× the cost of a tracked one (it skips the observation dispatch), rather than the ~6× *slower* adopters measured on 1.0.3 — that figure was the discarded-recompute cost, not a pure access-path cost.

### Changed

- **`node.memoize` cache-hit fast path no longer allocates per access.** The `forceNextBox` (`LockIsolated`) and `didModifyCallback` closure are now built only on the first access that sets up tracking, not on every call — they were pure waste on the common cache-hit path, which discarded them.

### Added

- **Memoize regression coverage.** `SwiftModelTests.MemoizeThrashTests` asserts produce-count stays O(1) after a dependency write and under *deterministic* cooperative-pool starvation (the revalidation queue is blocked on a gate, not left to machine load) — for tracked and untracked access, single and chained memoizes. `SwiftModelBenchmarkTests.MemoizeAccessBenchmarks` adds the cost benchmark (cached untracked vs tracked access, interleaved-median ratio for CI stability) plus produce-count under genuine cooperative-pool saturation; it runs in CI via a dedicated `benchmarks` job (the read-path and timing benchmarks remain on-demand).

---

## [1.0.3] — Read-path performance: `withUntrackedModelReads`, striped observer-KP cache, `@inlinable` hot path

### Added

- **`withUntrackedModelReads { }` — public untracked/bulk-read scope.** Reads of `@Model` properties (and memoize/environment/preference values) inside the scope register no observation dependencies anywhere: no `ObservationRegistrar.access`, no `ModelAccess.willAccess` dispatch (view tracking / `ModelTester` / `Observed`), and no access stamping of returned child models. Reads reduce to a lock-protected raw state read — they still route through the context lock, so scanning while other threads write stays memory-safe (unlike the internal `forceDirectAccess` mechanism, which bypasses the lock and stays internal). Intended for O(N) traversals over live models on hot paths — hit-testing, snapping, validation passes — where per-read observation overhead dominates and the caller doesn't want a dependency on every visited property. Writes inside the scope notify normally. Framework-driven dependency collection is immune: `update()` (the engine under `node.memoize` and `Observed`) clears the flag around its `access()` evaluations, so a memoize set up inside an untracked scope still tracks its own dependencies. In the Release read-path benchmark an untracked read costs ~half a tracked read, and the n=120 two-property scan drops ~1.7x; a pre-extracted value snapshot remains far cheaper still for repeated scans (see the new *Performance* documentation article).

- **Read-path + scan benchmarks.** `SwiftModelBenchmarks` (Release executable) gains sections *2b. Read path* (raw vs tracked {no listener, inside `withObservationTracking`} vs untracked), *2c. O(N) scan over live child models* (n=120, the client workload that motivated the untracked API), and *2d. Parallel tracked reads* (8-thread contention probe for process-global serialization points in the read path). `SwiftModelBenchmarkTests.ReadPathBenchmarks` adds ratio-asserting micro-benchmarks (min-of-rounds; asserts untracked beats tracked and raw beats untracked — ratios, not absolute times, for machine stability) including `@testable`-only scenarios (registrar disabled, stamped propagating access).

- **Performance documentation article** (`Documentation.docc/Performance.md`): what a tracked read pays, why the cost is real in Release builds (key-path projection, registrar internals, locks, and cross-module generic dispatch all ship `-O` regardless of the app's build configuration), the ~10–30x `-Onone` inflation to watch for when profiling Debug builds, and when to reach for `withUntrackedModelReads` vs `node.memoize` vs value snapshots.

### Changed

- **The hot read chain is now `@inlinable` — reads specialize and inline into client modules.** Macro-generated accessors compile in the *client's* module, so every tracked read previously crossed the module boundary through unspecialized generic entry points (runtime metadata, witness tables, coroutine shells). The generic `<T>` read subscript, the `Context` state subscript, and `withUntrackedModelReads` are now `@inlinable`, with a minimal `@usableFromInline` cascade (~17 annotations) over the members they touch; only `willAccessDirect` (the registrar machinery) remains an outlined call. Measured (Release, M-series, min of 3): tracked read 774 → 571 ns/op (−26%), untracked read 469 → 283 ns/op (−40%), n=120 scan 192 → 142 µs tracked / 116 → 72 µs untracked. The `@usableFromInline` members remain `internal` — not nameable from client source, gaining linkage visibility only — and a source-distributed package carries no ABI-stability constraint, so the residual cost is encapsulation discipline on the annotated members (compile-time enforced). A new in-module probe (benchmark section *2e*) tracks the remaining gap to the whole-module-optimization ceiling (~508 ns tracked / ~228 ns untracked).

- **Observer-KP resolution no longer serializes every tracked read/write on one process-global lock, and no longer runs a dynamic cast per access.** `Context.willAccessDirect` / `invokeDidModifyDirect` resolved their registrar observer key path through a single `NSLock`-guarded cache keyed by `(contextID, statePath.hashValue)`, whose lookup also performed an `as?` dynamic cast — a `swift_dynamicCast` on the hottest path in the library (the same Linux runtime-cast failure family worked around in 7a59f42, a847c79, and 9d87bd3). A new identity-keyed first level (`_stateObserverKP`) keys by `ObjectIdentifier` of the key-path object (macro-generated accessors pass key-path literals, which the runtime interns per call site) under 1-of-16 striped locks, and resolves hits with `unsafeDowncast` — sound because each entry retains its key-path object (no ABA on address reuse) and the key-path object determines the state type. Misses fall back to the structural `hashValue`-keyed cache, so appended/dynamically-built key paths still canonicalize to the same observer KP; stripes self-clear at capacity (no unbounded growth for generic `@Model` types whose key-path literals can't be interned). Measured (Release, M-series, min of 3): 8-thread concurrent reads of distinct models improve ~35% (≈7.4 → ≈4.8 μs/op under full 8-way contention, see the new *2d. Parallel tracked reads* benchmark); single-threaded reads are unchanged within run-to-run noise (≈0.85–1.0 μs/op before and after — the structural hash of a simple stored-property key path was *not* a measurable share of single-threaded read cost).

---

## [1.0.2] — Linux `SIGSEGV` workaround + `settle()` budget-cap enforcement

### Fixed

- **Intermittent Linux `SIGSEGV` in `ContainerVisitor` state dispatch.** `ContainerVisitor._dispatchStatePath` ran `modelVisitor as? any _ModelStateVisitor` on every `_ModelState`-level visit, purely to detect the lone `InstallUndoVisitor` conformer. That runtime existential check routes through `swift_conformsToProtocol`, which intermittently null-dereferenced inside `libswiftCore` (`swift_conformsToProtocolMaybeInstantiateSuperclasses`) on the `Linux (serial)` CI job when the conformance cache raced first-time instantiation — the same Linux runtime-cast failure family already worked around in 7a59f42 and a847c79. The cast is replaced with witness-table dispatch on `ModelVisitor`: a `_isModelStateVisitor` discriminator (default `false`) and a `_visitModelStatePath` requirement (default no-op). Dispatch now goes directly off the `V` conformance record `ContainerVisitor` already holds — no `swift_conformsToProtocol`, no `swift_dynamicCast`, and cheaper than the per-property conformance scan it replaces. `InstallUndoVisitor` opts in via `_isModelStateVisitor`; the now-unused internal `_ModelStateVisitor` protocol is removed. Behaviour-identical.

- **In-test `settle()` now enforces its total-budget cap under `.background` starvation.** `settle()` arms its quiet-window deadline with `.deferential` priority, whose `GlobalTickScheduler` callback hops to `DispatchQueue.global(qos: .background)` before running — and the settle total-budget cap (`pastBudget`) lives *inside* that callback. On a saturated CI host the `.background` slot may never get scheduled within the budget, so the cap never tripped: `settle()` instead unblocked ~30 s later at the `.modelTesting` trait wall-clock cap, surfacing a misleading `settle() timed out: model still has active tasks.` against an empty active-task list. Debounced `.deferential` entries now arm a *second* scheduler entry at the fixed total-budget deadline with `.responsive` priority, which runs inline on the timer's `.userInitiated` queue and is never starved by `.background`, so the cap always trips on time regardless of pool load. Whichever entry fires first resolves the pending wait; the other becomes a no-op. `.predicate` and cleanup-settle entries were already `.responsive` and are unaffected.

### Internal

- **`GlobalTickScheduler` is now injectable into `TestAccess`** (defaulting to `.shared`, threaded through `ModelTester.init`) and `_drivenTick` gains a `fireDeferential:` flag that can hold expired `.deferential` entries pending while firing `.responsive` ones inline. This lets `SettleBudgetCapStarvationTests` model an infinitely-starved `.background` slot with a per-test manual scheduler — no real GCD timer and no process-global `.background` queue — making the budget-cap regression coverage deterministic and fully parallel-safe. Production and all existing tests keep using `.shared` unchanged; the change is purely additive.

---

## [1.0.1] — Packaging fix: stable `swift-dependencies` pin

### Fixed

- **`swift-dependencies` is now referenced by a version requirement (`from: "1.13.0"`) instead of `branch: "main"`.** Depending on it by branch made `swift-model` itself an *unstable-version* package, so any downstream project that required `swift-model` by a stable version (e.g. `from: "1.0.0"`) failed to resolve with:

  ```
  'swift-model' is required using a stable-version but 'swift-model'
  depends on an unstable-version package 'swift-dependencies'
  ```

  swift-dependencies 1.13.0 ships the trait-aware manifest the branch pin was waiting for, so the dependency can now point at a tagged release. The `#if swift(>=6.3)` gate around the `traits: ["Foundation", "Clocks"]` override is retained: 1.13.0 still ships the `Package@swift-6.0.swift` shadow manifest (no traits), which SE-0152 selects on toolchains < 6.3, where a `traits:` override would be a hard error. No source or API changes.

---

## [1.0.0] — `@Model` Layout Redesign, Performance Overhaul + API Cleanup

### Changed

- **`@Model` generated code restructured** — tracked `var` properties are now stored in a nested `_State` struct inside the macro expansion rather than as individual backing fields directly on the value type. The model struct itself stores only `_$modelAccess` (8 bytes) and `_$modelSource` (8 bytes).

- **`@Model` no longer synthesises an `Observable` conformance** — the generated `extension MyModel: Observation.Observable { … }` block is removed. Observation tracking for SwiftUI and `TestAccess` is handled internally through typed key paths without requiring `Observable` conformance. Explicit `Observable` conformance on `@Model` types is now redundant.

- **`ContainerVisitor<State>` → `ContainerVisitor<V: ModelVisitor>`** — the generic parameter is now the concrete visitor type rather than the raw state type. `@ModelContainer`-generated `visit(with:)` bodies are updated automatically. Any hand-written `visit(with:)` that spells out `ContainerVisitor<…>` by type-parameter name must be updated; call sites of `visitStatically` / `visitDynamically` are otherwise unchanged.

- **Custom `@Model` inits must use `self.property = value`** — the init-accessor storage layout has no underscore-prefixed backing fields. The old `_property = value` pattern no longer compiles; all properties in user-written initialisers must be assigned through `self.property =`.

- **`debug(_:)` / `debug(_:_:)` moved from `Model` to `ModelNode`** — the closure-form and no-closure-form model-level debug entry points now live on `ModelNode`, matching their doc comments (which always said `node.debug(…)`) and the placement of all other `node.*` methods (`memoize`, `transaction`, `trackUndo`, etc.). Call sites from inside a model body continue to read `node.debug(…)` as before. External callers that were inadvertently relying on the misplaced `Model.debug` need to thread through `.node`: `model.debug(…)` → `model.node.debug(…)`. `withDebug(_:)` (the modifier form on `Model`) is unchanged.

### Added

- **`MutableCollection` of `Model` or `ModelContainer` elements handled automatically** — any `var` property whose type is a `MutableCollection` with `Model & Identifiable & Sendable` elements (e.g. a custom sorted-array type) is now traversed and activated by the framework without requiring an explicit `ModelContainer` conformance on the collection type. The same applies to collections of `ModelContainer & Identifiable` elements.

- **Benchmark target** — new `SwiftModelBenchmarks` executable target (`scripts/benchmark`) covers activation, property reads/writes, hierarchy update, event dispatch, and `reduceHierarchy`. Used to track and validate performance improvements.

- **Reactive single-await test primitives** — `expect { }`, `require(_:)`, and `settle()` now suspend on a single `withCheckedContinuation` and wake reactively on model writes / `node.send(...)` events / `TestProbe` calls. Internally a per-`TestAccess` queue of pending entries (`_pendingExpects`) is iterated under `TestAccess.lock` on every `_noteActivity()` — predicates that pass have their continuations resumed outside the lock. Replaces the prior park-and-loop scheme that retried predicates on a timer. Deadline cancellation is delegated to `GlobalTickScheduler` (below) so the cooperative pool can't starve it. The visible test API is unchanged; the change shows up as significantly faster `await expect` / `await settle` (no fixed polling interval) and as cleaner stack traces (a single suspension instead of nested timer loops).

- **`GlobalTickScheduler`** (internal) — a process-wide GCD-backed deadline scheduler shared by every per-test `TestAccess`. Deadlines for `expect` / `require` / `settle` and the per-test wall-clock cap (`.modelTesting`'s 30 s trait timeout) are registered with the scheduler; it fires from GCD's thread pool, so the cooperative pool can be fully saturated with parallel-test work and the deadline still arrives on time. Hangs in the cooperative pool now surface as a deterministic `[TRAIT timeout]` failure rather than as wedged tests.

  The scheduler uses a **one-shot timer source** armed to the soonest pending deadline (re-armed after each fire). No periodic ticker, no idle CPU cost. The timer itself runs at `.userInitiated` so deadlines surface promptly under load.

  Each scheduled entry carries a **`CallbackPriority`** (`.responsive` or `.deferential`). Responsive callbacks run inline on the timer's `.userInitiated` queue — used for failure-case timeouts and polling, where firing close to the requested deadline is the contract. Deferential callbacks hop to `DispatchQueue.global(qos: .background)` before executing — used by **in-test settle's quiet-window check** so suspended cooperative-pool Tasks (which run at `.medium`) get CPU before the check, closing the race where a cascade write lands just after settle's nominal deadline. Cleanup settle uses `.responsive` because `cancelAllRecursively` has already torn down the active tasks and the 200 ms cleanup window absorbs cancel-handler writes naturally; deferring would stall every test's teardown behind the `.background` queue.

  No load-aware multipliers or scaling — adaptation under contention lives entirely in the OS scheduler's QoS prioritisation. Set `SWIFT_MODEL_GTS_TRACE=1` to write per-event diagnostic logs to `/tmp/swift-model-{gts,settle}-trace.log`.

- **`BackgroundCallQueue.onIdle(_:)`** (internal) — a one-shot idle observer. Registering a callback either fires it inline if the queue is currently empty, or arms it to fire the next time the drain runs through and finds the queue empty. Used by `awaitSettled` to compose "no model writes for the quiet window AND `backgroundCall` is fully idle" without a polling loop — important for catching silent memoize recomputes whose `isSame`-true updates skip the `didModify` notification path.

- **`waitUntil(_:)` polling helper** — `Tests/SwiftModelTests/Utilities.swift`. Explicit-polling escape hatch for framework-internal lifecycle tests whose predicates read off-model state (`TestResult` / `LockIsolated` counters mutated from `forEach` callbacks). Not for user tests — `expect` / `require` / `settle` should cover those — but documented in `CLAUDE.md` so the distinction is clear.

- **Per-test wall-clock cap on `@Test(.modelTesting)`** — every `.modelTesting` test now races against a 30 s `GlobalTickScheduler` timer. Hitting it surfaces as `[TRAIT timeout]` and cancels the body task; wait primitives use `withTaskCancellationHandler` to resume parked continuations, so the body unwinds rather than wedging the test runner. Override per-process via the `SWIFT_MODEL_TEST_TIMEOUT` env var (seconds, float).

### Performance

- **`@Model` struct size is now 16 bytes + `let` fields** — tracked `var` properties live in a `_State` struct inside the reference-counted context and no longer contribute to the value-type size. Only `let` properties remain as direct stored fields.

- **Lazy child context creation** — `Context<M>` instances for child models are allocated only on first access. Models with many rarely-reached children pay no upfront cost.

- **Cached key-path → registrar path mapping** — per-property `ObservationRegistrar` key paths are cached after first use, eliminating a per-read heap allocation that dominated property-read cost (~1,910 ns → ~730 ns, ~2.5× faster reads).

- **Shared observation registrar** — all models rooted at the same anchor share a single `RegistrarBox`, reducing per-model allocation and `withObservationTracking` overhead.

- **Reduced lock contention** — `AnyContext.parentsLock` decouples the parents-path lock from the main context lock, reducing contention in read-heavy hierarchies.

- **Cursor-based `ModelContainer` updates** — `ContainerCursor` is now a `struct`; `shouldSkipElement` lets the traversal short-circuit unchanged children, avoiding unnecessary context-lookup work on large stable collections.

- **Lazy dependency capture** — child contexts that have no dependency overrides no longer copy the parent's dependency stack, saving allocations in the common case.

- **Faster `reduceHierarchy` and event dispatch** — internal iteration no longer boxes each step through an existential; ~30–40% faster for wide hierarchies.

- **Lazy main-channel `ObservationRegistrar` allocation** — `RegistrarPair` now allocates its `background` registrar eagerly (every observation-enabled tree uses it) but the `main` registrar lazily on first main-channel use. Trees that never reach the main channel — every model tree on Linux/Android/WASM, plus opt-out trees on Apple — save one `ObservationRegistrar` (and its internal `Extent` heap object) per anchored hierarchy.

- **`_withBatchedUpdates` skips `drainIfOnMain` on non-Apple** — the post-batch `mainCallQueue.drainIfOnMain()` call is now gated on `canImport(Darwin)`. On Linux/Android/WASM no main-thread work is ever enqueued, so the drain was pure overhead (a `Thread.isMainThread` syscall on every batched write).

### Added

- **Swift 6.2 `defaultIsolation: MainActor` support** — `@Model`-annotated types now compile and behave correctly in modules that use Xcode 26's default project setting `defaultIsolation: MainActor`. All conformance extensions (`Model`, `Sendable`, `Identifiable`, `CustomReflectable`, `CustomStringConvertible`) and all framework-facing member declarations (`visit(with:)`, `_State`, `_makeState`, `_modelState`, `_modelStateKeyPath`, `_$modelContext`, `_context`, `_updateContext`) are now generated with explicit `nonisolated`. This is a no-op in modules without a default isolation; it is required so that SwiftModel's non-`@MainActor` internals can access model state without compile errors when the user module injects `@MainActor` as the default. See `Docs/Dependencies.md` for the companion patterns needed on dependency types and plain domain structs in such modules.

- **`SwiftModelMainActorTests` test target** — new conditional target (Swift 6.2+, `#if swift(>=6.2)`) that validates the full `@Model` feature set under `defaultIsolation: MainActor` module isolation: tracked properties, `@ModelDependency`, `node.task`, optional child models, and arrays of child models.

- **`withSetup`** — new modifier that runs a closure just before `onActivate()`. Use it to set `node.environment` or `node.local` keys that `onActivate()` reads (e.g. mode flags that guard which observers are registered). Unlike `withActivation`, which runs *after* `onActivate()`, `withSetup` closures run *before* it, so the model's own activation logic can see the configured values. The closure is called only when the model is anchored; if the model is never anchored, it is never called. Multiple `withSetup` calls are additive and run in declaration order.

- **`ModelOption.disableMainThreadObservation`** (internal) — opt-out for the dual-`ObservationRegistrar` main-thread bridge. On Apple platforms, mutations from background threads queue the main registrar's `willSet`/`didSet` via `mainCallQueue { @MainActor in … }` so SwiftUI/UIKit/AppKit consumers stay safely on main. Setting this option skips the main channel entirely — useful when no `Observable` consumer exists (server-side macOS, CLI tools, KVO-based AppKit apps). Non-Apple platforms (Linux, Android, WASM) behave as if this is always set; see the corresponding "Fixed" entry.

- **`$model.debug(_:)` on `@ObservedModel`** — view-side trigger logging. Call from inside `body` to log which key path on the wrapped model (or any descendant model the view reads) caused SwiftUI to invalidate that particular view. No initialiser changes required, no per-view `init` boilerplate even for models without default values — the body-side API attaches debug for the current render and removing the line auto-disables it on the next render. Mirrors the `debug:` field on `Observed`, `memoize`, `node.debug()`, and `observeModifications()`: takes a `DebugOptions` value honouring `triggers`, `name`, and `printer` (`changes` is ignored — covered by `node.debug(.changes)` on the model itself). The default label combines the wrapped model's type name with the call-site `#fileID:#line` (e.g. `"EditorModel at EditorMidBar.swift:42"`); pass `.init(name: "EditorMidBar")` for an explicit view-side label. All three trigger formats are supported: `.triggers(.name)` (default — minimal noise), `.triggers(.withValue)` (renders old → new via `customDump`), and `.triggers(.withDiff)` (structural −/+ diff, useful when the property is itself a model). The `printer` field accepts any `TextOutputStream & Sendable`, so a small `os_signpost(.event, …)` adapter routes view-invalidation events to Instruments without further wiring; see `Docs/Debugging.md` for the recipe. Works on **both** observation paths: the iOS 16 / macOS 13 `AccessCollector` path (where `ViewAccess` drives invalidation directly) and the iOS 17+ / macOS 14+ `ObservationRegistrar` path (where SwiftUI's `withObservationTracking` drives invalidation and `ViewAccess` is installed solely for debug emission with `suppressObjectWillChange` keeping it from firing a redundant invalidation signal). On the registrar path the install is **sticky-lazy**: until the first `$model.debug(…)` runs in a body, `@ObservedModel.update()` skips installing `ViewAccess` entirely (matching the release-build zero-cost path). The first `attachDebug` flips a sticky flag on the `@StateObject` access and schedules a priming `objectWillChange.send()` so the next render installs the access; from then on every render installs for the `@StateObject`'s lifetime (rebuilding the view with Cmd-R resets it). The body of `$model.debug(…)` is gated on `#if DEBUG` (the function signature is always present), so the call compiles to nothing in release — safe to leave in place when shipping, no `#if DEBUG` wrapping required at the call site. On release the registrar path preserves its zero-cost early-return regardless.

- **`ModelScope(debug:)` initialiser** — `ModelScope` now accepts a `DebugOptions` value at construction, mirroring `$model.debug(_:)` but configured at the scope's init rather than in `body`. Logs which property reads inside the scope's content closure invalidate the scope (rather than the parent view) — a natural way to split a large view's observation surface into smaller, individually-labelled regions for debugging. Default label is `"ModelScope at file:line"` (call-site `#fileID:#line`), overridable via `.init(name:)`. On the iOS 16 / macOS 13 `AccessCollector` path the scope's `ViewAccess` is installed as before; on iOS 17+ / macOS 14+ it's installed *only* when `debug` is non-nil, with `suppressObjectWillChange: true` so `withObservationTracking` continues to drive invalidation and the scope's access exists purely for debug emission. Wrap any sub-`View` in `ModelScope(debug: …) { … }` without restructuring the rest of the view tree.

- **`maxLines:` + `maxDepth:` on `.withValue` / `.value`** — `TriggerFormat.withValue` and `ChangeFormat.value` now take `(maxLines: Int = 20, maxDepth: Int = 4)`. `maxLines` post-truncates the rendered dump and appends `"… (N more line[s])"` when it overflows — protects production logs from huge value dumps (the case that triggered this work: a large `Timeline` value-struct rendered for hundreds of lines per trigger). `maxDepth` is passed through to `customDump` and short-circuits the Mirror walk at the given depth, which is the only knob that actually saves CPU on deeply-nested types. Defaults are symmetric bounded safety nets — pass `Int.max` on either field to opt out of that knob. Both shorthands `static var withValue: Self { .withValue() }` and `static var value: Self { .value() }` preserve backward compatibility at call sites that used the bare case spelling.

- **`captureAccessStack:` on `DebugOptions`** — the dedicated tool for "which read caused this trigger?". Set `captureAccessStack: 15` (or any frame count) and `willAccess` snapshots the body's raw return-address stack at access time, holds it alongside the access registration, and *only when that path actually fires a trigger* symbolicates it (via `backtrace_symbols(3)`) and appends a `\n  read from:\n    …` block to the trigger line. Trigger lines for properties that were read but never invalidated stay quiet — the signal-to-noise ratio for a complex view or expression goes from "one stack per read" to "one stack per actual re-render." Captures are cheap (raw return addresses stored as `[UInt]` bit patterns, no symbolication) and freed when access is unregistered. Free when the field is `nil`; no effect outside `DEBUG`. Honoured by every entry point that has a `willAccess` hook: `$model.debug(_:)` (`@ObservedModel`), `ModelScope(debug:)`, `Observed(debug:)`, `memoize(debug:)`, and `node.debug(_:_:)` (closure form). Ignored on `node.debug(_:)` (no-closure form) and `observeModifications(debug:)`, which observe mutations rather than reads. Composes with any `TriggerFormat` — the stack suffix appends to whatever the trigger line says (`.name` / `.withValue` / `.withDiff`). For memoize and Observed the stack identifies the body or helper that first registered the dependency inside the `produce` / observe closure, useful for nested-closure investigations. **The leading swift-model-internal frames** (`ViewAccess.willAccess`, `Context._modelSeed`, the `@dynamicMember` subscript, etc.) are automatically trimmed from each printed stack so the first visible frame is the user-code line that performed the read; deeper internal frames sandwiched between user frames (e.g. user → `memoize` → user `produce`) are preserved.

- **`AccessObserver` protocol + `FirstAccessObserver` + factories** — new read-side hook on `DebugOptions`. Where the existing `triggers` / `changes` format options report *mutations*, `accessObserver: (any AccessObserver)?` fires on every property *access* through the active debug observation — useful for custom telemetry on access patterns, or LLDB breakpoint trapping at the moment of read. Built-in `FirstAccessObserver` deduplicates by `(modelType, path)` and runs its action up to `limit` times per key. Factory helpers on `AccessObserver where Self == FirstAccessObserver`: `.firstAccess(limit:action:)` (custom action) and `.firstAccessBreakpoint(limit:)` (`raise(SIGTRAP)` so you can `bt` in LLDB and inspect the live reader frames; no-op in release). The hook fires *outside* swift-model's internal locks, so observers may freely perform expensive work (symbol resolution, breakpoint trap). Supported on `$model.debug(_:)`, `ModelScope(debug:)`, `Observed(debug:)`, `memoize(debug:)`, and `node.debug(_:_:)` (closure form). Silently ignored on `node.debug(_:)` (no-closure form) and `observeModifications(debug:)`, which observe mutations rather than reads. **For the most common "show me where this property was read from" investigation, prefer `captureAccessStack:` (above) — it gives you the same information stitched onto the trigger line instead of as a separate emit-on-every-access stream.**

### Fixed

- **`node.task(id:)` / `node.forEach(_, cancelPrevious: true)` — body interleaving across `id`-stream restarts** — when a new `id` value arrived while the previous body was mid-flight, the previous body's underlying `Task` was `.cancel()`-ed but `Task.cancel()` only flips a flag. A body that didn't hit another suspension point (or that had already passed its last one) would run to completion regardless — and could interleave its remaining writes with the new body's prefix through the model context lock. The classic shape is "two `task(id:) { value in … }` bodies both writing the same property with the post-suspension tail of the older one landing AFTER the newer one." Surfaced as `OnboardingTests.shortUsernameShowsInlineError` where the initial `""` body's `availabilityError = nil` write was clobbering the subsequent `"ab"` body's `availabilityError = "Username must be at least 3 characters"`. Fix: in `_forEachImpl`'s `cancelPrevious: true` branch the previous body's `TaskCancellable` is now retained, cancelled, and the outer for-await loop **awaits** `previousInner.underlyingTask?.value` before spawning the next body. The wrapped Task's outer `defer { onDone() }` (in `TaskCancellable`'s convenience initialiser) runs unconditionally — including when the inner `guard !Task.isCancelled` returns early without invoking the user closure — so the await resolves correctly even when cancellation arrives before the body is scheduled to run.

- **Writer-vs-reader lock-order race in `Context._modify` / `Context.stateTransaction` for `Model` / `ModelContainer` properties** — the previous writer sequence was `acquire context.lock → write reference.state → release context.lock → acquire TestAccess.lock → append valueUpdates → update lastState → fire _noteActivity`, with a gap between the two `release/acquire` steps. A reader (a predicate evaluator running on the test thread) holds `TestAccess.lock` from outside its evaluator and then takes `context.lock` to read `reference.state`. If the reader slipped into the writer's gap it could observe the new `reference.state` value while `valueUpdates` was still empty for that path, run its assertion-clearing pass against an empty entry list, and return `.passed` — leaving the entry to survive to the trait's end-of-test exhaustion check. The race was only observable for `@ModelContainer` / `@Model`-typed properties (`isContainerTypeValue` / `isModelTypeValue` short-circuits `isEqualIncludingIds`'s in-flight detection); the closure-typed associated values in `RecordMeeting.Destination.speechRecognizerFailed(discard:)` made the leaf-access backstop missing too. Fix: a new `ModelAccess.acquireWriteLock()` / `releaseWriteLock()` pair (no-op default; `TestAccess` overrides to grab its `NSRecursiveLock`) is called by `Context._modify` and `Context.stateTransaction` **before** acquiring `context.lock`, matching the reader's `access.lock → context.lock` order. The writer now holds `TestAccess.lock` across the entire write + `valueUpdates` append + `_noteActivity` sequence; readers cannot observe an inconsistent intermediate state. `Tests/SwiftModelTests/WriteLockOrderingTests.swift` covers both the lock-ordering contract directly and the end-to-end behaviour.

- **`ContainerCursor.get` force-unwrap when an element is removed concurrently with a child write** — `AnchorVisitor.visitCollection`'s lazy element-path maker (consulted by `rootPathTree()` when `TestAccess` / undo observation queries `rootPaths`) used `coll.first(where: { $0.id == typedID })!` to read the element through the cursor. Under x100 stress in `SearchTests`, the parent's `\.results` could be updated (element dropped from `lastState`) **before** the child's pending `detailLine` write reached `TestAccess.didModify`'s rootPaths walk — the force-unwrap then crashed the test. Fix: the maker signature now also takes a fallback element value (the child context's current live model captured at maker-invocation time). The cursor's `get` returns the fallback when the element has been concurrently removed, so the resulting "from" description is the last live model value — acceptable for a write that semantically targets a freshly-removed element. The change is API-internal (no public surface).

- **Pre-anchor crash on first-property assignment with no default value** — extends the fix from the previous release (which covered child `@Model` properties) to non-Model property types. A `@Model` whose first-declared property had no default value and a non-Model type (plain struct, `Equatable` struct, tuple, etc.) could trap with `Fatal error: UnsafeRawBufferPointer with negative count` in `_pop<RawKeyPathComponent.Header>` when a user-written initialiser assigned the property before the model was anchored — typically surfacing through `swift-dependencies`'s static-`liveValue` initialisation. The pre-anchor `_modify` path in `_ModelSourceBox`'s three non-`Model` write subscripts (disfavoured generic, `T: Equatable`, and the parameter-pack overload) now yields directly into the backing key path instead of taking a local copy first, mirroring the `T: Model` overload. The local-copy pattern is still used when the model is `_isLive` (storage is fully initialised in that mode).

- **`node.memoize { … }` observation isolation across both paths and both branches** — outer observers of a memoized property (a SwiftUI body's `withObservationTracking`, a `ViewAccess` from `$model.debug` / `ModelScope`, a debug collector, a `TestAccess`) now only ever depend on the memoize *sentinel* key path, never on the underlying properties read inside `produce`. Two fixes that together close the leak: (1) `update()`'s `withObservationTracking` branch wraps `access()` in `usingActiveAccess(nil)` so swift-model's outer `ModelAccess` is shielded during the cache-miss / first-access branch; (2) the dirty-recompute branch (which calls `produce()` directly, outside `update()`, to return a fresh value synchronously) now wraps that call in a new `isInsideMemoizeProduce` thread-local that our `Context.willAccessDirect` and `Context.willAccessSyntheticPath` dispatchers read at the very top — when set, they skip both the swift-model `ModelAccess.willAccess` dispatch *and* Apple's `registrar.access(...)`. Because we own those call sites we can suppress the Apple-side `_AccessList` registration entirely (rather than just wrapping in a discarded inner `withObservationTracking`), so the fix also closes the registrar-level leak that previously made a SwiftUI body observing a memoized property re-render whenever any underlying dependency changed, even when the memoized value was `isSame` after recompute. Memoize's own dependency tracking is unaffected: the cache-miss branch uses `update()`'s `observe()` (not flagged); the dirty-recompute branch doesn't re-track because the async `performUpdate` does that later via the same `observe()` (also not flagged).

- **Dep context instance mismatch** — when a `@Model` dependency (dep context) resolves another dependency via `node[Dep.self]`, `nearestDependencyContext` now starts its search from the parent rather than the dep context itself. This ensures the root's explicit `withAnchor { $0[Dep.self] = … }` override wins over the dep model's own `testValue` dep defaults, regardless of dep-loop ordering. Previously, non-deterministic dictionary iteration could cause the dep context to find its own dep instance (D1) while root writes went to a different instance (D2), resulting in `Observed { … }` streams that never fired.

- **Stored-child read-modify-write dep pollution** — when a stored child's `withDependencies` closure performed a read-modify-write on an inherited dep model (e.g. `$0.envProp.state = "childDefault"`), the mutation bypassed `ModelDependencies.subscript` and mutated the shared `Reference` in place, contaminating the parent's `dependencyModels` entry. The parent's dep loop then hit the `_PendingDepKey` cache (same `modelID`) and reused the child's dep context, causing the parent to see the child's overridden value instead of the anchor's explicit two-step override. Fix: dep model entries are snapshotted via `initialDependencyCopy` before `withContextAdded` runs. If the snapshot's `_stateVersion` differs after `withContextAdded`, the clone (correct pre-RMW state, independent `modelID`) is used for the parent's dep context instead.

- **Swift exclusivity violation when replaced property deinits read sibling properties** — in three call paths (`Context._modify`, `_threadLocalStoreOrLatest`, `Reference.clear`), the old property value could be destroyed while `Reference.state` was still exclusively held. If the value's `deinit` (e.g. a stored closure) read any model property on the same model, it triggered a fatal "Simultaneous accesses" exclusivity violation. Fixed by pinning the old value alive until after exclusive access ends (`defer { _fixLifetime(oldValue) }` / `withExtendedLifetime`).

- **Crash at construction and teardown for models with class-reference-containing properties** — `Reference._genesisState` was previously initialised via `_zeroInit()` (all-zero bytes). For property types whose value representation uses a class reference (e.g. `SwiftUI.ScrollPosition`, any struct with a `class` field), all-zero memory is not a valid Swift value; accessing or retaining it crashes. Fixed by initialising `_genesisState` to `state` (the model's actual initial value) in `Reference.init`. `Reference.clear()` now stores genesis into `state` instead of calling `_zeroInit()`, ensuring all reads on a cleared reference return valid values.

- **`@Model` macro: duplicate conformance extensions** — when a user declared `CustomStringConvertible` on their `@Model` type (in the inheritance clause or a separate extension), the macro would still emit an `extension MyType: CustomStringConvertible, CustomDebugStringConvertible { … }` block. The compiler rejected duplicate conformances. Fixed by checking the real compiler's `protocols` parameter (which only lists unsatisfied conformances) instead of inspecting the inheritance clause; `CustomStringConvertible` and `CustomDebugStringConvertible` are now synthesised independently so a user-provided `description` suppresses only the description extension, not `debugDescription`.

- **Observation silently dropped on non-Apple platforms** — `Observed { … }` and similar consumers stopped firing on Linux, Android, and WASM whenever the read happened on the platform's main thread (e.g. inside `onActivate()` called from `withAnchor()` on Android's JNI-invoked main thread). SwiftModel was registering main-thread accesses against a separate `mainObservationRegistrar` whose `willSet`/`didSet` notifications are bridged through `mainCallQueue { @MainActor in … }` — and on Android the `@MainActor` task never executes because Android's UI thread runs Android's `Looper`, not libdispatch's main queue. Non-Apple platforms now route every access through `backgroundObservationRegistrar`, whose notifications fire synchronously on the mutating thread.

- **`willSet`-before-mutation ordering preserved when already on the main thread** — when the dual-registrar split runs synchronously on the main thread, both registrars now fire `willSet` *before* the caller mutates and `didSet` *after*, matching `ObservationRegistrar`'s documented semantics and the pre-dual-registrar behaviour. When the mutation happens off the main thread, the main registrar's `willSet`/`didSet` continue to fire as a post-mutation bundle on `@MainActor` (the strict pre-mutation ordering isn't reachable without blocking the mutating thread). The background registrar always uses strict ordering on the mutating thread.

- **Simultaneous-access trap when a write expression reads any other model property on the RHS** — `Context.subscript[statePath:isSame:accessBox:]._modify` and the three non-`Model` write overloads of `_ModelSourceBox.subscript[write:access:]` previously `yield`ed `&reference.state[keyPath: …]` directly, holding an exclusive dynamic borrow on `Reference.state` (the class-backed `_State` struct) for the entire duration of the user's mutation expression. Any access on the same `Reference.state` during the yield — read or write, regardless of key path — would trip Swift's law of exclusivity with a fatal `"Simultaneous accesses to 0x…, but modification requires exclusive access"` trap. The patterns that hit this in practice include `model.x = model.y + 1`, `model.x = model.x + 1`, `model.x += model.x`, `model.items.append(model.intValue)`, and the optional-chained `model.x?.field = model.x.map { … } ?? .default` shape (which is what surfaced this in the Imagien editor). Fixed by adopting the same local-copy + write-back pattern that `stateTransaction` already uses: the user's mutation expression runs against a local `var`, the borrow on `reference.state` ends before the yield, and a single write-back store re-acquires it briefly after the yield returns. The companion `_read` fix (commit 776f453) covered the read-then-modify direction; this completes the pair. The fully-anchored `<T: Model>` write subscript already used the safe pattern and is unchanged. A known limitation remains for the pre-anchor / live yield in the `<T: Model>` overload, which cannot pre-read because zero-initialised `@Model` fields trap on key-path read — compound writes through a child `@Model` property during a user-written `init()` whose RHS reads `self` can still trip the check; documented inline.

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
- **`WriteLockOrderingTests`** — regression guard for the writer-vs-reader lock-order race. `writerAcquiresAccessWriteLockAroundEachContextWrite()` installs a `RecordingAccess` (a `ModelAccess` subclass that logs each `acquireWriteLock` / `releaseWriteLock` call) and asserts that `Context._modify` calls them in strict pairs around every property write — catches accidental removal of the calls without depending on timing-sensitive race reproduction. `taskWriteOfContainerPropertyIsAssertedByRequire()` is an end-to-end smoke test using a `ModelContainer`-typed property written from an activation task.
- **`TaskIdSerializationTests`** — regression guard for the `task(id:)` body-interleaving race. Spawns rapid `id` changes against a body that performs a long synchronous tail after a suspension point (mimicking the `OnboardingTests.shortUsernameShowsInlineError` failure pattern); fails with `maxConcurrentBodies > 1` if `_forEachImpl` lets the previous body's tail race the next body's prefix.
- **`ReactiveWaitInfrastructureTests`** — covers the `_pendingExpects` state machine: predicate registration, deadline cancellation via `GlobalTickScheduler`, debounce / quiet-window settle, `bg.onIdle` integration, cancellation propagation, and the all-pass / first-failure semantics that `expect { … }` exposes to user code.
- **`CrossModelObservationTests`** — covers observation paths that span model boundaries (parent reading from child, sibling reading via dependency context, environment-storage propagation visibility).
- **Test target split** — the monolithic `SwiftModelTests` is split into three:
  - `SwiftModelTests` (default) — the bulk of behaviour and regression tests; no `InlineSnapshotTesting` dependency.
  - `SwiftModelSnapshotTests` — `OutputSnapshotTests`, `DebugTests`, `PrivatePropertyTests`, `TransitionsTests`, `AssertIssueSnapshot` helpers. All `InlineSnapshotTesting` usage is contained here; lets us scope `swift-snapshot-testing`'s Apple-only types to a single target.
  - `SwiftModelBenchmarkTests` — `CoalescingBenchmarks`, `LazyContextBenchmarks`, `MemoizePerformanceTests`, `TestTags`. Skipped from the default test plan and from `swift test` invocations on CI (`--skip SwiftModelBenchmarkTests`); run on-demand via the existing `swift-model-benchmarks` Xcode test plan or `swift test --filter SwiftModelBenchmarkTests`.

  Effect on `swift test --skip Foo --skip Bar` CI invocations: the three per-file `--skip` flags collapse into a single `--skip SwiftModelBenchmarkTests`. Effect on local test plans: the default `swift-model` Xcode test plan now runs `SwiftModelTests` + `SwiftModelSnapshotTests` (and the example/macro/main-actor targets as before); `SwiftModelBenchmarkTests` is intentionally omitted. The `swift-model-benchmarks` plan now targets `SwiftModelBenchmarkTests` directly (no `selectedTags: [.benchmark]` filter needed).

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

[Unreleased]: https://github.com/bitofmind/swift-model/compare/1.0.1...HEAD
[1.0.1]: https://github.com/bitofmind/swift-model/compare/1.0.0...1.0.1
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
