import Foundation
import CustomDump
import ConcurrencyExtras

/// A stream for observing changes to model properties.
///
///     let countChanges = Observed { model.count }
///     let sumChanges = Observed { model.counts.reduce(0, +) }
///
/// An observation can be to any number of properties or models, and the stream will re-calculated it's value if any of the observed values are changed.
/// Observation are typically iterated using the a model's node `forEach` helper, often set up in the `onActive()` callback:
///
///     func onActivate() {
///       node.forEach(Observed { count }) {
///         print("count did update to", $0)
///       }
///     }
public struct Observed<Element: Sendable>: AsyncSequence, Sendable {
    let stream: AsyncStream<Element>

    /// Create as Observed stream observing updates of the values provided by  `access`
    ///
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter access: closure providing the value to be observed
    @_disfavoredOverload
    public init(initial: Bool = true, _ access: @Sendable @escaping () -> Element) {
        self.init(access: access, initial: initial, recursive: false, freezeValues: false)
    }

    public func makeAsyncIterator() -> AsyncStream<Element>.Iterator {
        stream.makeAsyncIterator()
    }
}

public extension Observed where Element: Equatable {
    /// Create as Observed stream observing changes of the value provided by  `access`
    ///
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter access: closure providing the value to be observed
    init(initial: Bool = true, removeDuplicates: Bool = true, _ access: @Sendable @escaping () -> Element) {
        if removeDuplicates {
            stream = Observed(access: access, initial: initial, recursive: false, freezeValues: false).stream.removeDuplicates().eraseToStream()
        } else {
            stream = Observed(access: access, initial: initial, recursive: false, freezeValues: false).stream
        }
    }
}

public extension Model where Self: Sendable {
    /// Returns a stream observing changes (using equality checks) of the value at `path`
    ///
    /// - Parameter path: key path to value to be observed
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    @available(*, deprecated, message: "Use `Observed { value }` instead")
    func change<T: Equatable&Sendable>(of path: KeyPath<Self, T>&Sendable, initial: Bool = true) -> AsyncStream<T> {
        Observed(initial: initial) { self[keyPath: path] }.stream
    }

    /// Returns a stream observing updates of the value at `path`
    ///
    /// Will be called when value was updated, even if updated to same value, use `change(of:)` to only receive changes
    ///
    /// - Parameter path: KeyPath to value to be observed
    /// - Parameter initial: Start by sending current initial value (defaults to true)
    @available(*, deprecated, message: "Use `Observed { value }` instead")
    func update<T: Sendable>(of path: KeyPath<Self, T>&Sendable, initial: Bool = true) -> AsyncStream<T> {
        Observed(initial: initial) { self[keyPath: path] }.stream
    }

    /// Returns a stream observing changes (using equality checks) of the value at `path`
    ///
    /// - Parameter path: key path to value to be observed
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter recursive: Also trigger updates if any sub-value or there of is updated (default to false).
    /// - Parameter freezeValues: Returned frozen copies (snap-shots) of models (defaults to false).
    @available(*, deprecated, message: "Use `Observed { value }` instead")
    func change<T: ModelContainer&Equatable&Sendable>(of path: KeyPath<Self, T>&Sendable, initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false) -> AsyncStream<T> {
        Observed(access: { self[keyPath: path] }, initial: initial, recursive: recursive, freezeValues: freezeValues).stream
    }

    /// Returns a stream observing updates of the value at `path`
    ///
    /// Will be called when value was updated, even if updated to same value, use `change(of:)` to only receive changes
    ///
    /// - Parameter path: KeyPath to value to be observed
    /// - Parameter initial: Start by sending current initial value (defaults to true)
    /// - Parameter recursive: Also trigger updates if any sub-value or there of is updated (default to false).
    /// - Parameter freezeValues: Returned frozen copies (snap-shots) of models (defaults to false).
    @available(*, deprecated, message: "Use `Observed { value }` instead")
    func update<T: ModelContainer&Sendable>(of path: KeyPath<Self, T>&Sendable, initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false) -> AsyncStream<T> {
        Observed(access: { self[keyPath: path] }, initial: initial, recursive: recursive, freezeValues: freezeValues).stream
    }

    /// Returns a stream observing any updates on self or any descendants
    func observeAnyModification() -> AsyncStream<()> {
        guard let context = enforcedContext() else { return .finished }

        return AsyncStream { cont in
            let cancel = context.onAnyModification { didFinish in
                if didFinish {
                    cont.finish()
                } else {
                    cont.yield(())
                }
                return nil
            }

            cont.onTermination = { _ in
                cancel()
            }
        }
    }

    /// Will start to print state changes until cancelled, but only in `DEBUG` configurations.
    @discardableResult
    func _printChanges(name: String? = nil, to printer: some TextOutputStream&Sendable = PrintTextOutputStream()) -> Cancellable {
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

public extension ModelNode {
    func memoize<T: Sendable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, produce: @Sendable @escaping () -> T) -> T {
        let key = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        return memoize(for: key, produce: produce, isSame: nil)
    }

    func memoize<T: Sendable&Equatable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, produce: @Sendable @escaping () -> T) -> T {
        let key = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        return memoize(for: key, produce: produce, isSame: { $0 == $1 })
    }
}


private extension Observed {
    init(access: @Sendable @escaping () -> Element, initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false) {
        stream = AsyncStream { cont in
            let cancellable = update(initial: initial, recursive: recursive, freezeValues: freezeValues) {
                access()
            } onUpdate: { value in
                cont.yield(value)
            }

            cont.onTermination = { _ in
                cancellable()
            }
        }
    }
}

private extension ModelNode {
    func memoize<T: Sendable>(for key: some Hashable&Sendable, produce: @Sendable @escaping () -> T, isSame: (@Sendable (T, T) -> Bool)?) -> T {
        guard let context = enforcedContext() else { return produce() }

        let key = AnyHashableSendable(key)
        let path: KeyPath<M, T>&Sendable = \M[memoizeKey: key]
        _$modelContext.willAccess(context.model, at: path)?()

        return context.lock {
            if let value = context._memoizeCache[key] as? T {
                return value
            }

            _ = update {
                produce()
            } onUpdate: { value in
                var postLockCallbacks: [() -> Void] = []

                context.lock {
                    let prevValue = context._memoizeCache[key] as? T
                    if let isSame, let prevValue, isSame(value, prevValue) {
                        return
                    }

                    context._memoizeCache[key] = value

                    if prevValue != nil {
                        context.onPostTransaction(callbacks: &postLockCallbacks) { postCallbacks in
                            for callback in (context.modifyCallbacks[path] ?? [:]).values {
                                if let postCallback = callback(false) {
                                    postCallbacks.append(postCallback)
                                }
                            }

                            if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), let model = context.model as? any Model&Observable {
                                postCallbacks.append {
                                    model.willSet(path: path, from: context)
                                    model.didSet(path: path, from: context)
                                }
                            }
                        }
                    }
                }

                for plc in postLockCallbacks { plc() }
            }

            return context._memoizeCache[key] as! T
        }
    }

    func memoize<T: Sendable>(for key: some Hashable&Sendable, produce: @Sendable @escaping () -> T) -> T {
        memoize(for: key, produce: produce, isSame: nil)
    }

    func memoize<T: Sendable&Equatable>(for key: some Hashable&Sendable, produce: @Sendable @escaping () -> T) -> T {
        memoize(for: key, produce: produce, isSame: { $0 == $1 })
    }
}

private extension Model {
    subscript<Value: Sendable>(memoizeKey key: some Hashable&Sendable) -> Value {
        context!.lock {
            context!._memoizeCache[AnyHashableSendable(key)] as! Value
        }
    }
}

private func update<T: Sendable>(initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false, access: @Sendable @escaping () -> T, onUpdate: @Sendable @escaping (T) -> Void) -> @Sendable () -> Void {
    let anyCallbacks = LockIsolated<[@Sendable () -> Void]>([])

    @Sendable func yield(_ value: T) -> () -> Void {
        let copy = copy(value, shouldFreeze: freezeValues)

        return { // Call out outside of held lock
            onUpdate(copy)
        }
    }

    @Sendable func reset() {
        guard recursive else { return }

        let value = access()
        if value is any ModelContainer {
            let cancels = anyCallbacks.withValue { anyCallbacks in
                anyCallbacks.removeAll(keepingCapacity: true)
                let container = value as! any ModelContainer
                defer {
                    container.forEachContext { subContext in
                        let cancel = subContext.onAnyModification { didFinish in
                            if didFinish { return nil }
                            return yield(access())
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

    let collector = AccessCollector { collector, modifiedValue in
        if modifiedValue is any ModelContainer {
            reset()
        }

        let value = collector.reset {
            usingActiveAccess(collector) {
                access()
            }
        }

        return yield(value)
    }

    reset()

    let value = collector.reset {
        usingActiveAccess(collector) {
            access()
        }
    }

    if initial {
        onUpdate(copy(value, shouldFreeze: freezeValues))
    }

    return {
        collector.reset { }
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

    func reset<Value>(_ access: () -> Value) -> Value {
        let keys = active.withValue {
            $0.added.removeAll(keepingCapacity: true)
            return Set($0.active.keys)
        }

        let value = access()

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

        return value
    }

    override var shouldPropagateToChildren: Bool { false }

    override func willAccess<M: Model, T>(_ model: M, at path: KeyPath<M, T>&Sendable) -> (() -> Void)? {
        if let context = model.context {
            let key = Key(id: model.modelID, path: path)

            let isActive = active.withValue {
                $0.added.insert(key)
                return $0.active[key] != nil
            }

            if !isActive {
                // Make sure to call this outside active lock to avoid dead-locks with context lock.
                let cancellation = context.onModify(for: path) { finished in
                    if finished { return {} }
                    return self.onModify(self, context[path])
                }

                active.withValue {
                    $0.active[key] = cancellation
                }
            }
        }

        return nil
    }
}

protocol _Optional {
    associatedtype Wrapped
    var isNil: Bool { get }

    var wrappedValue: Wrapped? { get }
}

extension Optional: _Optional {
    var isNil: Bool { self == nil }

    var wrappedValue: Wrapped? {
        self
    }
}

private func isNil<T>(_ value: T) -> Bool {
    (value as? any _Optional)?.isNil ?? false
}

