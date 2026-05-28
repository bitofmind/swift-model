import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - Shared helpers

/// Builds the `_read`/`nonmutating _modify` accessor pair (or `nonmutating set` for willSet/didSet).
///
/// Normal properties use `_read` + `nonmutating _modify` for efficient coroutine-based access
/// and proper observation coalescing. Properties with `willSet`/`didSet` use `nonmutating set`.
///
/// Both write paths include a pending-state guard (`_storePendingIfNeeded`) for user-written
/// inits where the setter fires instead of the init accessor.
private func makeGetSet(
    identifier: String,
    didSet: CodeBlockItemListSyntax?,
    willSet: CodeBlockItemListSyntax?
) -> [AccessorDeclSyntax] {
    let readAccessor: AccessorDeclSyntax =
    """
    _read {
        yield _$modelSource[read: \\_State.\(raw: identifier), access: _$modelAccess]
    }
    """

    let writeAccessor: AccessorDeclSyntax
    if didSet != nil || willSet != nil {
        writeAccessor =
        """
        nonmutating set {
            guard !_$modelSource._storePendingIfNeeded(\\.\(raw: identifier), newValue) else { return }
            let oldValue = _$modelSource[read: \\_State.\(raw: identifier), access: _$modelAccess]
            _ = oldValue
            \(willSet?.trimmed ?? "")
            _$modelSource[write: \\_State.\(raw: identifier), access: _$modelAccess] = newValue
            \(didSet?.trimmed ?? "")
        }
        """
    } else {
        writeAccessor =
        """
        nonmutating _modify {
            yield &_$modelSource[write: \\_State.\(raw: identifier), access: _$modelAccess]
        }
        """
    }

    return [readAccessor, writeAccessor]
}

/// Extracts identifier, willSet, didSet from a `VariableDeclSyntax`.
private func extractPropertyInfo(
    _ property: VariableDeclSyntax
) -> (identifier: String, willSet: CodeBlockItemListSyntax?, didSet: CodeBlockItemListSyntax?)? {
    guard property.isValidForObservation, let identifierToken = property.identifier else { return nil }
    let identifier = identifierToken.text
    if property.hasMacroApplication("_ModelIgnored") { return nil }

    var didSet: CodeBlockItemListSyntax?
    var willSet: CodeBlockItemListSyntax?
    for binding in property.bindings {
        guard let accessors = binding.accessorBlock?.accessors.as(AccessorDeclListSyntax.self) else { continue }
        for accessor in accessors {
            if accessor.accessorSpecifier.text == "didSet" { didSet = accessor.body?.statements }
            if accessor.accessorSpecifier.text == "willSet" { willSet = accessor.body?.statements }
        }
    }

    return (identifier, willSet, didSet)
}

/// Extracts the (index, count) arguments from `@_ModelTracked(index, count: count)`.
private func extractPositionArgs(_ node: AttributeSyntax) -> (index: Int, count: Int)? {
    guard let args = node.arguments?.as(LabeledExprListSyntax.self),
          args.count >= 2 else { return nil }
    let argArray = Array(args)
    guard let indexExpr = argArray[0].expression.as(IntegerLiteralExprSyntax.self),
          let countExpr = argArray[1].expression.as(IntegerLiteralExprSyntax.self),
          let index = Int(indexExpr.literal.text),
          let count = Int(countExpr.literal.text) else {
        return nil
    }
    return (index, count)
}

// MARK: - Position roles

private enum PositionRole {
    case only       // count == 1: initializes both _$modelAccess and _$modelSource
    case first      // index == 0: initializes _$modelAccess
    case middle(Int) // 0 < index < count-1: initializes _$privateN (Void peer)
    case last       // index == count-1: initializes _$modelSource

    init(index: Int, count: Int) {
        if count == 1 {
            self = .only
        } else if index == 0 {
            self = .first
        } else if index == count - 1 {
            self = .last
        } else {
            self = .middle(index)
        }
    }
}

// MARK: - Unified tracked macro

/// Accessor macro for `@Model` tracked properties.
///
/// Applied by `@Model`'s `MemberAttributeMacro` as `@_ModelTracked(index, count: count)`.
/// Position-aware init accessors enable the compiler-synthesized memberwise init,
/// which is always visible to `#Preview` (unlike macro-generated explicit inits).
public struct ModelTrackedMacro: AccessorMacro, PeerMacro {

    public static func expansion<C: MacroExpansionContext, D: DeclSyntaxProtocol>(
        of node: AttributeSyntax, providingAccessorsOf declaration: D, in context: C
    ) throws -> [AccessorDeclSyntax] {
        guard let property = declaration.as(VariableDeclSyntax.self),
              let (identifier, willSet, didSet) = extractPropertyInfo(property),
              let (index, count) = extractPositionArgs(node)
        else { return [] }

        let role = PositionRole(index: index, count: count)
        let initAccessor: AccessorDeclSyntax

        switch role {
        case .only:
            initAccessor =
            """
            @storageRestrictions(initializes: _$modelAccess, _$modelSource)
            init(newValue) {
                _$modelAccess = _ModelAccessBox()
                _ModelSourceBox<Self>._threadLocalStoreFirst(\\.\(raw: identifier), newValue)
                _$modelSource = ._popFromThreadLocal(Self._makeState)
            }
            """
        case .first:
            initAccessor =
            """
            @storageRestrictions(initializes: _$modelAccess)
            init(newValue) {
                _$modelAccess = _ModelAccessBox()
                _ModelSourceBox<Self>._threadLocalStoreFirst(\\.\(raw: identifier), newValue)
            }
            """
        case .middle(let idx):
            initAccessor =
            """
            @storageRestrictions(initializes: _$private\(raw: idx))
            init(newValue) {
                _$private\(raw: idx) = ()
                _ModelSourceBox<Self>._threadLocalStoreOrLatest(\\.\(raw: identifier), newValue)
            }
            """
        case .last:
            initAccessor =
            """
            @storageRestrictions(initializes: _$modelSource)
            init(newValue) {
                _$modelSource = _ModelSourceBox<Self>._threadLocalStoreAndPop(\\.\(raw: identifier), newValue, Self._makeState)
            }
            """
        }

        return [initAccessor] + makeGetSet(identifier: identifier, didSet: didSet, willSet: willSet)
    }

    public static func expansion<C: MacroExpansionContext, D: DeclSyntaxProtocol>(
        of node: AttributeSyntax, providingPeersOf declaration: D, in context: C
    ) throws -> [DeclSyntax] {
        guard let property = declaration.as(VariableDeclSyntax.self),
              property.isValidForObservation,
              property.identifier != nil,
              let (index, count) = extractPositionArgs(node)
        else { return [] }

        let role = PositionRole(index: index, count: count)

        // Only middle properties need a Void peer for init-accessor ordering.
        guard case .middle(let idx) = role else { return [] }

        return ["var _$private\(raw: idx): Void"]
    }

}
