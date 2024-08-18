import Foundation

class ModelAccessReference: @unchecked Sendable {
    var access: ModelAccess? { fatalError() }
}

class ModelAccess: ModelAccessReference, @unchecked Sendable {
    func willAccess<M: Model, Value>(_ model: M, at path: WritableKeyPath<M, Value>) -> (() -> Void)? { nil }
    func willModify<M: Model, Value>(_ model: M, at path: WritableKeyPath<M, Value>) -> (() -> Void)? { nil }

    func didSend<M: Model, Event>(event: Event, from context: Context<M>) {}

    var shouldPropagateToChildren: Bool { false }

    @TaskLocal static var isInModelTaskContext = false
    @TaskLocal static var current: ModelAccess?

    override var access: ModelAccess? {
        self
    }

    private final class Weak: ModelAccessReference, @unchecked Sendable {
        weak var _access: ModelAccess?

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
        _$modelContext.access
    }

    func withAccess(_ access: ModelAccess?) -> Self {
        var model = self
        model._$modelContext.access = access
        return model
    }
}
