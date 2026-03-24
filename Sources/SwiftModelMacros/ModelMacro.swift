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
            // Build the @unchecked Sendable extension programmatically rather than using a
            // string literal template.  On Linux Swift 6.1, SwiftSyntaxBuilder's parser
            // places @unchecked as an attribute on the extension declaration instead of as a
            // type attribute inside the inheritance clause, producing
            // "'unchecked' attribute only applies in inheritance clauses" at compile time.
            if !isConforming(to: "Sendable") {
                let uncheckedAttr = AttributeSyntax(
                    atSign: .atSignToken(),
                    attributeName: IdentifierTypeSyntax(name: .identifier("unchecked"))
                ).with(\.trailingTrivia, .space)
                let sendableType = AttributedTypeSyntax(
                    specifier: nil,
                    attributes: AttributeListSyntax([.attribute(uncheckedAttr)]),
                    baseType: IdentifierTypeSyntax(name: .identifier("Sendable"))
                )
                let extensionDecl = ExtensionDeclSyntax(
                    extensionKeyword: .keyword(.extension, trailingTrivia: .space),
                    extendedType: type,
                    inheritanceClause: InheritanceClauseSyntax(
                        colon: .colonToken(trailingTrivia: .space),
                        inheritedTypes: InheritedTypeListSyntax([
                            InheritedTypeSyntax(type: sendableType)
                        ])
                    ),
                    memberBlock: MemberBlockSyntax(
                        leftBrace: .leftBraceToken(leadingTrivia: .space),
                        members: MemberBlockItemListSyntax([]),
                        rightBrace: .rightBraceToken()
                    )
                )
                extensions.append(DeclSyntax(extensionDecl))
            }
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
                        node.mirror(of: self, children: [\(raw: mirrorChildren.joined(separator: ", "))])
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
                extension \(raw: type.trimmedDescription): \(raw: "CustomStringConvertible"), \(raw: "CustomDebugStringConvertible") {
                    public var description: String {
                        node.description(of: self)
                    }
                    public var debugDescription: String { description }
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
        !hasMacroApplication("_ModelIgnored") && !hasMacroApplication("ModelDependency")
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
        var _$contextInit: ModelContext<Self> = ModelContext<Self>()
        {
            @storageRestrictions(initializes: _$modelContext)
            init(initialValue) {
                _$modelContext = initialValue
            }
            get { fatalError("_$contextInit is an initializer-only property and must never be read") }
            set { fatalError("_$contextInit is an initializer-only property and must never be written after initialization") }
        }
        """)

        result.append(
        """
        public var _context: ModelContextAccess<Self> { ModelContextAccess(_$modelContext) }
        """)

        result.append(
        """
        private var _$modelContext: ModelContext<Self>
        """)

        result.append(
        """
        public mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
            _$modelContext = update._$modelContext
        }
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

        if property.hasMacroApplication("_ModelIgnored") || property.hasMacroApplication("ModelDependency") {
            return []
        }

        return ["@_ModelTracked"]
    }
}
