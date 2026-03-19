import Foundation
import Dependencies

/// A read token that gives the `SwiftModel` framework access to a model's internal context.
///
/// `ModelContextAccess` can be constructed by macro-generated code (its `init` is `public`),
/// but its stored context (`_$modelContext`) is `internal` — external code cannot read the
/// context back out. This prevents consumers from bypassing the model's lifecycle management.
public struct ModelContextAccess<M: Model>: Sendable {
    /// Public so macro-generated code (in user modules) can construct the access token
    /// from the model's private stored `_$modelContext`.
    public init(_ context: ModelContext<M>) {
        self._$modelContext = context
    }

    /// Internal so only `SwiftModel` framework code can read the underlying context.
    internal let _$modelContext: ModelContext<M>
}

/// A write token that lets the `SwiftModel` framework push a new context into a model.
///
/// `ModelContextUpdate` can only be constructed inside the `SwiftModel` module (its `init` is
/// `internal`), preventing external code from forging an update. Its stored context
/// (`_$modelContext`) is `public` so macro-generated `_updateContext` (in user modules) can
/// read it and write it into the model's private stored property.
public struct ModelContextUpdate<M: Model>: Sendable {
    /// Internal so only `SwiftModel` framework code can forge an update token.
    internal init(_ context: ModelContext<M>) {
        self._$modelContext = context
    }

    /// Public so macro-generated `_updateContext` (in user modules) can read the new context.
    public let _$modelContext: ModelContext<M>
}

public struct ModelContext<M: Model> {
    var source: Source = .reference(.init(modelID: .generate()))
    var _access: ModelAccess.Reference?

    var access: ModelAccess? {
        get { _access?.access ?? ModelAccess.current }
        set {
            _access = newValue?.reference
            reference?.updateAccess(newValue)
        }
    }

    var deepAccess: ModelAccess? {
        access.flatMap {
            $0.shouldPropagateToChildren ? $0 : nil
        }
    }

    var activeAccess: ModelAccess? {
        ModelAccess.active ?? access
    }

    enum Source {
        case reference(Context<M>.Reference)
        case frozenCopy(id: ModelID)
        case lastSeen(id: ModelID)
    }

    public init() {}
}

extension ModelContext: @unchecked Sendable {}

extension ModelContext: Hashable {
    public static func == (lhs: ModelContext<M>, rhs: ModelContext<M>) -> Bool {
        return switch (lhs.source, rhs.source) {
        case let (.reference(lhs), .reference(rhs)): lhs === rhs
        case let (.frozenCopy(lhs), .frozenCopy(rhs)): lhs == rhs
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) { }
}

public extension ModelContext {
    func mirror(of model: M, children: [(String, Any)]) -> Mirror {
        if threadLocals.includeInMirror, !children.map(\.0).contains("id") {
            return Mirror(model, children: [("id", modelID)] + children, displayStyle: .struct)
        } else if threadLocals.includeInMirror || threadLocals.includeChildrenInMirror {
            return Mirror(model, children: children, displayStyle: .struct)
        } else {
            // Return an empty mirror so LLDB doesn't expand properties below debugDescription
            return Mirror(model, children: [], displayStyle: .struct)
        }
    }

    func description(of model: M) -> String {
        // Set includeChildrenInMirror so customDumping gets the full children via customMirror,
        // without prepending the id (which is only needed for test diffing).
        threadLocals.withValue(true, at: \.includeChildrenInMirror) {
            String(customDumping: model)
        }
    }
}

public extension ModelContext {
    @_disfavoredOverload
    subscript<T>(model model: M, path path: WritableKeyPath<M, T>&Sendable) -> T {
        _read {
            yield self[model, path, nil]
        }
        nonmutating _modify {
            yield &self[model, path, nil]
        }
    }

    @_disfavoredOverload
    subscript<T: Equatable>(model model: M, path path: WritableKeyPath<M, T>&Sendable) -> T {
        _read {
            yield self[model, path, nil]
        }
        nonmutating _modify {
            yield &self[model, path, ==]
        }
    }

    @_disfavoredOverload
    subscript<each T: Equatable>(model model: M, path path: WritableKeyPath<M, (repeat each T)>&Sendable) -> (repeat each T) {
        get {
           self[model, path, nil]
        }
        nonmutating _modify {
            yield &self[model, path, isSame]
        }
    }

    subscript<T: Model>(model model: M, path path: WritableKeyPath<M, T>&Sendable) -> T {
        _read {
            yield self[model, path, nil].withAccessIfPropagateToChildren(access)
        }

        nonmutating set {
            guard let context = modifyContext else {
                if let initial {
                    guard newValue.isInitial else {
                        reportIssue("It is not allowed to add an already anchored or frozen model, instead create a new instance.")
                        return
                    }

                    initial[fallback: model][keyPath: path] = newValue
                }

                return
            }

            guard context[path].context !== newValue.context else {
                return
            }

            guard newValue.isInitial || newValue.context != nil else {
                reportIssue("It is not allowed to add a frozen model, instead create a new instance or add an already anchored model.")
                return
            }

            var callbacks: [() -> Void] = []
            transaction(with: model, at: path) { child in
                var newChild = newValue
                if let childContext = context[path].context {
                    context.removeChild(childContext, at: \M.self, callbacks: &callbacks)
                }
                context.updateContext(for: &newChild, at: path)

                child = newChild
            } isSame: {
                $0.modelID == $1.modelID
            }

            for callback in callbacks {
                callback()
            }

            if let access, access.shouldPropagateToChildren {
                usingAccess(access) {
                    _ = context[path].context?.onActivate()
                }
            } else {
                _ = context[path].context?.onActivate()
            }
        }
    }

    subscript<T: ModelContainer>(model model: M, path path: WritableKeyPath<M, T>&Sendable) -> T {
        _read {
            if let deepAccess {
                yield self[model, path, nil].withDeepAccess(deepAccess)
            } else {
                yield self[model, path, nil]
            }
        }
        nonmutating set {
            guard let context = modifyContext else {
                if let initial {
                    guard newValue.isAllInitial else {
                        reportIssue("It is not allowed to add an already anchored or frozen model, instead create a new instance.")
                        return
                    }

                    initial[fallback: model][keyPath: path] = newValue
                }

                return
            }

            var postLockCallbacks: [() -> Void] = []
            transaction(with: model, at: path) { container in
                var newContainer = newValue

                var didReplaceModelWithDestructedOrFrozenCopy = false
                let oldContexts = threadLocals.withValue({
                    didReplaceModelWithDestructedOrFrozenCopy = true
                }, at: \.didReplaceModelWithDestructedOrFrozenCopy) {
                    context.updateContext(for: &newContainer, at: path)
                }

                if didReplaceModelWithDestructedOrFrozenCopy {
                    reportIssue("It is not allowed to add a destructed nor frozen model.")
                    return
                }

                container = newContainer

                for oldContext in oldContexts {
                    context.removeChild(oldContext, at: path, callbacks: &postLockCallbacks)
                }
            } isSame: {
                containerIsSame($0, $1)
            }

            for callback in postLockCallbacks {
                callback()
            }

            if let access, access.shouldPropagateToChildren {
                usingAccess(access) {
                    context[path].activate()
                }
            } else {
                context[path].activate()
            }
        }
    }

    func dependency<D: Model&DependencyKey>() -> D where D.Value == D {
        (_dependency() as D).withAccessIfPropagateToChildren(access)
    }

    @_disfavoredOverload
    func dependency<D: DependencyKey>() -> D where D.Value == D {
        _dependency()
    }
}

private func containerIsSame<T: ModelContainer>(_ lhs: T, _ rhs: T) -> Bool {
    if let leftOptional = lhs as? any _Optional {
        return optionalIsSame(leftOptional, rhs)
    }

    if let leftCollection = lhs as? any Collection {
        return collectionIsSame(leftCollection, rhs)
    }

    return false
}

private func optionalIsSame<T: _Optional>(_ lhs: T, _ rhs: Any) -> Bool {
    let rightOptional = rhs as! T
    switch (lhs.wrappedValue, rightOptional.wrappedValue) {
    case (nil, nil):
        return true

    case (nil, _?), (_?, nil):
        return false
        
    case let (left?, right?):
        return modelIsSame(left, right)
    }
}

private func collectionIsSame<T: Collection>(_ lhs: T, _ rhs: Any) -> Bool {
    let rightCollection = rhs as! T
    if lhs.count != rightCollection.count {
        return false
    }

    return zip(lhs, rightCollection).allSatisfy {
        modelIsSame($0, $1)
    }
}

private func modelIsSame(_ lhs: Any, _ rhs: Any) -> Bool {
    if let l = lhs as? any Model {
        return _modelIsSame(l, rhs)
    } else {
        return false
    }
}

private func _modelIsSame<T: Model>(_ lhs: T, _ rhs: Any) -> Bool {
    let rightOptional = rhs as! T
    return lhs.id == rightOptional.id
}
