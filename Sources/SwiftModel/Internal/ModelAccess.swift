import Foundation

class ModelAccessReference: @unchecked Sendable {
    var access: ModelAccess? { fatalError() }
}

class ModelAccess: ModelAccessReference, @unchecked Sendable {
    func willAccess<M: Model, Value>(_ model: M, at path: KeyPath<M, Value>&Sendable) -> (() -> Void)? { nil }
    func didModify<M: Model, Value>(_ model: M, at path: KeyPath<M, Value>&Sendable) -> (() -> Void)? { nil }

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
