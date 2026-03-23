import Dependencies
public import Observation

/// Transforms a struct into a SwiftModel model.
///
/// Apply `@Model` to a `struct` to make it a fully-featured SwiftModel model. The macro:
///
/// - Synthesizes `@Observable`-compatible property storage and change tracking.
/// - Generates `Model`, `Identifiable`, `Sendable`, and `CustomStringConvertible` conformances.
/// - Adds a `node` property (`ModelNode<Self>`) for accessing the model's lifecycle APIs
///   (`onActivate`, `task`, `forEach`, `send`, `onCancel`, etc.).
///
/// ```swift
/// @Model
/// struct CounterModel {
///     var count = 0
///
///     func onActivate() {
///         // Called when the model enters the hierarchy.
///     }
/// }
/// ```
///
/// Properties are observable by default. Use `@ModelIgnored` to opt out, or store child models
/// directly as properties — they are automatically managed as part of the model hierarchy.
///
/// ## Identity
///
/// The macro generates an `id: ModelID` property for `Identifiable` conformance. If you declare
/// your own `id` property, the macro honours it and does **not** generate a `ModelID`-based one:
///
/// ```swift
/// @Model struct TodoModel {
///     let id: Int       // used as the Identifiable.id
///     var title: String
/// }
/// ```
///
/// See ``Model`` for full details on model identity.
@attached(extension, conformances: Model, Sendable, Identifiable, CustomReflectable, Observable, CustomStringConvertible, CustomDebugStringConvertible, names: named(customMirror), named(description), named(debugDescription))
@attached(member, names: named(_$modelContext), named(_$contextInit), named(_context), named(_updateContext), named(node), named(isEqual), named(visit), named(==))
@attached(memberAttribute)
public macro Model() = #externalMacro(module: "SwiftModelMacros", type: "ModelMacro")

/// Transforms a struct or enum into a `ModelContainer` — a type that holds `@Model`-typed children.
///
/// Apply `@ModelContainer` to a non-model type (e.g. an `Optional`, `Array`, or a custom wrapper)
/// when you want SwiftModel to traverse its children during hierarchy operations. The macro
/// synthesizes the `visit(_:)` method required by the `ModelContainer` protocol.
///
/// In practice you rarely need this macro directly: `Optional<M>` and `Array<M>` already conform
/// to `ModelContainer` for any `@Model` type `M`. Use `@ModelContainer` only when creating your
/// own container types.
@attached(extension, conformances: ModelContainer, Equatable, Hashable, Identifiable, names: named(visit), named(==), named(hash), named(id))
@attached(member, names: named(==), named(hash), named(id))
public macro ModelContainer() = #externalMacro(module: "SwiftModelMacros", type: "ModelContainerMacro")

/// Internal macro applied by `@Model` to tracked (observable) properties.
///
/// > Warning: Do not apply this macro directly. It is an implementation detail of `@Model`.
@attached(accessor, names: named(init), named(_read), named(_modify))
@attached(peer, names: prefixed(_))
public macro _ModelTracked() = #externalMacro(module: "SwiftModelMacros", type: "ModelTrackedMacro")

/// Internal macro applied by `@Model` to ignored (non-observable) properties.
///
/// > Warning: Do not apply this macro directly. It is an implementation detail of `@Model`.
@attached(accessor, names: named(willSet))
public macro _ModelIgnored() = #externalMacro(module: "SwiftModelMacros", type: "ModelIgnoredMacro")

/// Exposes a `swift-dependencies` dependency as a computed property on a model.
///
/// Apply `@ModelDependency` to a computed property to automatically resolve its value from the
/// model's dependency container rather than from a global `@Dependency`. This ensures the
/// dependency respects any overrides injected via `andTester { }` or `withDependencies { }`:
///
/// ```swift
/// @Model
/// struct FeatureModel {
///     @ModelDependency var apiClient: APIClient
///
///     func onActivate() {
///         node.task {
///             let data = try await apiClient.fetch()
///             // ...
///         }
///     }
/// }
/// ```
@attached(accessor, names: named(get))
public macro ModelDependency() = #externalMacro(module: "SwiftModelMacros", type: "ModelDependencyMacro")
