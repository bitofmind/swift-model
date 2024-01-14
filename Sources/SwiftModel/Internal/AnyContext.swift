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

class AnyContext: @unchecked Sendable {
    private let lock: NSRecursiveLock
    private var nextKey = 0

    private(set) weak var parent: AnyContext?
    var children: OrderedDictionary<AnyKeyPath, OrderedDictionary<ModelRef, AnyContext>> = [:]

    private var modeLifeTime: ModelLifetime = .anchored

    private var eventContinuations: [Int: AsyncStream<EventInfo>.Continuation] = [:]
    private let _observationRegistrar: Any?
    let cancellations = Cancellations()

    private(set) var anyModificationActiveCount = 0
    private var anyModificationCallbacks: [Int: (Bool) -> Void] = [:]

    struct EventInfo: @unchecked Sendable {
        var event: Any
        var context: AnyContext
    }

    struct ModelRef: Hashable {
        var elementPath: AnyKeyPath
        var id: AnyHashable
    }


    init(lock: NSRecursiveLock, parent: AnyContext?) {
        self.lock = lock
        self.parent = parent

        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            _observationRegistrar = ObservationRegistrar()
        } else {
            _observationRegistrar = nil
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

    var lifetime: ModelLifetime {
        lock(modeLifeTime)
    }

    var isDestructed: Bool {
        lock(modeLifeTime == .destructed)
    }

    func removeChild(_ context: AnyContext) {
        let onRemoval = lock {
            for (containerPath, contexts) in children {
                for (modelRef, child) in contexts {
                    if context === child {
                        let onRemoval = children[containerPath]?[modelRef]?.onRemoval
                        children[containerPath]?[modelRef] = nil
                        if children[containerPath]?.isEmpty == true {
                            children[containerPath] = nil
                        }

                        return onRemoval
                    }
                }
            }

            return nil
        }

        onRemoval?()
    }

    var allChildren: [AnyContext] {
        children.values.flatMap { $0.values }
    }

    func onActivate() -> Bool {
        return lock {
            defer {
                modeLifeTime = .active
            }
            return modeLifeTime == .anchored
        }
    }

    func onRemoval() {
        let removeSelfFromParent = lock {
            defer {
                modeLifeTime = .destructed
                parent = nil
            }
            return modeLifeTime == .destructed ? nil : { [parent] in
                parent?.removeChild(self)
            }
        }
        
        guard let removeSelfFromParent else { return }
        removeSelfFromParent()

        let children = lock {
            defer { self.children.removeAll() }
            return allChildren
        }

        for child in children {
            child.onRemoval()
        }

        cancellations.cancelAll()

        let (events, anyModifies) = lock {
            defer {
                eventContinuations.removeAll()
                anyModificationCallbacks.removeAll()
                anyModificationActiveCount = 0
            }
            return (eventContinuations.values, anyModificationCallbacks.values)
        }

        for cont in events {
            cont.finish()
        }

        for cont in anyModifies {
            cont(true)
        }
    }

    func withDependencies<Value>(_ operation: () -> Value) -> Value { fatalError() }

    func sendEvent(_ eventInfo: EventInfo, to receivers: EventReceivers) {
        let parent = lock(parent)

        if receivers.contains(.self) {
            for continuation in eventContinuations.values {
                continuation.yield(eventInfo)
            }
        }

        if receivers.contains(.ancestors) {
            parent?.sendEvent(eventInfo, to: [.self, .ancestors])
        } else if receivers.contains(.parent) {
            parent?.sendEvent(eventInfo, to: .self)
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

    func onAnyModification(callback: @Sendable @escaping (Bool) -> Void) -> @Sendable () -> Void {
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

    func didModify() {
        guard lock(anyModificationActiveCount) > 0 else { return }

        for callback in lock(anyModificationCallbacks.values) {
            callback(false)
        }

        parent?.didModify()
    }

    @TaskLocal static var keepLastSeenAround = false
}
