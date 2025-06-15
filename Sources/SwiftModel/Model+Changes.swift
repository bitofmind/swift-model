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
        self.init(access: access, initial: initial, isSame: nil)
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
        stream = Observed(access: access, initial: initial, isSame: removeDuplicates ? (==) : nil).stream
    }
}

public extension Observed {
    /// Create as Observed stream observing changes of the value provided by  `access`
    ///
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter access: closure providing the value to be observed
    init<each T: Equatable>(initial: Bool = true, removeDuplicates: Bool = true, _ access: @Sendable @escaping () -> (repeat each T)) where Element == (repeat each T) {
        stream = Observed(access: access, initial: initial, isSame: removeDuplicates ? isSame : nil).stream
    }

    /// Create as Observed stream observing changes of the value provided by  `access`
    ///
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter access: closure providing the value to be observed
    init<each T: Equatable>(initial: Bool = true, removeDuplicates: Bool = true, _ access: @Sendable @escaping () -> (repeat each T)?) where Element == (repeat each T)? {
        stream = Observed(access: access, initial: initial, isSame: removeDuplicates ? isSame : nil).stream
    }
}

public extension Model where Self: Sendable {
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
    func memoize<T: Sendable>(for key: some Hashable&Sendable, produce: @Sendable @escaping () -> T) -> T {
        memoize(for: key, produce: produce, isSame: nil)
    }

    func memoize<T: Sendable&Equatable>(for key: some Hashable&Sendable, produce: @Sendable @escaping () -> T) -> T {
        memoize(for: key, produce: produce, isSame: { $0 == $1 })
    }

    func memoize<each T: Sendable&Equatable>(for key: some Hashable&Sendable, produce: @Sendable @escaping () -> (repeat each T)) -> (repeat each T) {
        memoize(for: key, produce: produce, isSame: isSame)
    }

    func memoize<T: Sendable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, produce: @Sendable @escaping () -> T) -> T {
        memoize(for: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), produce: produce)
    }

    func memoize<T: Sendable&Equatable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, produce: @Sendable @escaping () -> T) -> T {
        memoize(for: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), produce: produce)
    }

    func memoize<each T: Sendable&Equatable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, produce: @Sendable @escaping () -> (repeat each T)) -> (repeat each T) {
        memoize(for: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), produce: produce)
    }

    func resetMemoization(for key: some Hashable&Sendable) {
        guard let context = enforcedContext() else { return }

        let key = AnyHashableSendable(key)
        context.lock {
            context._memoizeCache[key]?.cancellable()
            context._memoizeCache[key] = nil
        }
    }
}

private extension Observed {
    init(access: @Sendable @escaping () -> Element, initial: Bool = true, isSame: (@Sendable (Element, Element) -> Bool)?) {
        stream = AsyncStream { cont in
            let cancellable = update(initial: initial, isSame: isSame) {
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
            if let value = context._memoizeCache[key].flatMap({ $0.value as? T }) {
                return value
            }

            let cancellable = context.transaction {
                update(initial: true, isSame: nil) {
                    produce()
                } onUpdate: { value in
                    var postLockCallbacks: [() -> Void] = []

                    context.lock {
                        let (prevValue, cancellable) = context._memoizeCache[key].flatMap { ($0.value as? T, $0.cancellable) } ?? (nil, nil)
                        if let isSame, let prevValue, isSame(value, prevValue) {
                            return
                        }

                        context._memoizeCache[key] = (value: value, cancellable: cancellable ?? {})

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
            }

            let value = context._memoizeCache[key]?.value as! T
            context._memoizeCache[key] = (value: value, cancellable: cancellable)

            return value
        }
    }
}

private extension Model {
    subscript<Value: Sendable>(memoizeKey key: some Hashable&Sendable) -> Value {
        context!.lock {
            context!._memoizeCache[AnyHashableSendable(key)]?.value as! Value
        }
    }
}

private func update<T: Sendable>(initial: Bool, isSame: (@Sendable (T, T) -> Bool)?, access: @Sendable @escaping () -> T, onUpdate: @Sendable @escaping (T) -> Void) -> @Sendable () -> Void {
    let last = LockIsolated((value: T?.none, index: 0))
    let updateLock = NSRecursiveLock()
    @Sendable func update(with value: T, index: Int) {
        updateLock.withLock {
            let shouldUpdate: Bool = last.withValue { last in
                guard index == last.index else {
                    return false
                }

                if let isSame {
                    if let last = last.value, isSame(last, value) {
                        return false
                    } else {
                        last.value = value
                    }
                }

                return true
            }

            if shouldUpdate {
                onUpdate(value)
            }
        }
    }

    @Sendable func updateInitial(with value: T) {
        last.withValue { last in
            if last.value == nil {
                last.value = value
            }
        }

        if initial {
            onUpdate(value)
        }
    }

    guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), false else { // Disabled for now, as SwiftUI forces willSet to be called on main thread, and hence all values will be delivered on main.
        let collector = AccessCollector { collector in
            let (value, index) = last.withValue { last in
                last.index = last.index &+ 1

                let value = collector.reset {
                    usingActiveAccess(collector) {
                        access()
                    }
                }

                return (value, last.index)
            }

            return {
                update(with: value, index: index)
            }
        }

        let value = collector.reset {
            usingActiveAccess(collector) {
                access()
            }
        }

        updateInitial(with: value)

        return {
            collector.reset { }
        }
    }

    let hasBeenCancelled = LockIsolated(false)

    @Sendable func observe() -> T {
        withObservationTracking {
            access()
        } onChange: {
            if hasBeenCancelled.value { return }

            let (value, index) = last.withValue { last in
                last.index = last.index &+ 1
                return (observe(), last.index)
            }

            update(with: value, index: index)
        }
    }

    updateInitial(with: observe())

    return {
        hasBeenCancelled.withValue {
            $0 = true
        }
    }
}

private final class AccessCollector: ModelAccess, @unchecked Sendable {
    let onModify: @Sendable (AccessCollector) -> (() -> Void)?
    let active = LockIsolated<(active: [Key: @Sendable () -> Void], added: Set<Key>)>(([:], []))

    struct Key: Hashable, @unchecked Sendable {
        var id: ModelID
        var path: AnyKeyPath
    }

    init(onModify: @Sendable @escaping (AccessCollector) -> (() -> Void)?) {
        self.onModify = onModify
        super.init(useWeakReference: false)
    }

    deinit {
        for cancel in active.value.active.values {
            cancel()
        }
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
                    return self.onModify(self)
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

