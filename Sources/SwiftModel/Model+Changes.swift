import Foundation
import CustomDump
import ConcurrencyExtras

public extension Model {
    /// Returns a stream observing changes (using equality checks) of the value at `path`
    ///
    /// - Parameter path: key path to value to be observed
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    func change<T: Equatable&Sendable>(of path: KeyPath<Self, T>&Sendable, initial: Bool = true) -> AsyncStream<T> where Self: Sendable {
        update(of: path).removeDuplicates().dropFirst(initial ? 0 : 1).eraseToStream()
    }

    /// Returns a stream observing updates of the value at `path`
    ///
    /// Will be called when value was updated, even if updated to same value, use `change(of:)` to only receive changes
    ///
    /// - Parameter path: KeyPath to value to be observed
    /// - Parameter initial: Start by sending current initial value (defaults to true)
    func update<T: Sendable>(of path: KeyPath<Self, T>&Sendable, initial: Bool = true) -> AsyncStream<T> where Self: Sendable {
        _update(of: path, initial: initial, recursive: false, freezeValues: false)
    }

    /// Returns a stream observing changes (using equality checks) of the value at `path`
    ///
    /// - Parameter path: key path to value to be observed
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter recursive: Also trigger updates if any sub-value or there of is updated (default to false).
    /// - Parameter freezeValues: Returned frozen copies (snap-shots) of models (defaults to false).
    func change<T: ModelContainer&Equatable&Sendable>(of path: KeyPath<Self, T>&Sendable, initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false) -> AsyncStream<T> where Self: Sendable {
        update(of: path, recursive: recursive, freezeValues: freezeValues).removeDuplicates().dropFirst(initial ? 0 : 1).eraseToStream()
    }

    /// Returns a stream observing updates of the value at `path`
    ///
    /// Will be called when value was updated, even if updated to same value, use `change(of:)` to only receive changes
    ///
    /// - Parameter path: KeyPath to value to be observed
    /// - Parameter initial: Start by sending current initial value (defaults to true)
    /// - Parameter recursive: Also trigger updates if any sub-value or there of is updated (default to false).
    /// - Parameter freezeValues: Returned frozen copies (snap-shots) of models (defaults to false).
    func update<T: ModelContainer&Sendable>(of path: KeyPath<Self, T>&Sendable, initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false) -> AsyncStream<T> where Self: Sendable {
        _update(of: path, initial: initial, recursive: recursive, freezeValues: freezeValues)
    }

    /// Will start to print state changes until cancelled, but only in `DEBUG` configurations.
    @discardableResult
    func _printChanges(name: String? = nil, to printer: some TextOutputStream&Sendable = PrintTextOutputStream()) -> Cancellable where Self: Sendable {
#if DEBUG
        guard let context = enforcedContext() else { return EmptyCancellable() }
        let previous = LockIsolated(context.model.frozenCopy)

        let cancel = context.onAnyModification { hasEnded in
            guard !hasEnded else { return nil }

            let current = context.model
            defer { previous.setValue(current.frozenCopy) }

            var difference: String? = diff(previous.value, current)

            if difference == nil {
                difference = threadLocals.withValue(true, at: \.includeInMirror) {
                    diff(previous.value, current)
                }
            }

            guard let difference else { return nil }

            return {
                var printer = printer
                printer.write("State did update for \(name ?? typeDescription):\n" + difference)
            }
        }
        
        return AnyCancellable(cancellations: context.cancellations, onCancel: cancel)
#else
       return EmptyCancellable()
#endif
    }
}

public struct PrintTextOutputStream: TextOutputStream, Sendable {
    public init() {}
    public func write(_ string: String) {
        print(string)
    }
}

private extension Model {
    func _update<T: Sendable>(of path: KeyPath<Self, T>&Sendable, initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false) -> AsyncStream<T> where Self: Sendable {
        guard let context = enforcedContext() else { return .never }
        return AsyncStream { cont in
            let anyCallbacks = LockIsolated<[@Sendable () -> Void]>([])

            @Sendable func yield() -> () -> Void {
                let copy = copy(context[path], shouldFreeze: freezeValues)

                return { // Call out outside of held lock
                    cont.yield(copy)
                }
            }

            @Sendable func reset() {
                guard recursive else { return }

                let value = context[path]
                if value is any ModelContainer {
                    let cancels = anyCallbacks.withValue { anyCallbacks in
                        anyCallbacks.removeAll(keepingCapacity: true)
                        let container = value as! any ModelContainer
                        defer {
                            container.forEachContext { subContext in
                                let cancel = subContext.onAnyModification { didFinish in
                                    if didFinish { return nil }
                                    return yield()
                                }
                                anyCallbacks.append(cancel)
                            }
                        }
                        return anyCallbacks
                    }

                    for cancel in cancels {
                        cancel()
                    }
                }
            }

            self.transaction {
                let collector = AccessCollector { collector, modifiedValue in
                    reset()

                    collector.reset {
                        _ = withAccess(collector)[keyPath: path]
                    }


                    return yield()
                }

                reset()

                collector.reset {
                    let _ = withAccess(collector)[keyPath: path]
                }

                if initial {
                    cont.yield(copy(context[path], shouldFreeze: freezeValues))
                }

                cont.onTermination = { _ in
                    collector.reset { }
                }
            }
        }
    }
}

private final class AccessCollector: ModelAccess, @unchecked Sendable {
    let onModify: @Sendable (AccessCollector, Any) -> (() -> Void)?
    let active = LockIsolated<(active: [Key: @Sendable () -> Void], added: Set<Key>)>(([:], []))

    struct Key: Hashable, @unchecked Sendable {
        var id: ModelID
        var path: AnyKeyPath
    }

    init(onModify: @Sendable @escaping (AccessCollector, Any) -> (() -> Void)?) {
        self.onModify = onModify
        super.init(useWeakReference: false)
    }

    func reset(_ access: () -> Void) {
        let keys = active.withValue {
            $0.added.removeAll(keepingCapacity: true)
            return Set($0.active.keys)
        }

        access()

        let cancels = active.withValue { active in
            let noLongerActive = keys.subtracting(active.added)
            let cancels = active.active.filter { noLongerActive.contains($0.key) }.map(\.value)
            defer {
                for key in noLongerActive {
                    active.active.removeValue(forKey: key)
                }
            }
            return cancels
        }

        for cancel in cancels {
            cancel()
        }
    }

    override var shouldPropagateToChildren: Bool { true }

    override func willAccess<M: Model, T>(_ model: M, at path: WritableKeyPath<M, T>&Sendable) -> (() -> Void)? {
        if let context = model.context {
            active.withValue {
                let key = Key(id: model.modelID, path: path)

                $0.added.insert(key)
                if $0.active[key] == nil {
                    $0.active[key] = context.onModify(for: path, { finished in
                        if finished { return {} }
                        return self.onModify(self, context[path])
                    })
                }
            }
        }

        return nil
    }
}

private protocol _Optional {
    var isNil: Bool { get }
}

extension Optional: _Optional {
    var isNil: Bool { self == nil }
}

private func isNil<T>(_ value: T) -> Bool {
    (value as? _Optional)?.isNil ?? false
}
