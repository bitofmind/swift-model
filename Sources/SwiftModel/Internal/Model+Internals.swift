import Foundation
import Dependencies
import Observation
#if canImport(Dispatch)
import Dispatch
#endif

/// Returns whether the current execution context is the main thread.
/// On WASI (single-threaded), this is always true.
var isOnMainThread: Bool {
    #if os(WASI)
    return true
    #else
    return Thread.isMainThread
    #endif
}

/// Internal bridge so all framework code can access the model context directly
/// without going through the public `_context` access token.
extension Model {
    var modelContext: ModelContext<Self> {
        get { _context._$modelContext }
        set { _updateContext(ModelContextUpdate(newValue)) }
    }
}

extension Model {
    func assertInitialState(function: String = #function) {
        // Pre-anchor models (not live, no context, no snapshot) may be .destructed after a
        // previous test run (re-anchorable static dep models). Accept both .initial and .destructed.
        let src = modelContext._source
        let isPreAnchor = !src._isLive && src.reference.context == nil && !src.reference.isSnapshot
        let ok = isPreAnchor ? (lifetime == .initial || lifetime == .destructed) : (lifetime == .initial)
        if !ok {
            reportIssue("Calling \(function) on an anchored model is not allowed and has no effect")
        }
    }

    func withSetupAccess(modify: (ModelSetupAccess<Self>) -> Void, function: String = #function) -> Self {
        assertInitialState(function: function)

        let access = (access as? ModelSetupAccess<Self>) ?? ModelSetupAccess<Self>()
        modify(access)
        return withAccess(access)
    }

    var modelSetup: ModelSetupAccess<Self>? {
        access as? ModelSetupAccess<Self>
    }
}

final class ModelSetupAccess<M: Model>: ModelAccess, @unchecked Sendable {
    var dependencies: [(inout ModelDependencies) -> Void] = []
    var activations: [(M) -> Void] = []

    var allDependencies: ((inout ModelDependencies) -> Void)? {
        if dependencies.isEmpty { return nil }
        return { [dependencies = dependencies] in
            for dependency in dependencies {
                dependency(&$0)
            }
        }
    }

    init() {
        super.init(useWeakReference: false)
    }
}

extension Model {
    var typeDescription: String {
        String(describing: type(of: self))
    }

    func transaction<T>(_ callback: () throws -> T) rethrows -> T {
        try modelContext.transaction(callback)
    }
}

extension Model {
    var noAccess: Self {
        var copy = self
        copy.modelContext.access = nil
        return copy
    }

    var shallowCopy: Self {
        let src = modelContext._source
        if src._isLive { return self }  // internal direct-access copy — return as-is
        let ref = src.reference
        if ref.lifetime == .frozenCopy { return self }  // already a frozen snapshot
        if ref.context != nil {
            // Anchored: freeze the live state.
            // `makeFrozen` reads from `_stateHolder` without the lock (same as original behavior).
            var copy = self
            copy.modelContext.makeFrozen(id: ref.modelID)
            copy.modelContext.access = nil
            return copy
        } else if ref.isSnapshot {
            // lastSeen snapshot (destructed) — freeze without clearing access.
            var copy = self
            copy.modelContext.makeFrozen(id: ref.modelID)
            return copy
        }
        return self  // pre-anchor unlinked copy
    }
}

extension Model {
    func enforcedContext(_ function: StaticString = #function) -> Context<Self>? {
        enforcedContext("Calling \(function) on an unanchored model is not allowed and has no effect")
    }

    func enforcedContext(_ message: @autoclosure () -> String) -> Context<Self>? {
        guard let context else {
            reportIssue(message())
            return nil
        }

        return context
    }
}

