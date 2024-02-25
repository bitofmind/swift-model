import Foundation
import Dependencies
import OrderedCollections
import XCTestDynamicOverlay

final class Context<M: Model>: AnyContext {
    private let activations: [(M) -> Void]
    private var modifyCallbacks: [PartialKeyPath<M>: [Int: (Bool) -> (() -> Void)?]] = [:]
    let reference: Reference
    let rootPath: AnyKeyPath
    var readModel: M
    var modifyModel: M
    private var isMutating = false

    @Dependency(\.uuid) private var dependencies
    var dependencyCache: [PartialKeyPath<DependencyValues>: Any] = [:]

    init(model: M, rootPath: AnyKeyPath, lock: NSRecursiveLock, dependencies: (inout DependencyValues) -> Void, parent: AnyContext?) {
        readModel = model.assertInitialCopy()
        modifyModel = readModel
        self.rootPath = rootPath

        let modelSetup = model.modelSetup
        self.activations = modelSetup?.activations ?? []
        reference = Reference(modelID: model.modelID, lock: lock)
        super.init(lock: lock, parent: parent)
        reference._context = self

        Dependencies.withDependencies(from: parent ?? self) {
            dependencies(&$0)
            for dependency in modelSetup?.dependencies ?? [] {
                dependency(&$0)
            }
        } operation: {
            _dependencies = Dependency(\.uuid)
        }

        readModel.withContextAdded(context: self)
        modifyModel = readModel
    }

    private var lock: NSRecursiveLock { reference.lock }

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

        for child in allChildren {
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

        guard !_XCTIsTesting || AnyContext.keepLastSeenAround else { return }

        let lastSeenValue = readModel.lastSeen(at: Date())
        reference._lastSeenValue = lastSeenValue

        Task {
            try? await Task.sleep(nanoseconds: NSEC_PER_MSEC*UInt64(lastSeenTimeToLive*1000))
            reference.clear()
        }
    }

    func sendEvent(_ event: Any, to receivers: EventReceivers, context: AnyContext) {
        let eventInfo = EventInfo(event: event, context: context)
        sendEvent(eventInfo, to: receivers)
    }

    func onModify<T>(for path: KeyPath<M, T>, _ callback: @Sendable @escaping (Bool) -> (() -> Void)?) -> @Sendable () -> Void {
        guard !isDestructed else {
            return {}
        }

        let key = generateKey()
        lock {
            modifyCallbacks[path, default: [:]][key] = callback
        }

        return { [weak self] in
            self?.lock {
                _ = self?.modifyCallbacks[path]?.removeValue(forKey: key)
            }
        }
    }

    override var typeDescription: String {
        String(describing: M.self)
    }

    var model: M {
        lock(readModel)
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
            if let last = reference._lastSeenValue {
                yield last[keyPath: path]
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

    subscript<T>(path: WritableKeyPath<M, T>, callback: (() -> Void)? = nil) -> T {
        _read {
            lock.lock()
            if let last = reference._lastSeenValue {
                yield last[keyPath: path]
            } else if isDestructed {
                yield readModel[keyPath: path]
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
            if var last = reference._lastSeenValue {
                yield &last[keyPath: path]
                reference._lastSeenValue = last
                lock.unlock()
            } else if isDestructed {
                var value = readModel[keyPath: path]
                yield &value
                lock.unlock()
            } else {
                yield &modifyModel[keyPath: path]
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

    func transaction<Value, T>(at path: WritableKeyPath<M, Value>, callback: (() -> Void)? = nil, modify: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        let result: T
        if var last = reference._lastSeenValue {
            result = try modify(&last[keyPath: path])
            reference._lastSeenValue = last
            lock.unlock()
        } else {
            result = try modify(&modifyModel[keyPath: path])
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
        if reference.lastSeenValue != nil {
            return try callback()
        }

        var postLockCallbacks: [() -> Void] = []
        defer {
            for plc in postLockCallbacks {
                plc()
            }
        }

        return try lock {
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
            let rootPath = rootPath.appending(path: containerPath)!.appending(path: elementPath)!
            let child = Context<Child>(model: childModel, rootPath: rootPath, lock: lock, dependencies: { _ in }, parent: self)
            child.withModificationActiveCount { $0 = anyModificationActiveCount }
            children[containerPath, default: [:]][modelRef] = child

            return child
        }
    }

    func dependency<Value>(for keyPath: KeyPath<DependencyValues, Value>) -> Value {
        lock {
            if let value = dependencyCache[keyPath] as? Value {
                return value
            }
            
            return Dependencies.withDependencies(from: self, { _ in }) {
                let value = Dependency(keyPath).wrappedValue
                dependencyCache[keyPath] = value
                return value
            }
        }
    }
}

extension Context {
    final class Reference: @unchecked Sendable {
        let lock: NSRecursiveLock
        let modelID: ModelID
        fileprivate weak var _context: Context<M>?
        fileprivate var _lastSeenValue: M?

        fileprivate init(modelID: ModelID, lock: NSRecursiveLock) {
            self.modelID = modelID
            self.lock = lock
        }

        deinit {
            //print("Context.Reference deinit: \(type(of: self))")
        }

        var context: Context<M>? {
            lock { _context }
        }

        var lastSeenValue: M? {
            lock { _lastSeenValue }
        }

        func clear() {
            lock {
                _context = nil
                _lastSeenValue = nil
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
