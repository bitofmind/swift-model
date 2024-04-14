import Foundation
import CustomDump
import ConcurrencyExtras

public extension Model {
    /// Returns a stream observing changes (using equality checks) of the value at `path`
    ///
    /// - Parameter path: key path to value to be observed
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    func change<T: Equatable>(of path: KeyPath<Self, T>, initial: Bool = true) -> AsyncStream<T> where Self: Sendable {
        update(of: path, initial: initial).removeDuplicates().eraseToStream()
    }

    /// Returns a stream observing updates of the value at `path`
    ///
    /// Will be called when value was updated, even if updated to same value, use `change(of:)` to only receive changes
    ///
    /// - Parameter path: KeyPath to value to be observed
    /// - Parameter initial: Start by sending current initial value (defaults to true)
    func update<T>(of path: KeyPath<Self, T>, initial: Bool = true) -> AsyncStream<T> where Self: Sendable {
        _update(of: path, initial: initial, recursive: false, freezeValues: false)
    }

    /// Returns a stream observing changes (using equality checks) of the value at `path`
    ///
    /// - Parameter path: key path to value to be observed
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter recursive: Also trigger updates if any sub-value or there of is updated (default to false).
    /// - Parameter freezeValues: Returned frozen copies (snap-shots) of models (defaults to false).
    func change<T: ModelContainer&Equatable>(of path: KeyPath<Self, T>, initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false) -> AsyncStream<T> where Self: Sendable {
        update(of: path, initial: initial, recursive: recursive, freezeValues: freezeValues).removeDuplicates().eraseToStream()
    }

    /// Returns a stream observing updates of the value at `path`
    ///
    /// Will be called when value was updated, even if updated to same value, use `change(of:)` to only receive changes
    ///
    /// - Parameter path: KeyPath to value to be observed
    /// - Parameter initial: Start by sending current initial value (defaults to true)
    /// - Parameter recursive: Also trigger updates if any sub-value or there of is updated (default to false).
    /// - Parameter freezeValues: Returned frozen copies (snap-shots) of models (defaults to false).
    func update<T: ModelContainer>(of path: KeyPath<Self, T>, initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false) -> AsyncStream<T> where Self: Sendable {
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

            guard let diff = diff(previous.value, current) else { return nil }

            return {
                var printer = printer
                printer.write("State did update for \(name ?? typeDescription):\n" + diff)
            }
        }

        return AnyCancellable(cancellations: context.cancellations, onCancel: cancel)
#else
       return EmptyCancellable()
#endif
    }
}

public struct PrintTextOutputStream: TextOutputStream {
    public init() {}
    public func write(_ string: String) {
        print(string)
    }
}

private extension Model {
    func _update<T>(of path: KeyPath<Self, T>, initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false) -> AsyncStream<T> where Self: Sendable {
        guard let context = enforcedContext() else { return .never }
        return AsyncStream { cont in
            let anyCallbacks = LockIsolated<[@Sendable () -> Void]>([])

            @Sendable func yield() -> () -> Void {
                let copy = copy(context[path], shouldFreeze: freezeValues)

                return { // Callout outside of held lock
                    cont.yield(copy)
                }
            }

            @Sendable func reset() {
                let value = context[path]
                if recursive, let container = value as? any ModelContainer {
                    let cancels = anyCallbacks.withValue { anyCallbacks in
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
                    if modifiedValue is any ModelContainer {
                        collector.reset()
                        anyCallbacks.withValue { $0.removeAll(keepingCapacity: true) }

                        reset()
                        _ = withAccess(collector)[keyPath: path]
                    }

                    return yield()
                }

                reset()
                let _ = withAccess(collector)[keyPath: path]

                if initial {
                    cont.yield(copy(context[path], shouldFreeze: freezeValues))
                }

                cont.onTermination = { _ in
                    collector.reset()
                }
            }
        }
    }
}

private final class AccessCollector: ModelAccess, @unchecked Sendable {
    let onModify: @Sendable (AccessCollector, Any) -> (() -> Void)?
    var cancellables: [() -> Void] = []

    init(onModify: @Sendable @escaping (AccessCollector, Any) -> (() -> Void)?) {
        self.onModify = onModify
        super.init(useWeakReference: false)
    }

    func reset() {
        for cancellable in cancellables {
            cancellable()
        }
        cancellables.removeAll(keepingCapacity: true)
    }

    override var shouldPropagateToChildren: Bool { true }

    override func willAccess<M: Model, T>(_ model: M, at path: WritableKeyPath<M, T>) -> (() -> Void)? {
        if let context = model.context {
            cancellables.append(context.onModify(for: path, { finished in
                if finished { return {} }
                return self.onModify(self, context[path])
            }))
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
