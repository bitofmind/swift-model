import Foundation
import Dependencies

/// A type that models the state and logic that drives SwiftUI views.
///
/// Conform to `Model` via the `@Model` macro, which generates the required storage and
/// observation tracking:
///
/// ```swift
/// @Model struct CounterModel {
///     var count = 0
///
///     func incrementTapped() { count += 1 }
/// }
/// ```
///
/// > Important: Models must be `struct` types. Classes are not supported.
///
/// ## Using a model in SwiftUI
///
/// On iOS 17+ / macOS 14+, models automatically conform to `Observable` and can be used
/// directly with `@State` or passed as properties. On earlier platforms, use `@ObservedModel`:
///
/// ```swift
/// struct CounterView: View {
///     @ObservedModel var model: CounterModel
///
///     var body: some View {
///         Button("\(model.count)") { model.incrementTapped() }
///     }
/// }
/// ```
///
/// ## Anchoring
///
/// The root model must be anchored before use. Anchoring activates the model hierarchy and
/// calls each model's `onActivate()`:
///
/// ```swift
/// struct MyApp: App {
///     var body: some Scene {
///         WindowGroup {
///             ContentView(model: AppModel().withAnchor())
///         }
///     }
/// }
/// ```
///
/// ## Identity
///
/// Every model is `Identifiable`. By default, `@Model` synthesises an `id` property backed by
/// an auto-generated `ModelID` — a compact integer that is stable for the lifetime of the model
/// in the hierarchy.
///
/// If you declare your own `id` property, the macro uses it instead:
///
/// ```swift
/// @Model struct TodoModel {
///     let id: Int          // your own stable identity
///     var title: String
/// }
/// ```
///
/// > Note: Even when you provide your own `id`, SwiftModel still tracks the model instance
/// > internally using a `ModelID`. Your `id` is used for `Identifiable` conformance
/// > (e.g. `ForEach`, navigation stack paths) but is independent of the internal tracking.
public protocol Model: ModelContainer, Identifiable, Sendable {
    /// The type of events that this model can send
    associatedtype Event = ()

    /// Called once when the model is activated (becomes part of an anchored hierarchy).
    ///
    /// Use `onActivate()` to start async tasks, subscribe to events, and set up reactive
    /// observations. All work started here is automatically cancelled when the model is removed
    /// from the hierarchy.
    ///
    /// Parents are always activated before their children, and children are deactivated before
    /// their parents — so a parent can safely observe child events and tear them down in order.
    ///
    /// ```swift
    /// func onActivate() {
    ///     node.forEach(node.continuousClock.timer(interval: .seconds(1))) { _ in
    ///         elapsed += 1
    ///     }
    /// }
    /// ```
    func onActivate()

    /// Framework internal. Do not use directly — use `node` instead.
    var _context: ModelContextAccess<Self> { get }

    /// Framework internal. Do not call directly.
    mutating func _updateContext(_ update: ModelContextUpdate<Self>)
}

public extension Model {
    /// The model's identity, used for `Identifiable` conformance.
    ///
    /// This default implementation returns the auto-generated `ModelID`. It is shadowed when the
    /// model type declares its own `id` property of a different type.
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
    /// AppModel().withDebug(.triggers(.withValue)).withAnchor()
    /// AppModel().withDebug(.init(name: "App", printer: myStream)).withAnchor()
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
    func withDebug(_ options: DebugOptions = .all) -> Self where Self: Sendable {
        withActivation {
            $0.debug(options)
        }
    }

    /// - Deprecated: Use ``withDebug()`` instead.
    @available(*, deprecated, renamed: "withDebug()")
    func _withPrintChanges(name: String? = nil, to printer: some TextOutputStream&Sendable = PrintTextOutputStream()) -> Self where Self: Sendable {
        let p: (any TextOutputStream & Sendable)? = (printer is PrintTextOutputStream) ? nil : printer
        return withDebug(.init(triggers: nil, name: name, printer: p))
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

