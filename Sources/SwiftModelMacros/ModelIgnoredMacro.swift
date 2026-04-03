import SwiftDiagnostics
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

private enum ModelIgnoredDiagnostic: DiagnosticMessage {
    case computedProperty

    var message: String {
        "@ModelIgnored has no effect on computed properties"
    }

    var diagnosticID: MessageID {
        MessageID(domain: "SwiftModelMacros", id: "\(self)")
    }

    var severity: DiagnosticSeverity { .warning }
}

public struct ModelIgnoredMacro: AccessorMacro {
    public static func expansion<
        Context: MacroExpansionContext,
        Declaration: DeclSyntaxProtocol
    >(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: Declaration,
        in context: Context
    ) throws -> [AccessorDeclSyntax] {
        if let property = declaration.as(VariableDeclSyntax.self), property.isComputed {
            context.diagnose(Diagnostic(node: node, message: ModelIgnoredDiagnostic.computedProperty))
        }
        return []
    }
}
