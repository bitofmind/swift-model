import Foundation
import Dependencies
import OrderedCollections

enum ModelLifetime: Comparable {
    case initial
    case anchored
    case active
    case destructed
    case frozenCopy
}

extension ModelLifetime {
    var isDestructedOrFrozenCopy: Bool {
        self == .destructed || self == .frozenCopy
    }
}

class AnyContext: @unchecked Sendable {
    let lock: NSRecursiveLock
    private var nextKey = 0

    final class WeakParent {
        weak var parent: AnyContext?

        init(parent: AnyContext? = nil) {
            self.parent = parent
        }
    }

    private(set) var weakParents: [WeakParent] = []
    var children: OrderedDictionary<AnyKeyPath, OrderedDictionary<ModelRef, AnyContext>> = [:]
    var dependencyContexts: [ObjectIdentifier: AnyContext] = [:]
    var dependencyCache: [AnyHashable: Any] = [:]

    private var modeLifeTime: ModelLifetime = .anchored

    private var eventContinuations: [Int: AsyncStream<EventInfo>.Continuation] = [:]
    private let _observationRegistrar: Any?
    let cancellations = Cancellations()

    private(set) var anyModificationActiveCount = 0
    private var anyModificationCallbacks: [Int: (Bool) -> (() -> Void)?] = [:]
    private var modificationCount = 0

    func didModify() {
        modificationCount &+= 1
    }

    typealias ModificationCounts = [ObjectIdentifier: Int]

    var modificationCounts: ModificationCounts {
        lock {
            var counts = ModificationCounts()
            collectModificationCounts(&counts)
            return counts
        }
    }

    private func collectModificationCounts(_ counts: inout ModificationCounts) {
        counts[ObjectIdentifier(self)] = modificationCount
        for child in allChildren {
            child.collectModificationCounts(&counts)
        }
    }

    struct EventInfo: @unchecked Sendable {
        var event: Any
        var context: AnyContext
    }

    struct ModelRef: Hashable {
        var elementPath: AnyKeyPath
        var id: AnyHashable
    }

    func addParent(_ parent: AnyContext) {
        weakParents.append(WeakParent(parent: parent))
    }

    func removeParent(_ parent: AnyContext, callbacks: inout [() -> Void]) {
        for i in weakParents.indices {
            if weakParents[i].parent === parent {
                weakParents.remove(at: i)
                break
            }
        }

        if parents.isEmpty {
            onRemoval(callbacks: &callbacks)
        }
    }

    var rootParent: AnyContext {
        parents.first?.rootParent ?? self
    }

    var parents: [AnyContext] {
        weakParents.compactMap(\.parent)
    }

    var selfPath: AnyKeyPath { fatalError() }

    var rootPaths: [AnyKeyPath] {
        lock {
            if parents.isEmpty {
                return [selfPath]
            }

            return parents.flatMap { parent in
                let childPaths = parent.children.flatMap { childPath, modelRefs in
                    modelRefs.compactMap { modalRef, context in
                        if context === self {
                            return childPath.appending(path: modalRef.elementPath)
                        } else {
                            return nil
                        }
                    }
                }

                return parent.rootPaths.flatMap { rootPath in
                    childPaths.compactMap { rootPath.appending(path: $0) }
                }
            }
        }
    }

    func onPostTransaction(callbacks: inout [() -> Void], callback: @escaping (inout [() -> Void]) -> Void) {
        if threadLocals.postTransactions != nil {
            threadLocals.postTransactions!.append(callback)
        } else {
            callback(&callbacks)
        }
    }

    init(lock: NSRecursiveLock, parent: AnyContext?) {
        self.lock = lock
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            _observationRegistrar = nil//ObservationRegistrar() // There seem to be some issue with the Swift 6 compiler where updates or not always registered properly. We have to disable this for now.
        } else {
            _observationRegistrar = nil
        }

        if let parent {
            addParent(parent)
        }
    }

    deinit {
        //print("ContextBase deinit")
    }

    var activeTasks: [(modelName: String, fileAndLines: [FileAndLine])] {
        allChildren.reduce(into: cancellations.activeTasks) {
            $0.append(contentsOf: $1.activeTasks)
        }
    }

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    var observationRegistrar: ObservationRegistrar? {
        _observationRegistrar as? ObservationRegistrar
    }

    var hasObservationRegistrar: Bool {
        _observationRegistrar != nil
    }

    var lifetime: ModelLifetime {
        lock(modeLifeTime)
    }

    var isDestructed: Bool {
        lifetime == .destructed
    }

    func removeChild(_ context: AnyContext, callbacks: inout [() -> Void]) {
        context.removeParent(self, callbacks: &callbacks)

        for (containerPath, contexts) in children {
            for (modelRef, child) in contexts {
                if context === child {
                    children[containerPath]?[modelRef] = nil
                    if children[containerPath]?.isEmpty == true {
                        children[containerPath] = nil
                    }
                    return
                }
            }
        }
    }

    var allChildren: [AnyContext] {
        children.values.flatMap { $0.values } + dependencyContexts.values
    }

    func onActivate() -> Bool {
        return lock {
            defer {
                modeLifeTime = .active
            }
            return modeLifeTime == .anchored
        }
    }

    func onRemoval(callbacks: inout [() -> Void]) {
        let events = eventContinuations.values
        let anyModifies = anyModificationCallbacks.values
        let children = allChildren

        eventContinuations.removeAll()
        anyModificationCallbacks.removeAll()
        anyModificationActiveCount = 0
        modeLifeTime = .destructed
        self.children.removeAll()
        dependencyContexts.removeAll()

        callbacks.append {
            self.cancellations.cancelAll()

            for cont in events {
                cont.finish()
            }

            for cont in anyModifies {
                cont(true)?()
            }
        }

        for child in children {
            child.removeParent(self, callbacks: &callbacks)
        }
    }

    func onRemoval() {
        var callbacks: [() -> Void] = []
        
        lock {
            onRemoval(callbacks: &callbacks)
        }

        for callback in callbacks {
            callback()
        }
    }

    func sendEvent(_ eventInfo: EventInfo, to receivers: EventReceivers) {
        let parents = lock(parents)

        if receivers.contains(.self), !threadLocals.coalesceSends.contains(ObjectIdentifier(self)) {
            for continuation in eventContinuations.values {
                continuation.yield(eventInfo)
            }

            threadLocals.coalesceSends.insert(ObjectIdentifier(self))
        }

        for parent in parents {
            if receivers.contains(.ancestors) {
                parent.sendEvent(eventInfo, to: [.self, .ancestors])
            } else if receivers.contains(.parent) {
                parent.sendEvent(eventInfo, to: .self)
            }
        }

        if receivers.contains(.descendants) {
            for child in allChildren {
                child.sendEvent(eventInfo, to: [.self, .descendants])
            }
        } else if receivers.contains(.children) {
            for child in allChildren {
                child.sendEvent(eventInfo, to: .self)
            }
        }
    }

    func cancelAllRecursively(for id: some Hashable&Sendable) {
        cancellations.cancelAll(for: id)

        for child in allChildren {
            child.cancelAllRecursively(for: id)
        }
    }

    var typeDescription: String { fatalError() }

    func generateKey() -> Int {
        lock {
            defer { nextKey += 1 }
            return nextKey
        }
    }

    func events() -> AsyncStream<EventInfo> {
        lock {
            guard !isDestructed else {
                return .finished
            }
            let (stream, cont) = AsyncStream<EventInfo>.makeStream()
            let key = generateKey()

            cont.onTermination = { [weak self] _ in
                self?.lock {
                    _ = self?.eventContinuations.removeValue(forKey: key)
                }
            }

            eventContinuations[key] = cont
            return stream
        }
    }

    func withModificationActiveCount(_ callback: (inout Int) -> Void) {
        lock {
            callback(&anyModificationActiveCount)
            for child in allChildren {
                child.withModificationActiveCount(callback)
            }
        }

    }

    func onAnyModification(callback: @Sendable @escaping (Bool) -> (() -> Void)?) -> @Sendable () -> Void {
        let key = generateKey()
        lock {
            anyModificationCallbacks[key] = callback
            withModificationActiveCount {
                $0 += 1
            }
        }

        return { [weak self] in
            _ = self?.lock {
                self?.withModificationActiveCount {
                    $0 -= 1
                }
                self?.anyModificationCallbacks.removeValue(forKey: key)
            }
        }
    }

    func didModify(callbacks: inout [() -> Void]) {
        guard anyModificationActiveCount > 0 else { return }

        for callback in anyModificationCallbacks.values {
            if let c = callback(false) {
                callbacks.append(c)
            }
        }

        for parent in parents {
            parent.didModify(callbacks: &callbacks)
        }
    }

    @TaskLocal static var keepLastSeenAround = false

    func setupModelDependency<D: Model>(_ model: inout D, cacheKey: AnyHashable?, postSetups: inout [() -> Void]) {
        switch model._$modelContext.source {
        case let .reference(reference):
            if let child = reference.context, child.rootParent === rootParent {
                if dependencyContexts[ObjectIdentifier(D.self)] == nil {
                    dependencyContexts[ObjectIdentifier(D.self)] = child
                    child.addParent(self)
                }
                return
            } else if dependencyContexts[ObjectIdentifier(D.self)] == nil || reference.lifetime == .destructed {
                if let cacheKey {
                    if let context = rootParent.dependencyContexts[ObjectIdentifier(D.self)] as? Context<D> {
                        model.withContextAdded(context: context)
                    } else {
                        model = model.initialDependencyCopy // make sure to do unique copy of default value (liveValue etc).
                        rootParent.setupModelDependency(&model, cacheKey: nil, postSetups: &postSetups)
                        rootParent.dependencyCache[cacheKey] = model
                    }
                    setupModelDependency(&model, cacheKey: cacheKey, postSetups: &postSetups)
                } else {
                    model = model.initialCopy
                    assert(model.context == nil)
                    let child = Context<D>(model: model, lock: lock, dependencies: { _ in }, parent: self)
                    child.withModificationActiveCount { $0 = anyModificationActiveCount }
                    dependencyContexts[ObjectIdentifier(D.self)] = child
                    model.withContextAdded(context: child)
                    postSetups.append {
                        _ = child.onActivate()
                    }
                }
            }
        case .frozenCopy, .lastSeen:
            return // warn?
        }
    }

    func dependency<Value>(for keyPath: KeyPath<DependencyValues, Value>) -> Value {
        lock {
            if let value = dependencyCache[keyPath] as? Value {
                return value
            }

            return Dependencies.withDependencies(from: self, { _ in }) {
                let value = Dependency(keyPath).wrappedValue
                if var model = value as? any Model {
                    withPostActions { postActions in
                        setupModelDependency(&model, cacheKey: keyPath, postSetups: &postActions)
                        dependencyCache[keyPath] = model
                    }
                    return model as! Value
                } else {
                    dependencyCache[keyPath] = value
                    return value
                }
            }
        }
    }

    func dependency<Value: DependencyKey>(for type: Value.Type) -> Value where Value.Value == Value {
        lock {
            let key = ObjectIdentifier(type)
            if let value = dependencyCache[key] as? Value {
                return value
            }

            return Dependencies.withDependencies(from: self, { _ in }) {
                let value = Dependency(type).wrappedValue
                if var model = value as? any Model {
                    withPostActions { postActions in
                        setupModelDependency(&model, cacheKey: key, postSetups: &postActions)
                        dependencyCache[key] = model
                    }
                    return model as! Value
                } else {
                    dependencyCache[key] = value
                    return value
                }
            }
        }
    }
}

func withPostActions<T>(perform: (inout [() -> Void]) throws -> T) rethrows -> T {
    var postActions: [() -> Void] = []
    defer {
        for action in postActions {
            action()
        }
    }
    return try perform(&postActions)
}
