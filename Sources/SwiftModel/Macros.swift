import Dependencies
import Observation

@attached(extension, conformances: Model, Sendable, Identifiable, CustomReflectable, Observable, CustomStringConvertible, names: named(customMirror), named(description))
@attached(member, names: named(_$modelContext), named(node), named(_node), named(isEqual), named(visit), named(==))
@attached(memberAttribute)
public macro Model() = #externalMacro(module: "SwiftModelMacros", type: "ModelMacro")

@attached(extension, conformances: ModelContainer, names: named(visit))
public macro ModelContainer() = #externalMacro(module: "SwiftModelMacros", type: "ModelContainerMacro")

@attached(accessor, names: named(init), named(_read), named(_modify))
@attached(peer, names: prefixed(_))
public macro ModelTracked() = #externalMacro(module: "SwiftModelMacros", type: "ModelTrackedMacro")

@attached(accessor, names: named(willSet))
public macro ModelIgnored() = #externalMacro(module: "SwiftModelMacros", type: "ModelIgnoredMacro")
