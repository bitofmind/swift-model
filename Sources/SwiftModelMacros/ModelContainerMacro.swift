import SwiftDiagnostics
import SwiftOperators
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ModelContainerMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext) throws -> [ExtensionDeclSyntax]
    {
        let protocolName = "SwiftModel.ModelContainer"

        if declaration.is(StructDeclSyntax.self) {
            let memberList = declaration.memberBlock.members.filter {
                $0.decl.isObservableStoredProperty
            }

            let visits = memberList.compactMap { member in
                if let identifier = member.decl.as(VariableDeclSyntax.self)?.identifier {
                    return "visitor.visitStatically(at: \\.\(identifier))"
                }
                return nil
            }

            let visit: DeclSyntax =
            """
            public func visit(with visitor: inout ContainerVisitor<Self>) {
                \(raw: visits.joined(separator: "\n"))
            }
            """

            let decl: DeclSyntax = """
              extension \(raw: type.trimmedDescription): \(raw: protocolName) {
              \(raw: visit)
              }
              """

            return [decl.cast(ExtensionDeclSyntax.self)]
        } else if declaration.is(EnumDeclSyntax.self) {

            let members = declaration.memberBlock.members
            let caseDecls = members.compactMap { $0.decl.as(EnumCaseDeclSyntax.self) }
            let elements = caseDecls.flatMap(\.elements)


            let visits: [String] = elements.compactMap { element in
                guard let params = element.parameterClause?.parameters, params.count > 0 else {
                    return
              """
              case .\(element.name): 
              break

              """
                }

                func parameters(skipIndex: Int? = nil, onlyIndex: Int? = nil) -> String {
                    params.enumerated().map { index, param in
                        let value = if let skipIndex {
                            skipIndex == index ? "_" : "value\(index+1)"
                        } else if let onlyIndex {
                            onlyIndex != index ? "_" : "value\(index+1)"
                        } else {
                            "value\(index+1)"
                        }

                        return if let name = param.firstName?.text {
                            "\(name): \(value)"
                        } else {
                            value
                        }
                    }.joined(separator: ", ")
                }

                let visits = (0..<params.count).map { index in
                    """
                    visitor.visitStatically(at: path(caseName: "\(element.name)\(params.count == 1 ? "" : ".\(index)")", value: value\(index+1)) { root in
                            if case let .\(element.name)(\(parameters(onlyIndex: index))) = root {
                                value\(index+1)
                            } else {
                                nil
                            }
                        } set: { root, value in
                            if case \(params.count > 1 ? "let" : "") .\(element.name)(\(parameters(skipIndex: index))) = root {
                                let value\(index+1) = value
                                root = .\(element.name)(\(parameters()))
                            }
                        })

                    """
                }.joined(separator: "\n")

                return """
                case let .\(element.name)(\(parameters())):
                \(visits)
                
                """
            }

            let decl: DeclSyntax =
            """
            extension \(raw: type.trimmedDescription): \(raw: protocolName) {
                public func visit(with visitor: inout ContainerVisitor<Self>) {
                    switch self {
                    \(raw: visits.joined(separator: ""))
                    }
                }

              }
            """

            return [decl.cast(ExtensionDeclSyntax.self)]
        } else {
            throw ModelMacroError.requiresStructOrEnum
        }
    }
}
