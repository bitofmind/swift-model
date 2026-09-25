import Foundation

class ModelAccessReference: @unchecked Sendable {
    var access: ModelAccess? { fatalError() }
}

/// The observation/tracking hook for the SwiftModel framework.
///
/// Subclasses intercept property reads (`willAccess`) and writes (`didModify`) to implement
/// different observation strategies without coupling the model to any specific observer.
///
/// # Concrete subclasses
///
/// - `ModelSetupAccess<M>`: Pre-anchor only. Accumulates dependency overrides and
///   activation closures set via `.withActivation` / `.dependencies {}`. Extracted by
///   `Context.init` and then discarded — never stored on the context (would form a
///   retain cycle: context → access → anchor → context).
///
/// - Bare `ModelAccess(useWeakReference: false)`: Anchor holder. Created by `returningAnchor()`
///   when no other access is present. Its only role is holding `retainedObject = anchor`
///   so the anchor stays alive as long as the model value is held.
///
/// - `TestAccess<Root>`: Exhaustive test observer. Records every read and write for
///   assertion. `shouldPropagateToChildren = true`. Access is propagated via task-locals
///   (`ModelAccess.active` / `ModelAccess.current`): `ModelTester.model` wraps in
///   `usingActiveAccess`, predicate evaluation wraps in `usingActiveAccess`, and
///   `LocalValues`/`EnvironmentContext`/`PreferenceValues` capture `activeAccess` from the
///   model value and restore it via `usingActiveAccess` for their subscript calls.
///
/// - `ViewAccess` (pre-iOS 17 SwiftUI): Registers `context.onModify` callbacks per
///   accessed property and calls `objectWillChange.send()` on changes. Stored weakly
///   on context. `shouldPropagateToChildren = true`.
///
/// - `AccessCollector` (`Observed {}` streams, pre-iOS 17): Collects property accesses
///   during the closure, registers `onModify` callbacks, and re-runs on change. Installed
///   via `ModelAccess.$current` task-local — not on model values.
///   `shouldPropagateToChildren = false`.
///
/// - `LastSeenAccess`: Carries a timestamp and dependency cache on snapshot copies after
///   model destruction. Pure data carrier — no willAccess/didModify behaviour.
///
/// # The three homes of access
///
/// 1. **Model value** (`ModelContext._access: _ModelAccessBox`): Primary home. Carried
///    on the model struct. Read subscripts stamp access onto returned child model values
///    via `withAccessIfPropagateToChildren` — transiently at return time, NOT stored in
///    `_stateHolder.state`. Required so that test predicates and SwiftUI `body` closures
///    can read child model properties without an ambient task-local context.
///
/// 2. **Task-local propagation for metadata storage**: `Context.model` stamps
///    `ModelAccess.active ?? ModelAccess.current` onto the returned model value.
///    `metadataModelContext()` (used by `willAccessStorage`/`didModifyStorage` etc.)
///    reads the same task-locals. Callers ensure the right access is active:
///    `ModelTester.model` and predicate evaluation use `usingActiveAccess(testAccess)`;
///    tasks created during `onActivate()` inherit `ModelAccess.current` via `usingAccess`.
///
/// 3. **Task-local** (`ModelAccess.current` / `ModelAccess.active`): Fallback when the
///    model value has no stored access. `usingAccess(_:)` wraps `onActivate()` so tasks
///    created inside inherit access for TestAccess task counting.
///
/// # shouldPropagateToChildren
///
/// When `true` (TestAccess, ViewAccess), the read subscripts in `_ModelSourceBox` call
/// `withAccessIfPropagateToChildren` on every child model value they return. This stamps
/// the access onto the child value's `_access` box so that subsequent property reads on
/// that value fire `willAccess` — even when no task-local access is active (e.g. in
/// SwiftUI `body` or test predicates).
///
/// The models inside `_stateHolder.state` never carry access; it is applied only to
/// the VALUE returned to the caller (transient, not persisted in stored state).
class ModelAccess: ModelAccessReference, @unchecked Sendable {
    /// Called before a tracked property is read / after it is written on a live context.
    ///
    /// `path` is an autoclosure: the tracked read/write path hands the key path over
    /// lazily, and only an override that keys its bookkeeping by key path (`TestAccess`,
    /// `ViewAccess`, the collectors) evaluates it. This class's own no-op implementations
    /// — which is what a bare anchor-holder access (`returningAnchor()` / `withAnchor()`
    /// with no observer) has — never form it. That matters: the `\_State.prop` literal
    /// is one process-wide object that `_swift_getKeyPath` retains on every evaluation,
    /// and it was the last shared cache line on the 8-thread read path once the observer
    /// tables were keyed by index. Overrides that need the key path more than once should
    /// bind it first (`let path = path()`).
    func willAccess<M: Model, Value>(from context: Context<M>, at path: @autoclosure () -> (KeyPath<M._ModelState, Value> & Sendable)) -> (() -> Void)? { nil }
    func didModify<M: Model, Value>(from context: Context<M>, at path: @autoclosure () -> (KeyPath<M._ModelState, Value> & Sendable)) -> (() -> Void)? { nil }

    func didSend<M: Model, Event>(event: Event, from context: Context<M>) {}

    /// Acquired by `Context._modify` / `Context.stateTransaction` BEFORE acquiring the
    /// context lock, so that writers and readers use the same lock order
    /// (`access.lock` → `context.lock`). Without this, the writer's
    /// `release-context.lock → acquire-access.lock` sequence opened a race window where
    /// the reader (which already holds `access.lock` from inside its predicate
    /// evaluator) could acquire `context.lock`, read the updated `reference.state`, and
    /// run its assertion-clearing pass — all before the writer's post-lock callback got
    /// a chance to record the corresponding `valueUpdates` entry. The clearing pass
    /// would then see no entry to clear, and the entry would survive to the end-of-test
    /// exhaustion check.
    ///
    /// Default: no-op. `TestAccess` overrides to grab its `NSRecursiveLock`. Other
    /// access kinds (ViewAccess, AccessCollector) don't queue any state behind the
    /// reference write, so they don't need this serialization.
    func acquireWriteLock() {}
    func releaseWriteLock() {}

    /// The access whose write lock a writer must take BEFORE the context lock, or `nil` if
    /// this access owns no such lock and is *transparent* to that resolution.
    ///
    /// Default `nil`, matching the no-op `acquireWriteLock` above — and it has to be the
    /// default rather than an opt-out, because most `ModelAccess` subclasses are not
    /// writers at all but short-lived **probes** installed with `usingActiveAccess` to
    /// observe reads: `RegistrarDetector` (run by *every* `Observed` with the default
    /// `coalesceUpdates: true`), `AccessCollector`, `ForceObserver`, `PathCollector`, the
    /// debug and undo collectors. A probe left standing as `ModelAccess.active` used to
    /// *terminate* the holder chain (`ModelAccess.active ?? … ?? ModelAccess.current`) at
    /// itself, so the writer took no write lock and then took the context lock — while a
    /// nested evaluation that ran with the probe cleared (`memoize`'s `observe` does
    /// exactly that, so nested memoizes don't inherit it) resolved the chain down to the
    /// real `TestAccess` and asked for the write lock with the context lock already held.
    /// That B→A against every other writer's A→B deadlocked a downstream test process
    /// (`MemoizeProbeLockInversionTests`). Resolving *through* probes keeps one order for
    /// everybody, and keeps the outer and nested resolutions on the same instance — which
    /// is what makes the recursive re-entry work (`NSRecursiveLock` re-enters on identity,
    /// not on "any `TestAccess`" — see `Context.transaction(writeLockHolder:_:)`).
    ///
    /// Stored rather than overridden: this is read on every write, and the branch is
    /// cheaper than a dynamic dispatch on the write path.
    @inline(__always)
    var writeLockOwner: ModelAccess? { ownsWriteLock ? self : nil }

    /// Called from the prelude of every `TaskCancellable`'s body — i.e. the
    /// FIRST time the task actually gets a CPU slot after being scheduled.
    /// Used by `TestAccess.settle()` to keep its quiet window open until
    /// every freshly-registered task has had a chance to execute at least
    /// once. Without this, settle would happily declare "quiet" while an
    /// `onActivate` task was still sitting in the cooperative pool waiting
    /// to be scheduled, then the task would later run and write a property
    /// AFTER settle's exhaustivity baseline had been reset.
    ///
    /// Default: no-op. `TestAccess` overrides to fire `_noteActivity`.
    func taskBodyStarted() {}

    /// SPIKE (async teardown work): the store that hosts `node.onTeardown` work once
    /// its model has been removed. `nil` in production — the work runs as a plain,
    /// untracked task. `TestAccess` returns a store it owns, so the work stays visible
    /// to `settle()` and the end-of-test task check after the model is gone.
    var teardownWorkStore: Cancellations? { nil }

    /// SPIKE: `true` while the test harness tears down the model tree at the end of a
    /// test — removal calls are skipped then. Always `false` in production.
    var isInHarnessTeardown: Bool { false }

    /// Records that a reactive body (`node.forEach` / `node.onChange`) delivered
    /// an element, keyed by its source location. Powers `settle()`'s runaway
    /// diagnostic: a registration that keeps firing right up to a settle timeout
    /// is almost certainly a non-`isSame` source or a feedback loop. Default:
    /// no-op (zero cost in production — `ModelAccess.current` is nil or a
    /// non-test access). `TestAccess` overrides to count.
    func reactiveBodyFired(_ fileAndLine: FileAndLine) {}

    /// Erased executor-drain hooks so the free `waitUntil` (which only has
    /// `ModelAccess.current`, not the generic `TestAccess<Root>`) can drive the
    /// model to a quiescence fixpoint. Defaults are inert; `TestAccess`
    /// overrides them when the per-test harness executor is active.
    var hasTestExecutorErased: Bool { false }
    func driveToStableFixpointErased() async -> Bool { true }

    var shouldPropagateToChildren: Bool { false }

    /// Returns the `ModelAccess` to install on a child model when propagating observation.
    ///
    /// The default implementation returns `self` when `shouldPropagateToChildren` is `true`,
    /// or `nil` to stop propagation. Subclasses can override this to return a different
    /// access instance (e.g. a depth-decremented wrapper) instead of `self`.
    func propagatingAccess() -> ModelAccess? { shouldPropagateToChildren ? self : nil }

    @TaskLocal static var isInModelTaskContext = false
    @TaskLocal static var current: ModelAccess?
    @TaskLocal static var active: ModelAccess?

    override var access: ModelAccess? {
        self
    }

    final class Weak: ModelAccessReference, @unchecked Sendable {
        weak var _access: ModelAccess?

        init(_ access: ModelAccess? = nil) {
            self._access = access
        }

        override var access: ModelAccess? {
            _access
        }
    }

    private var _weak: Weak?

    /// Retains an associated object (e.g. a ModelAnchor) for the lifetime of this access object.
    /// Used by `withAnchor()` as a cross-platform alternative to `objc_setAssociatedObject`.
    var retainedObject: AnyObject?

    var reference: ModelAccessReference {
        _weak ?? self
    }

    typealias Reference = ModelAccessReference

    /// See `writeLockOwner`. Only `TestAccess` passes `true`.
    let ownsWriteLock: Bool

    init(useWeakReference: Bool, ownsWriteLock: Bool = false) {
        self.ownsWriteLock = ownsWriteLock
        if useWeakReference {
            let weak = Weak()
            _weak = weak
            super.init()
            weak._access = self
        } else {
            super.init()
        }
    }
}

extension Model {
    var access: ModelAccess? {
        modelContext.access
    }

    func withAccess(_ access: ModelAccess?) -> Self {
        var model = self
        model.modelContext.access = access
        return model
    }

    func withAccessIfPropagateToChildren(_ access: ModelAccess?) -> Self {
        var model = self
        if let childAccess = access?.propagatingAccess() {
            model.modelContext.access = childAccess
        }
        return model
    }
}

func usingAccess<T>(_ access: ModelAccess?, operation: () throws -> T) rethrows -> T {
    try ModelAccess.$current.withValue(access, operation: operation)
}

func usingActiveAccess<T>(_ access: ModelAccess?, operation: () throws -> T) rethrows -> T {
    try ModelAccess.$active.withValue(access, operation: operation)
}
