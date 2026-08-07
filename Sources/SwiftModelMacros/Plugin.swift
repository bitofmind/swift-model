import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct SwiftModelMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ModelMacro.self,
        ModelContainerMacro.self,
        ModelTrackedMacro.self,
        ModelIgnoredMacro.self,
        ModelDependencyMacro.self,
    ]
}

