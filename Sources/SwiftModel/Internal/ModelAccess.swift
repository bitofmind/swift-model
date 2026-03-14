import Foundation

class ModelAccessReference: @unchecked Sendable {
    var access: ModelAccess? { fatalError() }
}

class ModelAccess: ModelAccessReference, @unchecked Sendable {
    func willAccess<M: Model, Value>(_ model: M, at path: KeyPath<M, Value>&Sendable) -> (() -> Void)? { nil }
    func didModify<M: Model, Value>(_ model: M, at path: KeyPath<M, Value>&Sendable) -> (() -> Void)? { nil }

    func didSend<M: Model, Event>(event: Event, from context: Context<M>) {}

    var shouldPropagateToChildren: Bool { false }

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
        if let access, access.shouldPropagateToChildren {
            model.modelContext.access = access
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
