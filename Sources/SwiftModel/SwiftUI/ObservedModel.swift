#if canImport(SwiftUI)
import SwiftUI
import Observation

/// Sets up a model for observation to invalidate the view when state changes.
///
/// Use the projectedValue to access a binding of a property such as `$model.count`.
///
/// >  In iOS 17, tvOS 17, macOS 14 and watchOS 10.0, `@ObservedModel` is not required, instead your models will automatically conform to the new `Observable` protocol.
///
/// > In iOS 17, tvOS 17, macOS 14 and watchOS 10.0, `@ObservedModel` is not required, here you will use SwiftUI's new `@Bindable` annotation instead.
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
@available(iOS, deprecated: 17.0, message: "@ObservedModel can be removed or replaced with @Bindable")
@available(macOS, deprecated: 14.0, message: "@ObservedModel can be removed or replaced with @Bindable")
@available(tvOS, deprecated: 17.0, message: "@ObservedModel can be removed or replaced with @Bindable")
@available(watchOS, deprecated: 10.0, message: "@ObservedModel can be removed or replaced with @Bindable")
@propertyWrapper @dynamicMemberLookup
public struct ObservedModel<M: Model>: DynamicProperty {
    @StateObject private var access = ViewAccess()
    
    public init(wrappedValue: M) {
        self.wrappedValue = wrappedValue
    }
    
    public var wrappedValue: M

    public mutating func update() {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), wrappedValue is Observable {
            return
        }
        wrappedValue = wrappedValue.withAccess(access)
        access.reset()
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
    var accesses: [PartialKeyPath<M>: () -> Void] = [:]

    init(context: Context<M>, viewAccess: ViewAccess) {
        self.context = context
        self.viewAccess = viewAccess
        super.init()
    }

    deinit {
        reset()
    }

    override func reset() {
        for cancellable in accesses.values {
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

    override func willAccess<M: Model, Value>(_ model: M, at path: WritableKeyPath<M, Value>) -> (() -> Void)? {
        if ModelAccess.isInModelTaskContext {
            return nil
        }

        return lock {
            if shouldReset {
                shouldReset = false
                
                for (_, observer) in observers {
                    observer.reset()
                }

                observers.removeAll(keepingCapacity: true)
            }

            let id = model.modelID

            let observer = (observers[id] as? Observer<M>) ?? Observer(context: model.context!, viewAccess: self)
            if observer.accesses[path] == nil {
                observer.accesses[path] = model.context!.onModify(for: path) { [weak self] finished in
                    if !finished {
                        self?.didUpdate()
                    } else {
                        self?.lock {
                            observer.accesses[path] = nil
                        }
                    }
                }
            }
            observers[id] = observer
            return nil
        }
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

    func reset() {
        lock {
            shouldReset = true
        }

        Task { @MainActor in
            lock { shouldReset = false }
        }
    }
}

#endif
