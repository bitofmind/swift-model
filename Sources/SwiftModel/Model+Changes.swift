import Foundation
import CustomDump
import ConcurrencyExtras

public extension Model {
    /// Returns a stream observing changes (using equality checks) of the value at `path`
    ///
    /// - Parameter path: key path to value to be observed
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter recursive: Also trigger updates if any sub-value or there of is updated (default to false).
    /// - Parameter freezeValues: Returned frozen copies (snap-shots) of models (defaults to false).
    func change<T: Equatable>(of path: KeyPath<Self, T>, initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false) -> AsyncStream<T> where Self: Sendable {
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
    func update<T>(of path: KeyPath<Self, T>, initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false) -> AsyncStream<T> where Self: Sendable {
        guard let context = enforcedContext() else { return .never }
        return AsyncStream { cont in
            let anyCallbacks = LockIsolated<[@Sendable () -> Void]>([])
            let state = LockIsolated<(last: AnyKeyPath, isNil: Bool)?>(nil)
            self.transaction {
                let collector = AccessCollector(foundPaths: { updatePath in
                    let value = context[path]
                    state.withValue {
                        $0 = (updatePath, isNil(value))
                    }

                    if recursive, !isNil(value), anyCallbacks.value.isEmpty, let container = value as? any ModelContainer {
                        let cancels = anyCallbacks.withValue { anyCallbacks in
                            defer {
                                container.forEachContext { subContext in
                                    let cancel = subContext.onAnyModification { didFinish in
                                        if !didFinish {
                                            cont.yield(copy(context[path], shouldFreeze: freezeValues))
                                        }
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
                }, onModify: { collector, updatePath, finished in
                    let value = context[path]
                    let isNil = isNil(value)
                    let (lastPath, wasNil) = state.value ?? (nil, false)
                    if finished || isNil || (wasNil && !isNil) || updatePath != lastPath || (value is any ModelContainer) {
                        collector.cancel()
                        anyCallbacks.withValue { $0.removeAll(keepingCapacity: true) }
                        _ = withAccess(collector)[keyPath: path]
                        if finished {
                            return
                        }
                    }

                    cont.yield(copy(value, shouldFreeze: freezeValues))
                })

                let _ = withAccess(collector)[keyPath: path]

                if initial {
                    cont.yield(copy(context[path], shouldFreeze: freezeValues))
                }

                cont.onTermination = { _ in
                    collector.cancel()
                }
            }
        }
    }

    /// Will start to print state changes until cancelled, but only in `DEBUG` configurations.
    @discardableResult
    func _printChanges(name: String? = nil, to printer: some TextOutputStream&Sendable = PrintTextOutputStream()) -> Cancellable where Self: Sendable {
#if DEBUG
        guard let context = enforcedContext() else { return EmptyCancellable() }
        let previous = LockIsolated(context.model.frozenCopy)

        let cancel = context.onAnyModification { hasEnded in
            guard !hasEnded else { return }
            
            let current = context.model
            defer { previous.setValue(current.frozenCopy) }

            guard let diff = diff(previous.value, current) else { return }

            var printer = printer
            printer.write("State did update for \(name ?? typeDescription):\n" + diff)
        }

        return AnyCancellable(context: context, onCancel: cancel)
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

private final class AccessCollector: ModelAccess, @unchecked Sendable {
    let foundPaths: @Sendable (AnyKeyPath) -> Void
    let onModify: @Sendable (AccessCollector, AnyKeyPath, Bool) -> Void
    var cancellables: [() -> Void] = []

    init(foundPaths: @Sendable @escaping (AnyKeyPath) -> Void, onModify: @Sendable @escaping (AccessCollector, AnyKeyPath, Bool) -> Void) {
        self.foundPaths = foundPaths
        self.onModify = onModify
        super.init(useWeakReference: false)
    }

    func cancel() {
        for cancellable in cancellables {
            cancellable()
        }
    }

    override var shouldPropagateToChildren: Bool { true }

    override func willAccess<M: Model, T>(_ model: M, at path: WritableKeyPath<M, T>) -> (() -> Void)? {
        foundPaths(path)
        cancellables.append(model.context!.onModify(for: path, {
            self.onModify(self, path, $0)
        }))

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
