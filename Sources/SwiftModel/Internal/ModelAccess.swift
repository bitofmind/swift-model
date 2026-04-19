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
    func willAccess<M: Model, Value>(from context: Context<M>, at path: KeyPath<M._ModelState, Value>&Sendable) -> (() -> Void)? { nil }
    func didModify<M: Model, Value>(from context: Context<M>, at path: KeyPath<M._ModelState, Value>&Sendable) -> (() -> Void)? { nil }

    func didSend<M: Model, Event>(event: Event, from context: Context<M>) {}

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

    init(useWeakReference: Bool) {
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
