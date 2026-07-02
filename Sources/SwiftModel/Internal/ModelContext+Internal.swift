import Foundation
import Dependencies

extension ModelContext {
    /// Returns the backing Reference unless this is a live/internal-access copy (isLive == true).
    var reference: Context<M>.Reference? {
        _source._isLive ? nil : _source.reference
    }

    var initial: Context<M>.Reference? {
        if let reference, reference.lifetime == .initial {
            return reference
        } else {
            return nil
        }
    }

    var context: Context<M>? {
        _source.reference.context ?? _source.reference.materializeLazyContext()
    }

    var modelID: ModelID {
        _source.reference.modelID
    }

    var lifetime: ModelLifetime {
        _source._isLive ? .initial : _source.reference.lifetime
    }

    func enforcedContext(_ function: StaticString = #function) -> Context<M>? {
        enforcedContext("Calling \(function) on an unanchored model is not allowed and has no effect")
    }

    func enforcedContext(_ message: @autoclosure () -> String) -> Context<M>? {
        guard let context else {
            reportIssue(message())
            return nil
        }

        return context
    }

    var modifyContext: Context<M>? {
        let src = _source
        if src._isLive { return nil }  // internal direct-access copy — bypass
        if let context = src.reference.context { return context }
        // No live context — check for snapshot (warn) vs pre-anchor (silent).
        if src.reference.isSnapshot {
            switch src.reference.lifetime {
            case .frozenCopy:
                if !threadLocals.isApplyingSnapshot {
                    reportIssue("Modifying a frozen copy of a model is not allowed and has no effect")
                }
            case .destructed:
                if let access = access as? LastSeenAccess, -access.timestamp.timeIntervalSinceNow < lastSeenTimeToLive {
                    break // SwiftUI accessing shortly after destruction — no warning
                }
                reportIssue("Modifying a destructed model is not allowed and has no effect")
            default:
                break
            }
        }
        return nil
    }

    /// Transitions source to a frozen snapshot — used by shallowCopy.
    mutating func makeFrozen(id: ModelID) {
        let ref = _source.reference
        // Copy under the live hierarchy lock: the whole-struct read otherwise
        // races concurrent locked writers / `Reference.clear()` (torn copy).
        guard let state = ref.withHierarchyLockIfLive({ () -> M._ModelState? in
            ref._stateCleared ? nil : ref.state
        }) else { return }
        _source = _ModelSourceBox(frozen: state, id: id)
    }

    /// Transitions source to a lastSeen snapshot — used by lastSeen snapshot.
    mutating func makeLastSeen(id: ModelID) {
        let ref = _source.reference
        // Same locked-copy discipline as `makeFrozen`.
        guard let state = ref.withHierarchyLockIfLive({ () -> M._ModelState? in
            ref._stateCleared ? nil : ref.state
        }) else { return }
        _source = _ModelSourceBox(lastSeen: state, id: id)
    }

    /// Sets the source to a new Reference (non-live) — used by anchoring and MakeInitialTransformer.
    mutating func setReference(_ ref: Context<M>.Reference) {
        _source = _ModelSourceBox(reference: ref)
    }

    init(context: Context<M>) {
        _access = _ModelAccessBox()
        _source = _ModelSourceBox(reference: context.reference)
    }
}

extension Model {
    var lifetime: ModelLifetime {
        modelContext.lifetime
    }
}

extension ModelContainer {
    mutating func withContextAdded<M: Model, Container: ModelContainer>(context: Context<M>, containerPath: WritableKeyPath<M, Container>, elementPath: WritableKeyPath<Container, Self>, includeSelf: Bool, hierarchyLockHeld: Bool = false) {
        var visitor = AnchorVisitor(value: self, context: context, containerPath: containerPath, elementPath: elementPath, hierarchyLockHeld: hierarchyLockHeld)
        visit(with: &visitor, includeSelf: includeSelf)
        self = visitor.value
    }

    func forEachContext(callback: (AnyContext) -> Void) {
        withoutActuallyEscaping(callback) { callback in
            _ = transformModel(with: ForEachTransformer(callback: callback))
        }
    }

    func activate() {
        var contexts: [AnyContext] = []
        forEachContext { contexts.append($0) }
        for context in contexts {
            _ = context.onActivate()
        }
    }
}

private struct ForEachTransformer: ModelTransformer {
    let callback: (AnyContext) -> Void
    func transform<M: Model>(_ model: inout M) -> Void {
        if let context = model.context {
            callback(context)
        }
    }
}

extension Model {
    var reference: Context<Self>.Reference? { modelContext.reference }

    var context: Context<Self>? {
        reference?.context
    }

    var anyContext: AnyContext? {
        reference?.context
    }

    var isInitial: Bool {
        lifetime == .initial
    }

    // `modelID` is declared as public API in Model.swift (per-instance identity).

    mutating func withContextAdded(context: Context<Self>) {
        // Transition @Model pending state to live before traversal reads _$modelSource paths.
        var mc = modelContext
        mc._source._transitionToLive()
        modelContext = mc
        var visitor = AnchorVisitor(value: self, context: context, containerPath: \.self, elementPath: \.self)
        visit(with: &visitor, includeSelf: true)
        self = visitor.value
    }
}

extension ModelContext {
    /// Fires `activeAccess.willAccess` for the given path (AccessCollector / ViewAccess / TestAccess).
    /// ObservationRegistrar calls for _State paths are handled by `willAccessDirect` (in Context),
    /// and for synthetic paths (storage/preference/parents) by `willAccessSyntheticPath` (in Context).
    func willAccess<T>(at path: KeyPath<M._ModelState, T>&Sendable) -> (() -> Void)? {
        // Suppress reads happening inside a memoize's async `observe()` body. The
        // outer `withObservationTracking` in `ObservationTracking.observe()` already
        // captures the deps for memoize's own re-evaluation; the calling view's
        // `ViewAccess` (reached here via the stamped-access fall-through that
        // `usingActiveAccess(nil)` cannot clear) must not accumulate them too.
        // See `ThreadLocals.isInsideMemoizeObserve`.
        // Also suppress inside a `withUntrackedModelReads` scope — no dependency
        // registration for synthetic-path reads (memoize/environment/preference).
        let tl = threadLocals
        if tl.isInsideMemoizeObserve || tl.untrackedReads { return nil }
        guard let activeAccess, let context else { return nil }
        return activeAccess.willAccess(from: context, at: path)
    }

    /// Fires `activeAccess.didModify` and drains the main call queue.
    /// ObservationRegistrar calls for _State paths are handled by `invokeDidModifyDirect` (in Context),
    /// and for synthetic paths (storage/preference/parents) by `invokeDidModifySyntheticPath` (in Context).
    ///
    /// Returns the active-access callback (from TestAccess/AccessCollector) without executing it.
    /// The caller is responsible for running the returned closure **after releasing the context lock**
    /// to avoid a lock-ordering deadlock.
    @discardableResult
    func invokeDidModify<T>(at path: KeyPath<M._ModelState, T>&Sendable) -> (() -> Void)? {
        let callback: (() -> Void)?
        if let activeAccess, let context {
            callback = activeAccess.didModify(from: context, at: path)
        } else {
            callback = nil
        }
        // Only drain main-thread observation work if it's enabled for this context.
        // When `useMainThreadObservation == false`, no main-thread notifications were ever
        // enqueued — `drainIfOnMain` would no-op safely either way, but skipping the call
        // makes the intent explicit and removes the `Thread.isMainThread` check on the
        // hot path for non-Apple platforms.
        if let context, context.useMainThreadObservation,
           threadLocals.pendingObservationNotifications == nil {
            context.mainCallQueue.drainIfOnMain()
        }
        return callback
    }

}

extension ModelContext {
    func transaction<Value, T>(with model: M, at path: WritableKeyPath<M, Value>&Sendable, statePath: WritableKeyPath<M._ModelState, Value>&Sendable, modify: (inout Value) throws -> T, isSame: ((Value, Value) -> Bool)?) rethrows -> T {
        guard let context = modifyContext else {
            if let reference, reference.lifetime == .initial {
                // Unanchored: write through the property setter so mutations reach ref._state.
                var mutableModel = model
                return try modify(&mutableModel[keyPath: path])
            } else {
                var value = model[keyPath: path]
                return try modify(&value)
            }
        }

        return try context.transaction(at: path, statePath: statePath, isSame: isSame, modelContext: self, modify: modify)
    }

    func transaction<T>(_ callback: () throws -> T) rethrows -> T {
        if let context {
            // Compute `writeLockHolder` here, using the same chain
            // `stateTransaction` does (`ModelAccess.active ?? accessBox._reference?.access
            // ?? ModelAccess.current`), so the outer transaction's
            // `TestAccess.lock` matches the nested writes' `TestAccess.lock`
            // by identity. See the long comment at `Context.transaction(writeLockHolder:_:)`.
            let writeLockHolder = ModelAccess.active ?? _access._reference?.access ?? ModelAccess.current
            return try context.transaction(writeLockHolder: writeLockHolder, callback)
        } else {
            return try callback()
        }
    }

    func _dependency<D: DependencyKey>() -> D where D.Value == D {
        ModelNode(_$modelContext: self)[D.self]
    }

    func stateTransaction<T>(_ callback: () throws -> T) rethrows -> T {
        if let context {
            // Same writeLockHolder chain as `transaction(_:)` above.
            let writeLockHolder = ModelAccess.active ?? _access._reference?.access ?? ModelAccess.current
            return try context.transaction(writeLockHolder: writeLockHolder, callback)
        } else {
            return try callback()
        }
    }
}
