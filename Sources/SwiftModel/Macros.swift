import Dependencies
import Observation

@attached(extension, conformances: Model, Sendable, Identifiable, CustomReflectable, Observable, CustomStringConvertible, CustomDebugStringConvertible, names: named(customMirror), named(description), named(debugDescription))
@attached(member, names: named(_$modelContext), named(_$contextInit), named(_context), named(_updateContext), named(node), named(isEqual), named(visit), named(==))
@attached(memberAttribute)
public macro Model() = #externalMacro(module: "SwiftModelMacros", type: "ModelMacro")

@attached(extension, conformances: ModelContainer, names: named(visit))
public macro ModelContainer() = #externalMacro(module: "SwiftModelMacros", type: "ModelContainerMacro")

@attached(accessor, names: named(init), named(_read), named(_modify))
@attached(peer, names: prefixed(_))
public macro _ModelTracked() = #externalMacro(module: "SwiftModelMacros", type: "ModelTrackedMacro")

@attached(accessor, names: named(willSet))
public macro _ModelIgnored() = #externalMacro(module: "SwiftModelMacros", type: "ModelIgnoredMacro")

@attached(accessor, names: named(get))
public macro ModelDependency() = #externalMacro(module: "SwiftModelMacros", type: "ModelDependencyMacro")
