import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ModelMacro { }

extension ModelMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext) throws -> [ExtensionDeclSyntax] {
            guard let structDecl = declaration.as(StructDeclSyntax.self) else {
                return []
            }

            var extensions: [DeclSyntax] = []

            func isConforming(to name: String) -> Bool {
                structDecl.inheritanceClause.map {
                    $0.inheritedTypes.contains(where: { $0.type.trimmedDescription.contains(name)
                    })
                } ?? false
            }

            func addConformance(_ name: String, qualifiedName: String? = nil) {
                if !isConforming(to: name) {
                    extensions.append(
                    """
                    extension \(raw: type.trimmedDescription): \(raw: qualifiedName ?? name) {}
                    """)
                }
            }

            addConformance("Model", qualifiedName: "SwiftModel.Model")
            addConformance("Sendable")
            addConformance("Identifiable")

            let memberList = declaration.memberBlock.members.filter {
                $0.decl.isStoredProperty
            }

            let mirrorChildren = memberList.compactMap { member -> String? in
                guard let decl = member.decl.as(VariableDeclSyntax.self),
                      !decl.hasMacroApplication("ModelDependency"),
                      let identifier = decl.identifier else { return nil }

                return "(\"\(identifier)\", \(identifier) as Any)"
            }

            if !isConforming(to: "CustomReflectable") {
                extensions.append(
                """
                extension \(raw: type.trimmedDescription): \(raw: "CustomReflectable") {
                    public var customMirror: Mirror {
                        _$modelContext.mirror(of: self, children: [\(raw: mirrorChildren.joined(separator: ", "))])
                    }
                }
                """)
            }

            if !isConforming(to: "Observable") {
                extensions.append(
                """
                @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
                extension \(raw: type.trimmedDescription): \(raw: "Observation.Observable") {}
                """)
            }

            if !isConforming(to: "CustomStringConvertible") {
                extensions.append(
                """
                extension \(raw: type.trimmedDescription): \(raw: "CustomStringConvertible") {
                    public var description: String {
                        _$modelContext.description(of: self)
                    }
                }
                """)
            }
            return extensions.map { $0.cast(ExtensionDeclSyntax.self) }
        }
}

enum ModelMacroError: String, Error, CustomStringConvertible {
    case requiresStruct = "Requires type to be struct"
    case requiresStructOrEnum = "Requires type to be either struct or enum"

    var description: String { rawValue }
}

private extension VariableDeclSyntax {
    var isValid: Bool {
        !hasMacroApplication("ModelIgnored") && !hasMacroApplication("ModelDependency")
    }
}

extension ModelMacro: MemberMacro {
    public static func expansion<Declaration: DeclGroupSyntax,
                                 Context: MacroExpansionContext>(
        of node: AttributeSyntax,
        providingMembersOf declaration: Declaration,
        in context: Context
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw ModelMacroError.requiresStruct
        }

        var result: [DeclSyntax] = []

        let visits = declaration.definedVariables.filter {
            !$0.isComputed && $0.isInstance && $0.isValid
        }.compactMap { member -> String? in
            guard let identifier = member.identifier else { return nil }
            return "visitor.visitStatically(at: \\.\(member.isImmutable ? "" :  "_")\(identifier))"
        }

        result.append(
        """
        public func visit(with visitor: inout ContainerVisitor<Self>) {
            \(raw: visits.joined(separator: "\n"))
        }
        """
        )

        let storedInstanceVariables = declaration.definedVariables.filter {
            $0.isValidForObservation && $0.isValid
        }

        let inheritanceClause = structDecl.inheritanceClause
        if let inheritedTypes = inheritanceClause?.inheritedTypes,
           inheritedTypes.contains(where: { inherited in inherited.type.trimmedDescription == "Equatable" || inherited.type.trimmedDescription == "Hashable" })
        {


            let equals: [String] = storedInstanceVariables.compactMap { member in
                if let identifier = member.identifier, member.isValid {
                    //DeclSyntax("lhs._modelContext.getValue(at: \\._\(identifier), from: lhs) == rhs._modelContext.getValue(at: \\._\(identifier), from: rhs) && ")
                    return "lhs.\( identifier) == rhs.\(identifier)"
                } else {
                    return nil
                }
            }

            result.append(
            """
            public static func ==(_ lhs: Self, _ rhs: Self) -> Bool {
                \(raw: equals.isEmpty ? "true" : equals.joined(separator: " && "))
            }
            """
            )
        }

        if let inheritedTypes = inheritanceClause?.inheritedTypes,
           inheritedTypes.contains(where: { inherited in inherited.type.trimmedDescription == "Hashable" })
        {
            let hashables: [String] = storedInstanceVariables.compactMap { member in
                if let identifier = member.identifier, member.isValid {
                    return "hasher.combine(\(identifier))"
                } else {
                    return nil
                }
            }

            result.append(
            """
            func hash(into hasher: inout Hasher) {
                \(raw: hashables.joined(separator: "\n"))
            }
            """
            )
        }

        result.append(
        """
        public var _$modelContext: ModelContext<Self> = ModelContext<Self>()
        {
            @storageRestrictions(initializes: _node)
            init {
                _node = ModelNode(_$modelContext: newValue)
            }
            get {
                _node._$modelContext
            }
            set {
                _node = ModelNode(_$modelContext: newValue)
            }
        }
        """)

        result.append(
        """
        private var _node = ModelNode(_$modelContext: ModelContext<Self>())
        """)

        result.append(
        """
        private var node: ModelNode<Self> { _node }
        """)

        return result
    }
}

extension ModelMacro: MemberAttributeMacro {
    public static func expansion<
        Declaration: DeclGroupSyntax,
        MemberDeclaration: DeclSyntaxProtocol,
        Context: MacroExpansionContext
    >(
        of node: AttributeSyntax,
        attachedTo declaration: Declaration,
        providingAttributesFor member: MemberDeclaration,
        in context: Context
    ) throws -> [AttributeSyntax] {
        guard let property = member.as(VariableDeclSyntax.self), property.isValidForObservation,
              property.identifier != nil else {
            return []
        }

        if property.hasMacroApplication("ModelIgnored") || property.hasMacroApplication("ModelDependency") {
            return []
        }

        return ["@ModelTracked"]
    }
}
