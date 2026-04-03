import Foundation
import Dependencies
import Observation

extension ModelContext {
    var reference: Context<M>.Reference? {
        switch source {
        case let .reference(reference):
            return reference

        case .frozenCopy, .lastSeen:
            return nil
        }
    }

    var initial: Context<M>.Reference? {
        if let reference, reference.lifetime == .initial {
            return reference
        } else {
            return nil
        }
    }

    var context: Context<M>? {
        reference?.context
    }

    var modelID: ModelID {
        switch source {
        case let .reference(reference): reference.modelID
        case let .frozenCopy(id: id), let .lastSeen(id: id): id
        }
    }

    var lifetime: ModelLifetime {
        switch source {
        case let .reference(reference): reference.lifetime
        case .frozenCopy: .frozenCopy
        case .lastSeen: .destructed
        }
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
        switch source {
        case let .reference(reference):
            return reference.context
        case .frozenCopy:
            reportIssue("Modifying a frozen copy of a model is not allowed and has no effect")
            return nil
        case .lastSeen:
            if let access = access as? LastSeenAccess, -access.timestamp.timeIntervalSinceNow < lastSeenTimeToLive {
                // Most likely being accessed by SwiftUI shortly after being destructed, no need for runtime warning.
                return nil
            }

            reportIssue("Modifying a destructed model is not allowed and has no effect")
            return nil
        }
    }
}

extension Model {
    var lifetime: ModelLifetime {
        modelContext.lifetime
    }
}

extension ModelContainer {
    mutating func withContextAdded<M: Model, Container: ModelContainer>(context: Context<M>, containerPath: WritableKeyPath<M, Container>, elementPath: WritableKeyPath<Container, Self>, includeSelf: Bool) {
        var visitor = AnchorVisitor(value: self, context: context, containerPath: containerPath, elementPath: elementPath)
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

extension ModelContext {
    init(context: Context<M>) {
        _access = nil
        source = .reference(context.reference)
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
        reference?.lifetime == .initial
    }

    var modelID: ModelID {
        modelContext.modelID
    }

    mutating func withContextAdded(context: Context<Self>) {
        var visitor = AnchorVisitor(value: self, context: context, containerPath: \.self, elementPath: \.self)
        visit(with: &visitor, includeSelf: true)
        self = visitor.value
    }
}

extension ModelContext {
    func willAccess<T>(_ model: M, at path: KeyPath<M, T>&Sendable) -> (() -> Void)? {
        // Skip ObservationRegistrar tracking during AccessCollector performUpdate recomputation.
        //
        // When both conditions hold:
        //   1. isInsideAsyncPerformUpdate == true  (we're inside a coalesced performUpdate)
        //   2. ModelAccess.active != nil            (we're inside usingActiveAccess(collector))
        // we are in an AccessCollector recomputation that has no outer withObservationTracking
        // scope. Calling observable.access here would register nothing useful but acquires the
        // registrar's internal lock, causing severe lock contention on Linux (~133K calls/iteration
        // for a sort over 100 items × 100 mutations with NoCoalescing).
        //
        // The OT (withObservationTracking) path sets isInsideAsyncPerformUpdate=true too, but
        // inside withObservationTracking, ModelAccess.active is nil — so the guard is not
        // triggered and the tracking works correctly.
        //
        // Initial AccessCollector setup and ForceObserver registration also do NOT set
        // isInsideAsyncPerformUpdate, so they are unaffected.
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), let context, context.isObservable,
           let observable = model as? any Observable&Model,
           !(threadLocals.isInsideAsyncPerformUpdate && ModelAccess.active != nil) {
            observable.access(path: path, from: context)
        }

        return activeAccess?.willAccess(model, at: path)
    }


    /// Performs all post-modify observation notifications inline (or deferred when batching).
    /// Called directly from Context._modify/transaction and any other post-modify site.
    ///
    /// Returns the active-access callback (from TestAccess/AccessCollector) without executing it.
    /// The caller is responsible for running the returned closure **after releasing the context lock**
    /// to avoid a lock-ordering deadlock: TestAccess.didModify's closure calls rootPaths, which
    /// acquires the parent context lock (child → parent order), while onAnyModification's
    /// withModificationActiveCount holds the parent lock and tries to acquire child locks
    /// (parent → child order). Running the closure post-lock breaks this cycle.
    ///
    /// For call sites that are already outside any context lock (didModifyStorage,
    /// didModifyPreference, etc.) the returned closure may be called immediately with `?()`.
    @discardableResult
    func invokeDidModify<T>(_ model: M, at path: KeyPath<M, T>&Sendable) -> (() -> Void)? {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), let context, context.isObservable, let observable = model as? any Observable&Model {
            if threadLocals.pendingObservationNotifications != nil {
                // Batched: defer registrar notifications; collect activeAccess callback for
                // per-write granularity (caller will execute it immediately since it is already
                // outside the context lock).
                let callback = activeAccess?.didModify(model, at: path)
                threadLocals.pendingObservationNotifications!.append {
                    observable.willSet(path: path, from: context)
                    observable.didSet(path: path, from: context)
                }
                return callback
            } else {
                // Normal: fire registrar notifications inline; return activeAccess callback
                // for the caller to execute after releasing the context lock.
                observable.willSet(path: path, from: context)
                defer { observable.didSet(path: path, from: context) }
                let callback = activeAccess?.didModify(model, at: path)
                context.mainCallQueue.drainIfOnMain()
                return callback
            }
        } else {
            let callback = activeAccess?.didModify(model, at: path)
            if threadLocals.pendingObservationNotifications == nil {
                (self.context?.mainCallQueue ?? mainCall).drainIfOnMain()
            }
            return callback
        }
    }

}

extension ModelNode {
    func access<T>(path: WritableKeyPath<M, T>&Sendable, from model: M) {
        _$modelContext.willAccess(model, at: path)?()
    }

    func withMutation<Member, T>(of model: M, keyPath: WritableKeyPath<M, Member>&Sendable, _ mutation: () throws -> T) rethrows -> T {
        defer { _$modelContext.invokeDidModify(model, at: keyPath)?() }
        return try mutation()
    }
}

extension ModelContext {
    subscript<T>(model: M, path: WritableKeyPath<M, T>&Sendable, isSame: ((T, T) -> Bool)?) -> T {
        _read {
            if threadLocals.forceDirectAccess {
                yield model[keyPath: path]
            } else {
                switch source {
                case let .reference(reference):
                    if let context = reference.context {
                        yield context[path, willAccess(model, at: path)]
                    } else if let lastSeenValue = reference.model  {
                        yield lastSeenValue[keyPath: path]
                    } else {
                        yield model[keyPath: path]
                    }

                case .frozenCopy, .lastSeen:
                    yield model[keyPath: path]
                }
            }
        }

        nonmutating _modify {
            guard let context = modifyContext else {
                if let reference, reference.lifetime == .initial {
                    yield &reference[fallback: model][keyPath: path]
                } else {
                    var model = model
                    yield &model[keyPath: path]
                }
                return
            }

            // Use the typed subscript overload to avoid allocating a didModify closure.
            // Observation notifications are performed inline after the isSame check.
            yield &context[path, isSame, self]
        }
    }

    func transaction<Value, T>(with model: M, at path: WritableKeyPath<M, Value>&Sendable, modify: (inout Value) throws -> T, isSame: ((Value, Value) -> Bool)?) rethrows -> T {
        guard let context = modifyContext else {
            if let reference, reference.lifetime == .initial {
                return try modify(&reference[fallback: model][keyPath: path])
            } else {
                var value = model[keyPath: path]
                return try modify(&value)
            }
        }

        // Use the typed transaction overload to avoid allocating a postModify closure.
        // Observation notifications are performed inline after the isSame check.
        return try context.transaction(at: path, isSame: isSame, modelContext: self, modify: modify)
    }

    func transaction<T>(_ callback: () throws -> T) rethrows -> T {
        if let context {
            return try context.transaction(callback)
        } else {
            return try callback()
        }
    }

    func _dependency<D: DependencyKey>() -> D where D.Value == D {
        ModelNode(_$modelContext: self)[D.self]
    }
}
