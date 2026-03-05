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
    /// Internal shorthand to access the underlying ModelContext without going through `node`.
    var _$modelContext: ModelContext<Self> {
        node._$modelContext
    }

    var access: ModelAccess? {
        _$modelContext.access
    }

    func withAccess(_ access: ModelAccess?) -> Self {
        var ctx = _$modelContext
        ctx.access = access
        var model = self
        model.node = ModelNode(_$modelContext: ctx)
        return model
    }

    func withAccessIfPropagateToChildren(_ access: ModelAccess?) -> Self {
        guard let access, access.shouldPropagateToChildren else { return self }
        return withAccess(access)
    }

    mutating func withSource(_ source: ModelContext<Self>.Source) {
        var ctx = _$modelContext
        ctx.source = source
        node = ModelNode(_$modelContext: ctx)
    }
}

func usingAccess<T>(_ access: ModelAccess?, operation: () throws -> T) rethrows -> T {
    try ModelAccess.$current.withValue(access, operation: operation)
}

func usingActiveAccess<T>(_ access: ModelAccess?, operation: () throws -> T) rethrows -> T {
    try ModelAccess.$active.withValue(access, operation: operation)
}
