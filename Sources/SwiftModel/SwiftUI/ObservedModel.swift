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

    public init(wrappedValue: M) {
        self.wrappedValue = wrappedValue
    }

    public init(projectedValue: Self) {
        self.init(wrappedValue: projectedValue.wrappedValue)
    }

    public var wrappedValue: M
    public var projectedValue: Self { self }

    public nonisolated mutating func update() {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *),
            wrappedValue.context?.hasObservationRegistrar == true {
            return
        }

        MainActor.assumeIsolated {
            wrappedValue = wrappedValue.withAccess(access)
            access.updateObserved(wrappedValue)
        }
    }

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

    public var binding: Binding<M> {
        Binding {
            wrappedValue
        } set: { _ in }
    }

    public nonisolated static func == (lhs: ObservedModel, rhs: ObservedModel) -> Bool {
        lhs.wrappedValue.modelID == rhs.wrappedValue.modelID
    }
}

public extension Binding {
    subscript<Subject: Model>(dynamicMember keyPath: KeyPath<Value, Subject>&Sendable) -> Binding<Subject> where Value: Model {
        Binding<Subject> {
            wrappedValue[keyPath: keyPath]
        } set: { _ in }
    }
}

/// A view that presents a model with observation enabled, passing it to a content closure.
///
/// > This view is deprecated. Use ``ModelScope`` instead — it covers all use cases
/// > without requiring an explicit model parameter and no longer ties the scope to a single model type.
@available(*, deprecated, message: "Use ModelScope instead.")
public struct UsingModel<M: Model, Content: View>: View {
    @ObservedModel var model: M
    var content: (Binding<M>) -> Content

    public init(_ model: M, @ViewBuilder content: @escaping (M) -> Content) {
        self.model = model
        self.content = {
            content($0.wrappedValue)
        }
    }

    public init(_ model: ObservedModel<M>, @ViewBuilder content: @escaping (Binding<M>) -> Content) {
        self.model = model.wrappedValue
        self.content = content
    }

    public init(_ model: Binding<M>, @ViewBuilder content: @escaping (Binding<M>) -> Content) {
        self.model = model.wrappedValue
        self.content = content
    }

    public var body: some View {
        content($model.binding)
    }
}

/// A view that scopes observation to its content, preventing unnecessary
/// re-renders of the containing view.
///
/// When a parent view accesses a model property, SwiftUI re-renders the
/// *entire* parent whenever that property changes — even if the property is
/// only used in a small part of the view hierarchy. Wrapping that part in
/// `ModelScope` confines observation to the scope itself: only `ModelScope`
/// re-renders when its accessed properties change, leaving the parent unaffected.
///
/// ```swift
/// struct TrackView: View {
///     var segment: SegmentModel  // no @ObservedModel — view is stable
///
///     var body: some View {
///         baseTrackView
///             .overlay {
///                 // Only this scope re-renders when isHovering changes.
///                 // Without ModelScope the overlay has no observation at all
///                 // (no @ObservedModel in TrackView), or with @ObservedModel
///                 // the entire TrackView re-renders for every hover change.
///                 ModelScope {
///                     if segment.isHovering { HoverOverlay() }
///                 }
///             }
///     }
/// }
/// ```
///
/// `ModelScope` observes *all* models accessed inside the closure — not just
/// one — so mixed-model content is naturally handled:
///
/// ```swift
/// ModelScope {
///     if segment.isHovering || editor.isExternalPaneActive { ... }
/// }
/// ```
///
/// ## Migrating from `UsingModel`
///
/// `UsingModel` is deprecated. `ModelScope` covers all its use cases without
/// requiring an explicit model parameter — the content closure captures models
/// from the enclosing scope:
///
/// ```swift
/// // Before (deprecated):
/// UsingModel(segment) { segment in
///     if segment.isHovering { ... }
/// }
///
/// // After:
/// ModelScope {
///     if segment.isHovering { ... }
/// }
/// ```
///
/// ## iOS 16 lazy-closure fix
///
/// `ModelScope` also fixes a secondary iOS 16 issue: certain SwiftUI APIs
/// evaluate their `@ViewBuilder` content in a separate rendering context,
/// breaking the observation chain if no scope boundary is present. Affected
/// APIs include `ModalContext`, `GeometryReader`, `.sheet`, `.popover`,
/// `.fullScreenCover`, and `NavigationStack` destination closures. On iOS 17
/// and later, SwiftUI's `withObservationTracking` handles these automatically.
///
/// ```swift
/// ModalContext {
///     ModelScope {
///         switch model.step { ... }
///     }
/// }
/// ```
public struct ModelScope<Content: View>: View {
    @StateObject private var access = ViewAccess()
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            // On iOS 17+, SwiftUI wraps every view body in withObservationTracking,
            // so the view boundary already scopes observation correctly.
            content()
        } else {
            usingActiveAccess(access) {
                content()
            }
        }
    }
}

private final class Observer<M: Model>: @unchecked Sendable {
    // Protected by ViewAccess's lock
    weak var context: Context<M>?
    weak var viewAccess: ViewAccess?
    var accesses: [PartialKeyPath<M._ModelState>: () -> Void] = [:]

    init(context: Context<M>, viewAccess: ViewAccess) {
        self.context = context
        self.viewAccess = viewAccess
    }

    deinit {
        for cancellable in accesses.values {
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

    override func willAccess<M: Model, Value>(from context: Context<M>, at path: KeyPath<M._ModelState, Value>&Sendable) -> (() -> Void)? {
        guard !ModelAccess.isInModelTaskContext else {
            return nil
        }

        let id = context.anyModelID

        if context.isDestructed {
            lock {
                observers[id] = nil
            }
            return nil
        }

        if let root, root.isDestructed {
            lock {
                observers.removeAll(keepingCapacity: true)
            }
            return nil
        }

        lock.lock()

        let observer = (observers[id] as? Observer<M>) ?? Observer(context: context, viewAccess: self)
        observers[id] = observer

        if observer.accesses[path] == nil {
            lock.unlock()

            let access = context.onModify(for: path) { [weak self] finished, _ in
                guard let self else {
                    return {}
                }

                return {
                    if !finished {
                        context.mainCallQueue {
                            self.objectWillChange.send()
                        }
                    } else {
                        self.lock {
                            observer.accesses[path] = nil
                        }
                    }
                }
            }
            
            lock.lock()
            observer.accesses[path] = access
        }

        observers[id] = observer

        lock.unlock()
        return nil
    }

    override var shouldPropagateToChildren: Bool { true }
}

#endif
