import SwiftDiagnostics
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

private enum ModelDependencyDiagnostic: DiagnosticMessage {
    case requiresVar
    case requiresInstance
    case requiresStored
    case initializerIgnored

    var message: String {
        switch self {
        case .requiresVar:
            return "@ModelDependency requires a 'var' declaration"
        case .requiresInstance:
            return "@ModelDependency cannot be applied to static properties"
        case .requiresStored:
            return "@ModelDependency cannot be applied to computed properties"
        case .initializerIgnored:
            return "Initial value of a @ModelDependency property is ignored; the value is resolved from the dependency container"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "SwiftModelMacros", id: "\(self)")
    }

    var severity: DiagnosticSeverity {
        switch self {
        case .requiresVar, .requiresInstance, .requiresStored:
            return .error
        case .initializerIgnored:
            return .warning
        }
    }
}

public struct ModelDependencyMacro: AccessorMacro {
    public static func expansion<Context: MacroExpansionContext, Declaration: DeclSyntaxProtocol>(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: Declaration,
        in context: Context
    ) throws -> [AccessorDeclSyntax] {
        guard let property = declaration.as(VariableDeclSyntax.self) else {
            return []
        }

        if property.isImmutable {
            context.diagnose(Diagnostic(node: node, message: ModelDependencyDiagnostic.requiresVar))
            return []
        }

        if !property.isInstance {
            context.diagnose(Diagnostic(node: node, message: ModelDependencyDiagnostic.requiresInstance))
            return []
        }

        if property.isComputed {
            context.diagnose(Diagnostic(node: node, message: ModelDependencyDiagnostic.requiresStored))
            return []
        }

        if property.hasMacroApplication("ModelIgnored") {
            return []
        }

        // Warn if the property has an initializer — it will be discarded when the accessor is added.
        if property.bindings.contains(where: { $0.initializer != nil }) {
            context.diagnose(Diagnostic(node: node, message: ModelDependencyDiagnostic.initializerIgnored))
        }

        let readAccessor: AccessorDeclSyntax =
        """
        get { _$modelContext.dependency() }
        """

        return [readAccessor]
    }
}
