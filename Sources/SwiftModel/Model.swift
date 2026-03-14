import Foundation
import Dependencies

/// A type that models the state and logic that drives e.g. SwiftUI views
///
/// > Important: You typically never confirms to `Model`directly instead you use the
/// `@Model` macro that will provided the required conformance and behavior.
///
///     @Model struct MyModel {
///         var count = 0
///     }
///
/// > Important: Models are required to be a `struct` to allow many of the powerful state
/// tracking that is used in tests and debugging.
/// 
/// To access a model state and methods from a view it should be declared using `@ObservedModel`:
///
///     struct MyView: View {
///         @ObservedModel var model: MyModel
///
///         var body: some View {
///             Text("count \(model.count)")
///         }
///     }
///
/// > In iOS 17, tvOS 17, macOS 14 and watchOS 10.0, `@ObservedModel` is not required, instead
/// your models will automatically conform to the `Observable` protocol.
///
/// Further the root model needs to anchored to be activated and function properly:
///
///     struct MyApp: App {
///         var body: some Scene {
///             WindowGroup {
///                 MyView(model: MyModel().withAnchor())
///             }
///         }
///     }
///
/// > A model is always identifiable, either by providing your own id or using a automatically generated identity id
public protocol Model: ModelContainer, Identifiable, Sendable {
    /// The type of events that this model can send
    associatedtype Event = ()

    /// Will be called once a model becomes part of a anchored model hierarchy.
    /// > Any parent will always be activated before its children to allow the parent to set up listener on child events and value changes
    /// 
    /// > Any remaining children will always be deactivated (cancelled) just after its parent deactivation to allow the parent to access and tear down listeners on child events and value changes.
    func onActivate()

    /// Framework internal. Do not use directly — use `node` instead.
    var _context: ModelContextAccess<Self> { get }

    /// Framework internal. Do not call directly.
    mutating func _updateContext(_ update: ModelContextUpdate<Self>)
}

public extension Model {
    /// An automatically generated id
    var id: ModelID { modelID }

    func onActivate() { }

    /// The runtime interface for this model.
    ///
    /// Use `node` to access SwiftModel's runtime APIs from within the model's own implementation —
    /// in `onActivate()`, in methods, and in extensions. It provides access to async tasks, events,
    /// cancellations, dependencies, memoization, and hierarchy queries.
    ///
    /// `node` is intended for use by the *model implementor*, not by *consumers* of a model.
    /// A view or parent model should interact with a model through the properties and methods the
    /// model explicitly exposes, not through `node`.
    var node: ModelNode<Self> { ModelNode(_$modelContext: _context._$modelContext) }
}

/// Model modifiers
public extension Model {
    /// Override dependencies for this model and its descendants.
    ///
    /// Use this to inject test doubles or configure dependencies before anchoring:
    ///
    /// ```swift
    /// AppModel()
    ///     .withDependencies {
    ///         $0.apiClient = .mock
    ///         $0.clock = .immediate
    ///     }
    ///     .withAnchor()
    /// ```
    ///
    /// Multiple `withDependencies` calls are additive — each closure is applied in order.
    func withDependencies(_ dependencies: @escaping (inout ModelDependencies) -> Void) -> Self {
        withSetupAccess {
            $0.dependencies.append(dependencies)
        }
    }

    /// Attach an activation closure to this model without modifying its source.
    ///
    /// The closure is called with the model instance immediately after `onActivate()` runs.
    /// This is useful for attaching side-effects or additional setup in previews, tests, or
    /// composition sites without subclassing or modifying the model's own `onActivate()`:
    ///
    /// ```swift
    /// let model = StandupModel()
    ///     .withActivation { $0.loadFromDisk() }
    ///     .withAnchor()
    /// ```
    ///
    /// Multiple `withActivation` calls are additive — closures run in declaration order.
    func withActivation(_ onActivate: @escaping (Self) -> Void, function: String = #function) -> Self {
        withSetupAccess(modify:  {
            $0.activations.append(onActivate)
        }, function: function)
    }

    /// Observes this model's entire state tree and prints debug output whenever anything changes.
    ///
    /// Apply as a modifier before anchoring the model. Only active in `DEBUG` builds.
    ///
    /// ```swift
    /// AppModel().withDebug().withAnchor()
    /// AppModel().withDebug([.triggers, .changes]).withAnchor()
    /// AppModel().withDebug([.changes(), .name("App"), .printer(myStream)]).withAnchor()
    /// ```
    ///
    /// To enable debugging only temporarily on a live model, use `debug()` on the model
    /// directly, which returns a `Cancellable` you can cancel when you're done:
    ///
    /// ```swift
    /// let cancel = model.debug()
    /// // ... do work ...
    /// cancel.cancel()
    /// ```
    func withDebug(_ options: DebugOptions = [.changes()]) -> Self where Self: Sendable {
        withActivation {
            $0.debug(options)
        }
    }

    /// - Deprecated: Use ``withDebug()`` instead.
    @available(*, deprecated, renamed: "withDebug()")
    func _withPrintChanges(name: String? = nil, to printer: some TextOutputStream&Sendable = PrintTextOutputStream()) -> Self where Self: Sendable {
        var opts: [DebugOption] = [.changes()]
        if let name { opts.append(.name(name)) }
        if !(printer is PrintTextOutputStream) { opts.append(.printer(printer)) }
        return withDebug(DebugOptions(opts))
    }

    /// Prints a message each time this model is activated or deactivated.
    ///
    /// Useful during development to understand model lifecycle — for example, to confirm that
    /// a child model is being properly removed when navigating away.
    ///
    /// ```swift
    /// RecordMeetingModel(standup: standup)
    ///     .withPrintingActivationEvents(name: "RecordMeeting")
    /// ```
    func withPrintingActivationEvents(name: String? = nil, to printer: some TextOutputStream&Sendable = PrintTextOutputStream()) -> Self {
        let name = name ?? typeDescription
        return withActivation { model in
            var printer = printer
            printer.write("\(name) was activated")
            guard let cancellations = model.enforcedContext()?.cancellations else { return }
            _ = AnyCancellable(cancellations: cancellations) { [printer] in
                var printer = printer
                printer.write("\(name) was deactivated")
            }
        }
    }
}

