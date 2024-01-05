import Dependencies
import Observation

@attached(extension, conformances: Model, Sendable, Identifiable, CustomReflectable, Observable, names: named(customMirror), named(visit))
@attached(member, names: named(_modelContext), named(node), named(isEqual), arbitrary)
@attached(memberAttribute)
public macro Model() = #externalMacro(module: "SwiftModelMacros", type: "ModelMacro")

@attached(extension, conformances: ModelContainer, names: named(visit), arbitrary)
public macro ModelContainer() = #externalMacro(module: "SwiftModelMacros", type: "ModelContainerMacro")

@attached(accessor, names: named(init), named(_read), named(_modify))
public macro ModelTracked() = #externalMacro(module: "SwiftModelMacros", type: "ModelTrackedMacro")

@attached(accessor, names: named(willSet))
public macro ModelIgnored() = #externalMacro(module: "SwiftModelMacros", type: "ModelIgnoredMacro")
