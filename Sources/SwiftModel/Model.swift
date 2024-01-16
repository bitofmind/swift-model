import Foundation
import AsyncAlgorithms
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
    var _$modelContext: ModelContext<Self> { get set }

    /// The type of events that this model can send
    associatedtype Event = ()

    /// Will be called once a model becomes part of a anchored model hierarchy.
    /// > Any parent will always be activated before its children to allow the parent to set up listener on child events and value changes
    /// 
    /// > Any children will always be deactivated (cancelled) before its parent to allow the parent to tear down listener on child events and value changes
    func onActivate()
}

public extension Model {
    /// An automatically generated id
    var id: ModelID { modelID }

    func onActivate() { }
}


/// Model modifiers
public extension Model {
    func withDependencies(_ dependencies: @escaping (inout DependencyValues) -> Void) -> Self {
        withSetupAccess {
            $0.dependencies.append(dependencies)
        }
    }

    func withActivation(_ onActivate: @escaping (Self) -> Void, function: String = #function) -> Self {
        withSetupAccess(modify:  {
            $0.activations.append(onActivate)
        }, function: function)
    }

    func _withPrintChanges(name: String? = nil, to printer: some TextOutputStream&Sendable = PrintTextOutputStream()) -> Self where Self: Sendable {
        withActivation {
            $0._printChanges(name: name, to: printer)
        }
    }

    func withPrintingActivationEvents(name: String? = nil, to printer: some TextOutputStream&Sendable = PrintTextOutputStream()) -> Self {
        let name = name ?? typeDescription
        return withActivation { model in
            var printer = printer
            printer.write("\(name) was activated")
            guard let context = model.enforcedContext() else { return }
            _ = AnyCancellable(context: context) { [printer] in
                var printer = printer
                printer.write("\(name) was deactivated")
            }
        }
    }
}

