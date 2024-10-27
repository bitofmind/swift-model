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
            access.updateObserved(wrappedValue)
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

private final class Observer<M: Model>: @unchecked Sendable {
    // Protected by ViewAccess's lock
    weak var context: Context<M>?
    weak var viewAccess: ViewAccess?
    var accesses: [PartialKeyPath<M>: ((any Equatable)?, () -> Void)] = [:]

    init(context: Context<M>, viewAccess: ViewAccess) {
        self.context = context
        self.viewAccess = viewAccess
    }

    deinit {
        for (_ , cancellable) in accesses.values {
            cancellable()
        }
    }
}

private final class ViewAccess: ModelAccess, ObservableObject, @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [ModelID: AnyObject] = [:]
    private var root: AnyContext?

    init() {
        super.init(useWeakReference: true)
    }

    func updateObserved<M: Model>(_ model: M) {
        lock.withLock {
            if let root, root !== model.context {
                observers.removeAll(keepingCapacity: true)
            }
            self.root = model.context
        }
    }

    override func willAccess<M: Model, Value>(_ model: M, at path: WritableKeyPath<M, Value>&Sendable) -> (() -> Void)? {
        guard let context = model.context, !ModelAccess.isInModelTaskContext else {
            return nil
        }

        let id = model.modelID

        if context.isDestructed {
            lock {
                observers[id] = nil
            }
            return nil
        }

        if let root {
            if root.isDestructed {
                lock {
                    observers.removeAll(keepingCapacity: true)
                }
                return nil
            }

            if !context.hasPredecessor(root), root !== context {
                lock {
                    observers[id] = nil
                }
                return nil
            }
        }

        lock.lock()

        let observer = (observers[id] as? Observer<M>) ?? Observer(context: context, viewAccess: self)
        observers[id] = observer

        if observer.accesses[path] == nil {
            lock.unlock()

            let access = context.onModify(for: path) { [weak self] finished in
                guard let self else {
                    return {}
                }

                return {
                    if !finished {
                        let shouldUpdate = self.lock {
                            if let oldValue = observer.accesses[path]?.0, let newValue = context[path] as? any Equatable {
                                if isEqual(oldValue, newValue) == true {
                                    return false
                                } else {
                                    observer.accesses[path]?.0 = newValue
                                }
                            }

                            return true
                        }

                        if shouldUpdate {
                            self.didUpdate()
                        }
                    } else {
                        self.lock {
                            observer.accesses[path] = nil
                        }
                    }
                }
            }
            
            let initialValue = context[path] as? any Equatable
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
}

#endif
