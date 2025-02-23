import Foundation
import Dependencies
import OrderedCollections
import IssueReporting

final class Context<M: Model>: AnyContext, @unchecked Sendable {
    private let activations: [(M) -> Void]
    private(set) var modifyCallbacks: [PartialKeyPath<M>: [Int: (Bool) -> (() -> Void)?]] = [:]
    let reference: Reference
    var readModel: M
    var modifyModel: M
    private var isMutating = false

    @Dependency(\.uuid) private var dependencies

    init(model: M, lock: NSRecursiveLock, dependencies: (inout ModelDependencies) -> Void, parent: AnyContext?) {
        if model.lifetime != .initial {
            reportIssue("It is not allowed to add an already anchored or fozen model, instead create new instance.")
        }

        readModel = model.initialCopy
        modifyModel = readModel

        let modelSetup = model.modelSetup
        self.activations = modelSetup?.activations ?? []
        reference = readModel.reference ?? Reference(modelID: model.modelID)
        super.init(lock: lock, parent: parent)

        var dependencyModels: [AnyHashable: any Model] = [:]
        Dependencies.withDependencies(from: parent ?? self) {
            var contextDependencies = ModelDependencies(dependencies: $0)
            dependencies(&contextDependencies)
            for dependency in modelSetup?.dependencies ?? [] {
                dependency(&contextDependencies)
            }

            $0 = contextDependencies.dependencies
            dependencyModels = contextDependencies.models
        } operation: {
            _dependencies = Dependency(\.uuid)
        }

        readModel.withContextAdded(context: self)
        readModel._$modelContext.access = nil
        modifyModel = readModel
        reference.setContext(self)

        withPostActions { postActions in
            for (key, model) in dependencyModels {
                var model = model
                setupModelDependency(&model, cacheKey: nil, postSetups: &postActions)
                dependencyCache[key] = model
            }
        }
    }

    deinit {
        //print("Context deinit: \(type(of: self))")
    }

    override func onActivate() -> Bool {
        let shouldActivate = super.onActivate()

        if shouldActivate {
            AnyCancellable.$contexts.withValue(AnyCancellable.contexts + [CancellableKey(key: ContextCancellationKey.onActivate)]) {
                model.onActivate()
            }

            for activation in activations {
                activation(model)
            }
        }

        for child in lock(allChildren) {
            _ = child.onActivate()
        }

        return shouldActivate
    }

    override func onRemoval(callbacks: inout [() -> Void]) {
        super.onRemoval(callbacks: &callbacks)
        let modifies = modifyCallbacks.values.flatMap({ $0.values })
        modifyCallbacks.removeAll()

        callbacks.append {
            for cont in modifies {
                cont(true)?()
            }
        }

        guard !_XCTIsTesting || AnyContext.keepLastSeenAround else {
            reference.destruct(nil)
            return
        }

        let lastSeenValue = readModel.lastSeen(at: Date(), dependencyCache: dependencyCache)
        reference.destruct(lastSeenValue)

        Task {
            try? await Task.sleep(nanoseconds: NSEC_PER_MSEC*UInt64(lastSeenTimeToLive*1000))
            reference.clear()
        }
    }

    func sendEvent(_ event: Any, to relation: ModelRelation, context: AnyContext) {
        let eventInfo = EventInfo(event: event, context: context)
        sendEvent(eventInfo, to: relation)
    }

    func onModify<T>(for path: KeyPath<M, T>&Sendable, _ callback: @Sendable @escaping (Bool) -> (() -> Void)?) -> @Sendable () -> Void {
        guard !isDestructed else {
            return {}
        }

        let key = generateKey()
        lock {
            modifyCallbacks[path, default: [:]][key] = callback
        }

        return { [weak self] in
            guard let self else { return }
            self.lock {
                _ = self.modifyCallbacks[path]?.removeValue(forKey: key)
            }
        }
    }

    override var typeDescription: String {
        String(describing: M.self)
    }

    override var selfPath: AnyKeyPath { \M.self }

    var model: M {
        lock(readModel)
    }

    override var anyModel: any Model {
        model
    }

    func updateContext<T: Model>(for model: inout T, at path: WritableKeyPath<M, T>){
        guard !isDestructed else { return }
        model.withContextAdded(context: self, containerPath: path, elementPath: \.self, includeSelf: true)
    }

    private var modelRefs: Set<ModelRef> = []

    func updateContext<C: ModelContainer>(for container: inout C, at path: WritableKeyPath<M, C>) -> [AnyContext] {
        guard !isDestructed else { return [] }

        return lock {
            let prevChildren = (children[path] ?? [:])
            let prevRefs = Set(prevChildren.keys)

            modelRefs.removeAll(keepingCapacity: true)
            container.withContextAdded(context: self, containerPath: path, elementPath: \.self, includeSelf: false)

            let oldRefs = prevRefs.subtracting(modelRefs)
            return oldRefs.map { prevChildren[$0]! }
        }
    }

    subscript<T>(path: KeyPath<M, T>, callback: (() -> Void)? = nil) -> T {
        _read {
            lock.lock()
            if unprotectedIsDestructed {
                if let last = reference.model {
                    yield last[keyPath: path]
                } else {
                    yield readModel[keyPath: path]
                }
            } else {
                if isMutating { // Handle will and did set recursion
                    yield modifyModel[keyPath: path]
                } else {
                    yield readModel[keyPath: path]
                }
                callback?()
            }
            lock.unlock()
        }
    }

    subscript<T>(path: WritableKeyPath<M, T>, isSame: ((T, T) -> Bool)?, callback: (() -> Void)? = nil) -> T {
        _read {
            lock.lock()
            if unprotectedIsDestructed {
                if let last = reference.model {
                    yield last[keyPath: path]
                } else {
                    yield readModel[keyPath: path]
                }
            } else {
                if isMutating { // Handle will and did set recursion
                    yield modifyModel[keyPath: path]
                } else {
                    yield readModel[keyPath: path]
                }
                callback?()
            }
            lock.unlock()
        }
        _modify {
            lock.lock()
            if unprotectedIsDestructed {
                if var last = reference.model {
                    yield &last[keyPath: path]
                    reference.destruct(last)
                } else {
                    var value = readModel[keyPath: path]
                    yield &value
                }
                lock.unlock()
            } else {
                yield &modifyModel[keyPath: path]

                if let isSame, isSame(modifyModel[keyPath: path], readModel[keyPath: path]) {
                    return lock.unlock()
                }

                didModify()
                isMutating = true
                readModel[keyPath: path] = modifyModel[keyPath: path] // handle exclusivity access with recursive calls
                isMutating = false
                callback?()
                var postLockCallbacks: [() -> Void] = []
                onPostTransaction(callbacks: &postLockCallbacks) { postCallbacks in
                    for callback in (self.modifyCallbacks[path] ?? [:]).values {
                        if let postCallback = callback(false) {
                            postCallbacks.append(postCallback)
                        }
                    }
                    self.didModify(callbacks: &postCallbacks)
                }
                lock.unlock()

                for plc in postLockCallbacks { plc() }
            }
        }
    }

    func transaction<Value, T>(at path: WritableKeyPath<M, Value>, isSame: ((Value, Value) -> Bool)?, callback: (() -> Void)? = nil, modify: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        let result: T
        if var last = reference.model {
            result = try modify(&last[keyPath: path])
            reference.destruct(last)
            lock.unlock()
        } else {
            result = try modify(&modifyModel[keyPath: path])

            if let isSame, isSame(modifyModel[keyPath: path], readModel[keyPath: path]) {
                lock.unlock()
                return result
            }

            didModify()
            isMutating = true
            readModel[keyPath: path] = modifyModel[keyPath: path] // handle exclusivity access with recursive calls
            isMutating = false
            callback?()

            var postLockCallbacks: [() -> Void] = []
            onPostTransaction(callbacks: &postLockCallbacks) { postCallbacks in
                for callback in (self.modifyCallbacks[path] ?? [:]).values {
                    if let postCallback = callback(false) {
                        postCallbacks.append(postCallback)
                    }
                }
                self.didModify(callbacks: &postCallbacks)
            }

            lock.unlock()

            for plc in postLockCallbacks { plc() }
        }
        return result
    }

    func transaction<T>(_ callback: () throws -> T) rethrows -> T {
        if reference.model != nil {
            return try callback()
        }

        var postLockCallbacks: [() -> Void] = []
        defer {
            for plc in postLockCallbacks {
                plc()
            }
        }

        return try lock {
            if threadLocals.postTransactions != nil {
                return try callback()
            }

            threadLocals.postTransactions = []
            defer {
                let posts = threadLocals.postTransactions!
                threadLocals.postTransactions = nil
                for postTransaction in posts {
                    postTransaction(&postLockCallbacks)
                }
            }

            return try callback()
        }
    }

    func childContext<C: ModelContainer, Child: Model>(containerPath: WritableKeyPath<M, C>, elementPath: WritableKeyPath<C, Child>, childModel: Child) -> Context<Child> {
        lock {
            let modelRef = ModelRef(elementPath: elementPath, id: childModel.id)
            modelRefs.insert(modelRef)

            if let child = children[containerPath]?[modelRef] as? Context<Child> {
                return child
            }

            assert(children[containerPath]?[modelRef] == nil)

            if let child = childModel.context {
                child.addParent(self)
                children[containerPath, default: [:]][modelRef] = child
                return child
            } else {
                let child = Context<Child>(model: childModel, lock: lock, dependencies: { _ in }, parent: self)
                child.withModificationActiveCount { $0 = anyModificationActiveCount }
                children[containerPath, default: [:]][modelRef] = child
                return child
            }
        }
    }
}

extension Context {
    final class Reference: @unchecked Sendable {
        let modelID: ModelID
        private let lock = NSRecursiveLock()
        private weak var _context: Context<M>?
        private(set) var _model: M?
        private var _isDestructed = false

        init(modelID: ModelID) {
            self.modelID = modelID
        }

        deinit {
            //print("Context.Reference deinit: \(type(of: self))")
        }

        var lifetime: ModelLifetime {
            context?.lifetime ?? lock {
                _isDestructed ? .destructed : .initial
            }
        }

        var context: Context<M>? {
            lock { _context }
        }

        var model: M? {
            lock { _model }
        }

        func updateAccess(_ access: ModelAccess?) {
            lock {
                _model?._$modelContext._access = access?.reference
            }
        }

        var isDestructed: Bool {
            lock { _isDestructed }
        }

        func destruct(_ model: M?) {
            lock {
                _isDestructed = true
                _model = model
            }
        }

        func clear() {
            lock {
                _context = nil
                _model = nil
            }
        }

        func setContext(_ context: Context) {
            lock {
                assert(!_isDestructed)
                _context = context
                _model = nil
            }
        }

        subscript (fallback fallback: M) -> M {
            _read {
                lock.lock()
                yield _model?.withAccess(fallback.access) ?? fallback
                lock.unlock()
            }
            _modify {
                lock.lock()
                var model = _model?.withAccess(fallback.access) ?? fallback
                yield &model
                _model = model
                lock.unlock()
            }
        }
    }
}

func _testing_keepLastSeenAround<T>(_ operation: () async throws -> T) async rethrows -> T {
    try await AnyContext.$keepLastSeenAround.withValue(true) {
        try await operation()
    }
}

func _testing_keepLastSeenAround<T>(_ operation: () throws -> T) rethrows -> T {
    try AnyContext.$keepLastSeenAround.withValue(true) {
        try operation()
    }
}

let lastSeenTimeToLive: TimeInterval = 2
