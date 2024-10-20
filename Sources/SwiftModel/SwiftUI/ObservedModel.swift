#if canImport(SwiftUI)
import SwiftUI
import Observation

/// Sets up a model for observation to invalidate the view when state changes.
///
/// Use the projectedValue to access a binding of a property such as `$model.count`.
///
/// >`@ObservedModel` has been carefully crafted to only trigger view updates when properties you are accessing from your view is updated.
///
///   struct CounterView: View {
///     @ObservedModel var model: CounterModel
///
///     var body: some View {
///       Stepper(value: $model.count) {
///         Text("\(model.count)")
///       }
///     }
///   }
@propertyWrapper @dynamicMemberLookup
@MainActor
public struct ObservedModel<M: Model>: DynamicProperty, Equatable {
    @StateObject private var access = ViewAccess()
    private var modificationCounts: AnyContext.ModificationCounts?

    public init(wrappedValue: M) {
        self.wrappedValue = wrappedValue
        self.modificationCounts = wrappedValue.context?.modificationCounts
    }

    public var wrappedValue: M

    public nonisolated mutating func update() {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *),
            wrappedValue.context?.hasObservationRegistrar == true,
            wrappedValue is Observable {
            return
        }

        MainActor.assumeIsolated {
            wrappedValue = wrappedValue.withAccess(access)
            access.reset()
        }
    }

    public var projectedValue: Self { self }

    public subscript<T>(dynamicMember path: WritableKeyPath<M, T>) -> Binding<T> {
        Binding {
            wrappedValue[keyPath: path]
        } set: { newValue in
            var model = wrappedValue
            model[keyPath: path] = newValue
        }
    }

    public subscript<T: Model>(dynamicMember path: KeyPath<M, T>) -> Binding<T> {
        Binding {
            wrappedValue[keyPath: path]
        } set: { _ in }
    }

    public nonisolated static func == (lhs: ObservedModel, rhs: ObservedModel) -> Bool {
        guard let lCounts = lhs.modificationCounts, let rCounts = rhs.modificationCounts else {
            return false
        }

        return lCounts == rCounts
    }
}

public extension Binding {
    subscript<Subject: Model>(dynamicMember keyPath: KeyPath<Value, Subject>&Sendable) -> Binding<Subject> where Value: Sendable {
        Binding<Subject> {
            wrappedValue[keyPath: keyPath]
        } set: { _ in }
    }
}

public struct UsingModel<M: Model, Content: View>: View {
    @ObservedModel var model: M
    var content: (M) -> Content

    public init(_ model: M, @ViewBuilder content: @escaping (M) -> Content) {
        self.model = model
        self.content = content
    }

    public var body: some View {
        content(model)
    }
}

private class BaseObserver {
    func reset() { fatalError() }
}

private final class Observer<M: Model>: BaseObserver, @unchecked Sendable { // Protected by ViewAccess's lock
    weak var context: Context<M>?
    weak var viewAccess: ViewAccess?
    var accesses: [PartialKeyPath<M>: (Any, () -> Void)] = [:]

    init(context: Context<M>, viewAccess: ViewAccess) {
        self.context = context
        self.viewAccess = viewAccess
        super.init()
    }

    deinit {
        reset()
    }

    override func reset() {
        for (_ , cancellable) in accesses.values {
            cancellable()
        }
        accesses.removeAll(keepingCapacity: true)
    }
}

private final class ViewAccess: ModelAccess, ObservableObject, @unchecked Sendable {
    let lock = NSLock()
    var observers: [AnyHashable: BaseObserver] = [:]
    var shouldReset = false

    init() {
        super.init(useWeakReference: true)
    }

    override func willAccess<M: Model, Value>(_ model: M, at path: WritableKeyPath<M, Value>&Sendable) -> (() -> Void)? {
        if ModelAccess.isInModelTaskContext {
            return nil
        }

        lock.lock()

        if shouldReset {
            shouldReset = false

            for (_, observer) in observers {
                observer.reset()
            }

            observers.removeAll(keepingCapacity: true)
        }

        let id = model.modelID

        let observer = (observers[id] as? Observer<M>) ?? Observer(context: model.context!, viewAccess: self)
        observers[id] = observer

        if observer.accesses[path] == nil, let context = model.context {
            lock.unlock()
            let access = context.onModify(for: path) { [weak self] finished in
                return {
                    if !finished {
                        let newValue = context[path]
                        let didChange = self?.lock {
                            if let oldValue = observer.accesses[path]?.0, isEqual(oldValue, newValue) == true {
                                return false
                            }

                            observer.accesses[path]?.0 = newValue
                            return true
                        }

                        if didChange == true {
                            self?.didUpdate()
                        }
                    } else {
                        self?.lock {
                            observer.accesses[path] = nil
                        }
                    }
                }
            }
            let initialValue = context[path]
            lock.lock()
            observer.accesses[path] = (initialValue, access)
        }
        observers[id] = observer

        lock.unlock()
        return nil
    }

    override var shouldPropagateToChildren: Bool { true }

    func didUpdate() {
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            Task { @MainActor in
                objectWillChange.send()
            }
        }
    }

    nonisolated func reset() {
        lock {
            shouldReset = true
        }

        Task { @MainActor in
            lock { shouldReset = false }
        }
    }
}

#endif
