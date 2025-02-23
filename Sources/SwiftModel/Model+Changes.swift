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

public extension ModelNode {
    //    @discardableResult
    //    func sync<T: Sendable>(_ path: WritableKeyPath<M, T>&Sendable, from: KeyPath<M, T>&Sendable) -> Cancellable {
    //        guard let context = enforcedContext() else { return EmptyCancellable() }
    //
    //        return context.update(of: from) {
    //            var model = context.model
    //            model[keyPath: path] = $0
    //        }
    //    }
    //
    //    @discardableResult
    //    func sync<T: Sendable&Equatable>(_ path: WritableKeyPath<M, T>&Sendable, from: KeyPath<M, T>&Sendable) -> Cancellable {
    //        guard let context = enforcedContext() else { return EmptyCancellable() }
    //
    //        return context.update(of: from) {
    //            var model = context.model
    //            if model[keyPath: path] != $0 {
    //                model[keyPath: path] = $0
    //            }
    //        }
    //    }

    func memoize<T: Sendable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, produce: @Sendable @escaping () -> T) -> T {
        let key = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        return memoize(for: key, produce: produce, isSame: nil)
    }

    func memoize<T: Sendable&Equatable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, produce: @Sendable @escaping () -> T) -> T {
        let key = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        return memoize(for: key, produce: produce, isSame: { $0 == $1 })
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

            _ = context.update { context in
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

private extension Context {
    func update<T: Sendable>(initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false, access: @Sendable @escaping (Context<M>) -> T, onUpdate: @Sendable @escaping (T) -> Void) -> Cancellable where Self: Sendable {
        let anyCallbacks = LockIsolated<[@Sendable () -> Void]>([])

        @Sendable func yield() -> () -> Void {
            let copy = copy(access(self), shouldFreeze: freezeValues)

            return { // Call out outside of held lock
                onUpdate(copy)
            }
        }

        @Sendable func reset() {
            guard recursive else { return }

            let value = access(self)
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

        return transaction {
            let collector = AccessCollector { collector, modifiedValue in
                if modifiedValue is any ModelContainer {
                    reset()
                }

                collector.reset {
                    usingActiveAccess(collector) {
                        _ = access(self)
                    }
                }

                return yield()
            }

            reset()

            let value = collector.reset {
                usingActiveAccess(collector) {
                    access(self)
                }
            }

            if initial {
                onUpdate(copy(value, shouldFreeze: freezeValues))
            }

            return AnyCancellable(cancellations: cancellations) {
                collector.reset { }
            }
        }
    }

    func update<T: Sendable>(of path: KeyPath<M, T>&Sendable, initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false, onUpdate: @Sendable @escaping (T) -> Void) -> Cancellable where Self: Sendable {
        update(initial: initial, recursive: recursive, freezeValues: freezeValues, access: { $0[path] }, onUpdate: onUpdate)
    }

    func __update<T: Sendable>(of path: KeyPath<M, T>&Sendable, initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false, onUpdate: @Sendable @escaping (T) -> Void) -> Cancellable where Self: Sendable {
        let anyCallbacks = LockIsolated<[@Sendable () -> Void]>([])

        @Sendable func yield() -> () -> Void {
            let copy = copy(self[path], shouldFreeze: freezeValues)

            return { // Call out outside of held lock
                onUpdate(copy)
            }
        }

        @Sendable func reset() {
            guard recursive else { return }

            let value = self[path]
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

        return transaction {
            let collector = AccessCollector { collector, modifiedValue in
                if modifiedValue is any ModelContainer {
                    reset()

                    collector.reset {
                        usingActiveAccess(collector) {
                            _ = self.model[keyPath: path]
                        }
                    }
                }

                return yield()
            }

            reset()

            collector.reset {
                usingActiveAccess(collector) {
                    _ = model[keyPath: path]
                }
            }

            if initial {
                onUpdate(copy(self[path], shouldFreeze: freezeValues))
            }

            return AnyCancellable(cancellations: cancellations) {
                collector.reset { }
            }
        }
    }
}

private extension Model {
    func _update<T: Sendable>(of path: KeyPath<Self, T>&Sendable, initial: Bool = true, recursive: Bool = false, freezeValues: Bool = false) -> AsyncStream<T> where Self: Sendable {
        guard let context = enforcedContext() else { return .never }

        return AsyncStream { cont in
            let cancellable = context.update(of: path, initial: initial, recursive: recursive, freezeValues: freezeValues) {
                cont.yield($0)
            }

            cont.onTermination = { _ in
                cancellable.cancel()
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
