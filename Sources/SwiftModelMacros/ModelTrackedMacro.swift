import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ModelTrackedMacro: AccessorMacro {
    public static func expansion<
        Context: MacroExpansionContext,
        Declaration: DeclSyntaxProtocol
    >(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: Declaration,
        in context: Context
    ) throws -> [AccessorDeclSyntax] {
        guard let property = declaration.as(VariableDeclSyntax.self),
              property.isValidForObservation,
              let identifier = property.identifier else {
            return []
        }

        if property.hasMacroApplication("ModelIgnored") {
            return []
        }

        var didSet: CodeBlockItemListSyntax?
        var willSet: CodeBlockItemListSyntax?
        for binding in property.bindings {
            guard let accessors = binding.accessorBlock?.accessors.as(AccessorDeclListSyntax.self) else { continue }
            for accessor in accessors {
                if accessor.accessorSpecifier.text == "didSet" {
                    didSet = accessor.body?.statements
                }
                if accessor.accessorSpecifier.text == "willSet" {
                    willSet = accessor.body?.statements
                }
            }
        }

        let initAccessor: AccessorDeclSyntax =
        """
        @storageRestrictions(initializes: _\(identifier))
        init {
            _\(identifier) = newValue
        }
        """


        let readAccessor: AccessorDeclSyntax =
        """
        _read { yield _$modelContext[model: self, path: \\._\(identifier)] }
        """

        let modifyAccessor: AccessorDeclSyntax
        if didSet != nil || willSet != nil {
            modifyAccessor =
            """
            nonmutating set {
            let oldValue = _$modelContext[model: self, path: \\._\(identifier)]
            \(willSet?.trimmed ?? "")
            _$modelContext[model: self, path: \\._\(identifier)] = newValue
            \(didSet?.trimmed ?? "")
            }
            """
        } else {
            modifyAccessor =
            """
            nonmutating _modify {
                yield &_$modelContext[model: self, path: \\._\(identifier)]
            }
            """
        }

        return [initAccessor, readAccessor, modifyAccessor]
    }
}

extension ModelTrackedMacro: PeerMacro {
    public static func expansion<
        Context: MacroExpansionContext,
        Declaration: DeclSyntaxProtocol
    >(
        of node: SwiftSyntax.AttributeSyntax,
        providingPeersOf declaration: Declaration,
        in context: Context
    ) throws -> [DeclSyntax] {
        guard let property = declaration.as(VariableDeclSyntax.self),
          property.isValidForObservation
        else {
          return []
        }

        if property.hasMacroApplication("ModelIgnored")
          || property.hasMacroApplication("ModelTracked")
        {
          return []
        }

        let storage = DeclSyntax(
          property.privatePrefixed("_", addingAttribute: "@ModelIgnored"))
        return [storage]
    }
}
