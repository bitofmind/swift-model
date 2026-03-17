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
                $0.decl.isStoredProperty
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

            let enumDecl = declaration.as(EnumDeclSyntax.self)!

            // Check if the user has manually declared == or hash(into:) in the enum body.
            // If so, skip synthesis and let the user's implementation take over.
            let hasManualEquals = enumDecl.memberBlock.members.contains { member in
                guard let fn = member.decl.as(FunctionDeclSyntax.self) else { return false }
                return fn.name.text == "==" || fn.name.text == "hash"
            }

            // Determine if the type already declares Hashable or Equatable in its inheritance clause.
            // When Hashable is declared, Swift will NOT pass it in `conformingTo` (it's already satisfied).
            // In that case we provide == and hash as members via MemberMacro, not as extension conformances.
            // When neither is declared, we synthesise full Equatable+Hashable extensions here.
            let inheritedNames = Set(enumDecl.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? [])
            let declaresHashable = inheritedNames.contains("Hashable")
            let declaresEquatable = inheritedNames.contains("Equatable")

            // Only synthesise conformance extensions when the user hasn't declared Hashable themselves
            // (in which case the MemberMacro will provide the implementations instead).
            let wantsHashable = !hasManualEquals && !declaresHashable && protocols.contains(where: {
                $0.trimmedDescription == "Hashable"
            })
            // Synthesise Equatable extension only when Equatable isn't already declared in the clause.
            let wantsEquatable = wantsHashable && !declaresEquatable

            // When the user explicitly declares Hashable, Swift will not pass Hashable or Equatable
            // in `conformingTo` (they are considered already declared). We must still emit an explicit
            // extension conformance for Equatable containing the == implementation. Providing == as a
            // direct member (MemberMacro) while relying on a separate empty extension: Equatable {}
            // causes a Swift compiler crash during SIL generation. The correct pattern is to place ==
            // inside an extension: Equatable {} block. The MemberMacro will separately inject hash(into:).
            let needsEquatableExtension = declaresHashable && !declaresEquatable && !hasManualEquals

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

            var decls: [ExtensionDeclSyntax] = []

            let containerDecl: DeclSyntax =
            """
            extension \(raw: type.trimmedDescription): \(raw: protocolName) {
                public func visit(with visitor: inout ContainerVisitor<Self>) {
                    switch self {
                    \(raw: visits.joined(separator: ""))
                    }
                }

              }
            """
            decls.append(containerDecl.cast(ExtensionDeclSyntax.self))

            if needsEquatableExtension {
                // Build the == implementation inline in the Equatable extension.
                // This avoids a Swift compiler crash that occurs when == is a direct member
                // (from MemberMacro) AND a separate extension: Equatable {} is emitted.
                var equalsCasesForMember: [String] = []
                for element in elements {
                    let params = element.parameterClause?.parameters ?? []
                    let count = params.count
                    if count == 0 {
                        equalsCasesForMember.append("case (.\(element.name), .\(element.name)): return true")
                    } else {
                        func paramLabel(_ i: Int) -> String {
                            let p = params[params.index(params.startIndex, offsetBy: i)]
                            if let name = p.firstName?.text, name != "_" { return "\(name): " }
                            return ""
                        }
                        let lhsBindings = (0..<count).map { "\(paramLabel($0))l\($0+1)" }.joined(separator: ", ")
                        let rhsBindings = (0..<count).map { "\(paramLabel($0))r\($0+1)" }.joined(separator: ", ")
                        let comparisons = (0..<count).map { "_modelEqual(l\($0+1), r\($0+1))" }.joined(separator: " && ")
                        equalsCasesForMember.append("case let (.\(element.name)(\(lhsBindings)), .\(element.name)(\(rhsBindings))): return \(comparisons)")
                    }
                }
                equalsCasesForMember.append("default: return false")
                let equatableExtDecl: DeclSyntax =
                """
                extension \(raw: type.trimmedDescription): Equatable {
                    public static func == (lhs: Self, rhs: Self) -> Bool {
                        switch (lhs, rhs) {
                        \(raw: equalsCasesForMember.joined(separator: "\n        "))
                        }
                    }
                }
                """
                decls.append(equatableExtDecl.cast(ExtensionDeclSyntax.self))
            }

            if wantsEquatable {
                // Synthesise == using _modelEqual, which Swift resolves at compile time:
                // - Equatable types: uses full value equality (lhs == rhs)
                // - Identifiable-only types: falls back to identity (lhs.id == rhs.id)
                // Parameterless cases compare equal when the case name matches.
                var equalsCases: [String] = []
                for element in elements {
                    let params = element.parameterClause?.parameters ?? []
                    let count = params.count
                    if count == 0 {
                        equalsCases.append("case (.\(element.name), .\(element.name)): return true")
                    } else {
                        func paramLabel(_ i: Int) -> String {
                            let p = params[params.index(params.startIndex, offsetBy: i)]
                            if let name = p.firstName?.text, name != "_" { return "\(name): " }
                            return ""
                        }
                        let lhsBindings = (0..<count).map { "\(paramLabel($0))l\($0+1)" }.joined(separator: ", ")
                        let rhsBindings = (0..<count).map { "\(paramLabel($0))r\($0+1)" }.joined(separator: ", ")
                        let comparisons = (0..<count).map { "_modelEqual(l\($0+1), r\($0+1))" }.joined(separator: " && ")
                        equalsCases.append("case let (.\(element.name)(\(lhsBindings)), .\(element.name)(\(rhsBindings))): return \(comparisons)")
                    }
                }
                equalsCases.append("default: return false")

                let equatableDecl: DeclSyntax =
                """
                extension \(raw: type.trimmedDescription): Equatable {
                    public static func == (lhs: Self, rhs: Self) -> Bool {
                        switch (lhs, rhs) {
                        \(raw: equalsCases.joined(separator: "\n        "))
                        }
                    }
                }
                """
                decls.append(equatableDecl.cast(ExtensionDeclSyntax.self))
            }

            if wantsHashable {
                // Synthesise hash(into:) using _modelCombine, which Swift resolves at compile time:
                // - Hashable types: uses full Hashable conformance (hasher.combine(value))
                // - Identifiable-only types: falls back to identity (hasher.combine(value.id))
                var hashCases: [String] = []
                for element in elements {
                    let params = element.parameterClause?.parameters ?? []
                    let count = params.count
                    if count == 0 {
                        hashCases.append("""
                        case .\(element.name):
                            hasher.combine("\(element.name)")
                        """)
                    } else {
                        func paramLabel(_ i: Int) -> String {
                            let p = params[params.index(params.startIndex, offsetBy: i)]
                            if let name = p.firstName?.text, name != "_" { return "\(name): " }
                            return ""
                        }
                        let bindings = (0..<count).map { "\(paramLabel($0))v\($0+1)" }.joined(separator: ", ")
                        let combines = (0..<count).map { "_modelCombine(into: &hasher, v\($0+1))" }.joined(separator: "\n            ")
                        hashCases.append("""
                        case let .\(element.name)(\(bindings)):
                            hasher.combine("\(element.name)")
                            \(combines)
                        """)
                    }
                }

                let hashableDecl: DeclSyntax =
                """
                extension \(raw: type.trimmedDescription): Hashable {
                    public func hash(into hasher: inout Hasher) {
                        switch self {
                        \(raw: hashCases.joined(separator: "\n        "))
                        }
                    }
                }
                """
                decls.append(hashableDecl.cast(ExtensionDeclSyntax.self))
            }

            return decls
        } else {
            throw ModelMacroError.requiresStructOrEnum
        }
    }
}

extension ModelContainerMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
            return []
        }

        // Only inject members when the user explicitly declares Hashable in the inheritance clause.
        // In that case the ExtensionMacro emits `extension T: Equatable { == }` to satisfy
        // Equatable, and we inject only hash(into:) here as a direct member.
        // For Equatable-only declarations we don't synthesise — Swift's own auto-synthesis handles
        // simple cases, and the extension macro adds Hashable without redundant Equatable.
        let inheritedNames = Set(enumDecl.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? [])
        let declaresHashable = inheritedNames.contains("Hashable")

        guard declaresHashable else { return [] }

        // Respect manual implementations — if the user wrote == or hash, don't synthesise.
        let hasManualEquals = enumDecl.memberBlock.members.contains { member in
            guard let fn = member.decl.as(FunctionDeclSyntax.self) else { return false }
            return fn.name.text == "==" || fn.name.text == "hash"
        }

        guard !hasManualEquals else { return [] }

        let caseDecls = enumDecl.memberBlock.members.compactMap { $0.decl.as(EnumCaseDeclSyntax.self) }
        let elements = caseDecls.flatMap(\.elements)

        func paramLabel(params: EnumCaseParameterListSyntax, at i: Int) -> String {
            let p = params[params.index(params.startIndex, offsetBy: i)]
            if let name = p.firstName?.text, name != "_" { return "\(name): " }
            return ""
        }

        // Synthesise hash(into:) only.
        // == is synthesised by the ExtensionMacro inside `extension T: Equatable { ... }` to
        // avoid a Swift compiler crash that occurs when == is a direct member AND a separate
        // Equatable conformance extension is present.
        var hashCases: [String] = []
        for element in elements {
            let params = element.parameterClause?.parameters ?? []
            let count = params.count
            if count == 0 {
                hashCases.append("""
                case .\(element.name):
                    hasher.combine("\(element.name)")
                """)
            } else {
                let bindings = (0..<count).map { "\(paramLabel(params: params, at: $0))v\($0+1)" }.joined(separator: ", ")
                let combines = (0..<count).map { "_modelCombine(into: &hasher, v\($0+1))" }.joined(separator: "\n        ")
                hashCases.append("""
                case let .\(element.name)(\(bindings)):
                    hasher.combine("\(element.name)")
                    \(combines)
                """)
            }
        }

        let hashDecl: DeclSyntax =
        """
        public func hash(into hasher: inout Hasher) {
            switch self {
            \(raw: hashCases.joined(separator: "\n    "))
            }
        }
        """

        return [hashDecl]
    }
}
