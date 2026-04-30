import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Infers a type string from an initializer expression, or returns nil if type can't be inferred.
/// PascalCase function calls (e.g. `ChildModel()`) are treated as type constructors.
/// This fails for generic types like `LockIsolated(0)` — but those are typically `let` properties
/// with defaults, which are excluded from the generated init entirely.
private func inferType(from expr: ExprSyntax) -> String? {
    if expr.is(IntegerLiteralExprSyntax.self) { return "Int" }
    if expr.is(FloatLiteralExprSyntax.self) { return "Double" }
    if expr.is(BooleanLiteralExprSyntax.self) { return "Bool" }
    if expr.is(StringLiteralExprSyntax.self) { return "String" }
    if let call = expr.as(FunctionCallExprSyntax.self),
       let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
        let name = callee.baseName.text
        if let first = name.first, first.isUppercase {
            return name
        }
    }
    return nil
}

/// Returns true if the type syntax represents a function type (possibly wrapped in attributes).
private func isFunctionType(_ type: TypeSyntax?) -> Bool {
    guard let type else { return false }
    if type.is(FunctionTypeSyntax.self) { return true }
    if let attributed = type.as(AttributedTypeSyntax.self) {
        return attributed.baseType.is(FunctionTypeSyntax.self)
    }
    return false
}

/// Returns the default value string for a parameter, considering the type and initializer.
/// Optionals default to `nil` when no explicit initializer is provided (matching memberwise init).
private func defaultValue(typeAnnotation: TypeSyntax?, initExpr: String?) -> String? {
    if let initExpr { return initExpr }
    // Optional types (T?, Optional<T>) default to nil.
    if let type = typeAnnotation {
        if type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return "nil"
        }
        if let ident = type.as(IdentifierTypeSyntax.self), ident.name.text == "Optional" {
            return "nil"
        }
    }
    return nil
}

enum ModelMacroError: String, Error, CustomStringConvertible {
    case requiresStruct = "Requires type to be struct"
    case requiresStructOrEnum = "Requires type to be either struct or enum"

    var description: String { rawValue }
}

/// `@Model` macro — 16-byte layout with compiler-synthesized memberwise init.
///
/// Every `@Model` struct is exactly 16 bytes (two 8-byte stored properties):
///
/// ```swift
/// private var _$modelAccess: _ModelAccessBox                // 8 bytes
/// private var _$modelSource: _ModelSourceBox<Self>  // 8 bytes
/// ```
///
/// Both are `private` with defaults → they do NOT appear as parameters in the
/// compiler-synthesized memberwise init. Position-aware `@_ModelTracked` init
/// accessors on tracked properties use `initializes:` to set them during init.
/// The synthesized init is always visible to `#Preview`.
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

            // When the real Swift compiler expands a macro, `protocols` contains only the
            // protocols from the macro's `conformances:` list that the type doesn't already
            // satisfy — including conformances declared in separate extensions elsewhere.
            // MacroTesting passes an empty array, so we fall back to checking the struct's
            // own inheritance clause in that case.
            let requestedProtocols = Set(protocols.map { $0.trimmedDescription })

            func isNeeded(_ name: String) -> Bool {
                if !requestedProtocols.isEmpty {
                    return requestedProtocols.contains(name)
                }
                // Fallback for MacroTesting (protocols is empty): check inheritance clause.
                return !(structDecl.inheritanceClause.map {
                    $0.inheritedTypes.contains(where: { $0.type.trimmedDescription.contains(name) })
                } ?? false)
            }

            func addConformance(_ name: String, qualifiedName: String? = nil) {
                if isNeeded(name) {
                    extensions.append(
                    """
                    extension \(raw: type.trimmedDescription): \(raw: qualifiedName ?? name) {}
                    """)
                }
            }

            addConformance("Model", qualifiedName: "SwiftModel.Model")
            addConformance("Sendable", qualifiedName: "@unchecked Sendable")
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

            if isNeeded("CustomReflectable") {
                extensions.append(
                """
                extension \(raw: type.trimmedDescription): \(raw: "CustomReflectable") {
                    public var customMirror: Mirror {
                        node.mirror(of: self, children: [\(raw: mirrorChildren.joined(separator: ", "))])
                    }
                }
                """)
            }

            let needsDescription = isNeeded("CustomStringConvertible")
            let needsDebugDescription = isNeeded("CustomDebugStringConvertible")
            if needsDescription || needsDebugDescription {
                let conformances = [
                    needsDescription ? "CustomStringConvertible" : nil,
                    needsDebugDescription ? "CustomDebugStringConvertible" : nil,
                ].compactMap { $0 }.joined(separator: ", ")
                // Use \n with explicit indentation so the multi-line description body
                // matches what a literal string interpolation would produce.
                let descriptionMember = "public var description: String {\n        node.description(of: self)\n    }"
                let debugDescriptionMember = "public var debugDescription: String { description }"
                let members = [
                    needsDescription ? descriptionMember : nil,
                    needsDebugDescription ? debugDescriptionMember : nil,
                ].compactMap { $0 }.joined(separator: "\n    ")
                extensions.append(
                """
                extension \(raw: type.trimmedDescription): \(raw: conformances) {
                    \(raw: members)
                }
                """)
            }

            return extensions.map { $0.cast(ExtensionDeclSyntax.self) }
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

        // All mutable tracked vars — both defaulted and non-defaulted.
        let trackedMutableVars = declaration.definedVariables.filter {
            $0.isValidForObservation && $0.isValid && !$0.isImmutable
        }

        // visit(with:): let-props → visitStatically(at: \.name) [M-level KeyPath]
        //               var-props → visitStatically(statePath: \.name) [_State-level WritableKeyPath]
        let visits = declaration.definedVariables.filter {
            !$0.isComputed && $0.isInstance && $0.isValid
        }.compactMap { member -> String? in
            guard let identifier = member.identifier else { return nil }
            if member.isImmutable {
                return "visitor.visitStatically(at: \\.\(identifier))"
            } else {
                let visibilityArg = member.isPrivateGetter ? ", visibility: .private" : ""
                return "visitor.visitStatically(statePath: \\.\(identifier)\(visibilityArg))"
            }
        }

        result.append(
        """
        public func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
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

        // _State struct holds ALL tracked mutable properties (NOT Sendable — protected by lock).
        if !trackedMutableVars.isEmpty {
            let stateFields = trackedMutableVars.compactMap { member -> String? in
                guard let identifier = member.identifier,
                      let binding = member.bindings.first else { return nil }
                if let typeExpr = binding.typeAnnotation?.type.trimmedDescription {
                    if let initExpr = binding.initializer?.value.trimmedDescription {
                        return "var \(identifier): \(typeExpr) = \(initExpr)"
                    } else {
                        return "var \(identifier): \(typeExpr)"
                    }
                } else if let initExpr = binding.initializer?.value.trimmedDescription {
                    return "var \(identifier) = \(initExpr)"
                } else {
                    return nil
                }
            }

            // _State is public (required for public _ModelState typealias) but NOT Sendable —
            // protected by the framework's internal lock. Conforms to _ModelStateType to
            // provide synthetic keypath subscripts for modifyCallbacksStore observation.
            result.append(
            """
            public struct _State: _ModelStateType {
                \(raw: stateFields.joined(separator: "\n    "))
            }
            """)

            result.append("public typealias _ModelState = _State")

            // _makeState: builds _State from PendingStorage, providing defaults for properties
            // whose init accessors didn't fire (user-written inits that skip some assignments).
            // Note: _zeroInit() is intentional here — for user-written inits, _$modelSource's
            // default fires in Swift phase-1 init (before the init body) when the pending
            // storage is still empty. _zeroInit() provides a placeholder; the init body then
            // overwrites it via setter → _storePendingIfNeeded. Without _zeroInit(), all
            // user-written inits would fatalError before the body runs.
            let makeStateArgs = trackedMutableVars.compactMap { member -> String? in
                guard let identifier = member.identifier?.text,
                      let binding = member.bindings.first else { return nil }
                if let initExpr = binding.initializer?.value.trimmedDescription {
                    return "\(identifier): pending.value(for: \\.\(identifier), default: \(initExpr))"
                } else {
                    return "\(identifier): pending.value(for: \\.\(identifier), default: _zeroInit())"
                }
            }
            let makeStateBody = makeStateArgs.joined(separator: ", ")
            result.append(
            """
            private static func _makeState(from pending: PendingStorage<_State>) -> _State {
                _State(\(raw: makeStateBody))
            }
            """)

            // _modelState: private computed property used only within this type.
            // Enables \Self._modelState inside _modelStateKeyPath (formed in concrete context).
            // Generic framework code accesses state via the _modelStateKeyPath value, not directly.
            result.append(
            """
            private var _modelState: _State {
                get { _$modelSource._modelState }
                nonmutating set { _$modelSource._modelState = newValue }
            }
            """)

            // _$modelAccess: private with default — not a memberwise init parameter.
            // Overridden by first/only init accessor's `initializes: _$modelAccess`.
            result.append("private var _$modelAccess: _ModelAccessBox = _ModelAccessBox()")

            // _$modelSource: private with default — not a memberwise init parameter.
            // Default `._popFromThreadLocal(Self._makeState)` captures any thread-local entries
            // stored by init accessors, builds _State via the factory, and creates a Reference.
            // In the synthesized init, the last/only init accessor overrides this via
            // `initializes: _$modelSource` (so the default is NOT evaluated). For user-written inits
            // that skip the last tracked property, the default fires AFTER the init body and captures
            // the partially-stored entries.
            result.append("private var _$modelSource: _ModelSourceBox<Self> = ._popFromThreadLocal(Self._makeState)")

            // No explicit init generated — the compiler-synthesized memberwise init is used.
            // Private stored properties (_$modelAccess, _$modelSource, _$privateN) are excluded
            // from the synthesized init parameters. Position-aware init accessors on tracked
            // properties use `initializes:` to set them during the synthesized init body.
            // This init is always visible to `#Preview` (no arm64 emit-module deferral).

            // _modelStateKeyPath: returns \Self._modelState formed in the concrete type's context
            // (direct dispatch), so keypath equality holds when composed generically in Context.
            result.append(
            """
            public static var _modelStateKeyPath: WritableKeyPath<Self, _State> { \\Self._modelState }
            """)
        }

        // Computed _$modelContext: assembles a ModelContext<Self> from the two stored properties.
        // For types with no tracked vars, it falls back to a simple stored context.
        if trackedMutableVars.isEmpty {
            result.append(
            """
            var _$modelContext: ModelContext<Self> = .init()
            """)
        } else {
            result.append(
            """
            private var _$modelContext: ModelContext<Self> {
                get { ModelContext(_access: _$modelAccess, _source: _$modelSource) }
            }
            """)
        }

        result.append(
        """
        public var _context: ModelContextAccess<Self> { ModelContextAccess(_$modelContext) }
        """)

        // _updateContext: sets both stored props from the update token.
        if trackedMutableVars.isEmpty {
            result.append(
            """
            public mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                _$modelContext = update._$modelContext
            }
            """)
        } else {
            result.append(
            """
            public mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                _$modelAccess = update._$modelContext._access
                _$modelSource = update._$modelContext._source
            }
            """)
        }

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
        guard let property = member.as(VariableDeclSyntax.self),
              property.isValidForObservation,
              property.identifier != nil,
              !property.isImmutable,
              !property.hasMacroApplication("_ModelIgnored"),
              !property.hasMacroApplication("ModelDependency") else {
            return []
        }

        // Collect all tracked mutable vars to determine position.
        let trackedMutableVars = declaration.definedVariables.filter {
            $0.isValidForObservation && $0.isValid && !$0.isImmutable
        }
        let count = trackedMutableVars.count
        guard let index = trackedMutableVars.firstIndex(where: {
            $0.identifier?.text == property.identifier?.text
        }) else {
            return []
        }

        return ["@_ModelTracked(\(raw: index), count: \(raw: count))"]
    }
}
