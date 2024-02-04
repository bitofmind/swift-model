import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension DeclSyntaxProtocol {
    var isStoredProperty: Bool {
        if let property = self.as(VariableDeclSyntax.self),
           let binding = property.bindings.first,
           let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
           identifier.text != "context" {

            if let accessors = binding.accessorBlock?.accessors.as(AccessorDeclListSyntax.self) {
                for accessor in accessors {
                    let text = accessor.accessorSpecifier.text
                    if text != "willSet" && text != "didSet" {
                        return false
                    }
                }
                return true
            }

            return binding.accessorBlock == nil
        }

        return false
    }
}

extension VariableDeclSyntax {
    var isComputed: Bool {
        if accessorsMatching({ $0 == .keyword(.get) }).count > 0 {
            return true
        } else {
            return bindings.contains { binding in
                if case .getter = binding.accessorBlock?.accessors {
                    return true
                } else {
                    return false
                }
            }
        }
    }

    func accessorsMatching(_ predicate: (TokenKind) -> Bool) -> [AccessorDeclSyntax] {
        let patternBindings = bindings.compactMap { binding in
            binding.as(PatternBindingSyntax.self)
        }
        let accessors: [AccessorDeclListSyntax.Element] = patternBindings.compactMap { patternBinding in
            switch patternBinding.accessorBlock?.accessors {
            case .accessors(let accessors):
                return accessors
            default:
                return nil
            }
        }.flatMap { $0 }
        return accessors.compactMap { accessor in
            guard let decl = accessor.as(AccessorDeclSyntax.self) else {
                return nil
            }
            if predicate(decl.accessorSpecifier.tokenKind) {
                return decl
            } else {
                return nil
            }
        }
    }

    var isInstance: Bool {
        for modifier in modifiers {
            for token in modifier.tokens(viewMode: .all) {
                if token.tokenKind == .keyword(.static) || token.tokenKind == .keyword(.class) {
                    return false
                }
            }
        }
        return true
    }


    var isImmutable: Bool {
        return bindingSpecifier.tokenKind == .keyword(.let)
    }

    var isValidForObservation: Bool {
        !isComputed && isInstance && !isImmutable && identifier != nil
    }

    func hasMacroApplication(_ name: String) -> Bool {
        for attribute in attributes {
            switch attribute {
            case .attribute(let attr):
                if attr.attributeName.tokens(viewMode: .all).map({ $0.tokenKind }) == [.identifier(name)] {
                    return true
                }
            default:
                break
            }
        }
        return false
    }

    func privatePrefixed(_ prefix: String, addingAttribute attribute: AttributeSyntax) -> VariableDeclSyntax {
        VariableDeclSyntax(
            leadingTrivia: leadingTrivia,
            attributes: attributes + [.attribute(attribute)],
            modifiers: modifiers.privatePrefixed(prefix),
            bindingSpecifier: TokenSyntax(bindingSpecifier.tokenKind, leadingTrivia: .space, trailingTrivia: .space, presence: .present),
            bindings: bindings.privatePrefixed(prefix),
            trailingTrivia: trailingTrivia
        )
    }

}

extension PatternBindingListSyntax {
    func privatePrefixed(_ prefix: String) -> PatternBindingListSyntax {
        var bindings = self.map { $0 }
        for index in 0..<bindings.count {
            let binding = bindings[index]
            if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
                bindings[index] = PatternBindingSyntax(
                    leadingTrivia: binding.leadingTrivia,
                    pattern: IdentifierPatternSyntax(
                        leadingTrivia: identifier.leadingTrivia,
                        identifier: identifier.identifier.privatePrefixed(prefix),
                        trailingTrivia: identifier.trailingTrivia
                    ),
                    typeAnnotation: binding.typeAnnotation,
                    initializer: binding.initializer,
                    accessorBlock: nil,// binding.accessorBlock,
                    trailingComma: binding.trailingComma,
                    trailingTrivia: binding.trailingTrivia)

            }
        }

        return PatternBindingListSyntax(bindings)
    }
}

extension TokenSyntax {
    func privatePrefixed(_ prefix: String) -> TokenSyntax {
        switch tokenKind {
        case .identifier(let identifier):
            return TokenSyntax(.identifier(prefix + identifier), leadingTrivia: leadingTrivia, trailingTrivia: trailingTrivia, presence: presence)
        default:
            return self
        }
    }
}

extension DeclModifierListSyntax {
    func privatePrefixed(_ prefix: String) -> DeclModifierListSyntax {
        let modifier: DeclModifierSyntax = DeclModifierSyntax(name: "private", trailingTrivia: .space)
        return [modifier] + filter {
            switch $0.name.tokenKind {
            case .keyword(let keyword):
                switch keyword {
                case .fileprivate: fallthrough
                case .private: fallthrough
                case .internal: fallthrough
                case .public:
                    return false
                default:
                    return true
                }
            default:
                return true
            }
        }
    }
}

extension VariableDeclSyntax {
    var identifierPattern: IdentifierPatternSyntax? {
        bindings.first?.pattern.as(IdentifierPatternSyntax.self)
    }

    var identifier: TokenSyntax? {
        identifierPattern?.identifier.trimmed
    }
}

extension DeclGroupSyntax {
    var definedVariables: [VariableDeclSyntax] {
        memberBlock.members.compactMap { member in
            if let variableDecl = member.as(MemberBlockItemSyntax.self)?.decl.as(VariableDeclSyntax.self) {
                return variableDecl
            }
            return nil
        }
    }
}
