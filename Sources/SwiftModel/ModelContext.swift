import Foundation
import Dependencies

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

    enum Source {
        case reference(Context<M>.Reference)
        case frozenCopy(id: ModelID)
        case lastSeen(id: ModelID)
    }

    public init() {}
}

extension ModelContext: Sendable where M: Sendable {}

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
        } else {
            return Mirror(model, children: children, displayStyle: .struct)
        }
    }

    func description(of model: M) -> String {
        String(customDumping: model)
    }
}

public extension ModelContext {
    subscript<T>(model model: M, path path: WritableKeyPath<M, T>&Sendable) -> T {
        _read {
            yield self[model, path]
        }
        nonmutating _modify {
            yield &self[model, path]
        }
    }

    subscript<T: Model>(model model: M, path path: WritableKeyPath<M, T>&Sendable) -> T {
        _read {
            yield self[model, path].withAccessIfPropagateToChildren(access)
        }

        nonmutating set {
            guard let context = modifyContext else {
                if let initial {
                    guard newValue.isInitial else {
                        reportIssue("It is not allowed to add an already anchored or frozen model, instead create new instance instead.")
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
                reportIssue("It is not allowed to add a frozen model, instead create new instance instead or add an already anchored model.")
                return
            }

            var callbacks: [() -> Void] = []
            transaction(with: model, at: path) { child in
                var newChild = newValue
                if let childContext = context[path].context {
                    context.removeChild(childContext, callbacks: &callbacks)
                }
                context.updateContext(for: &newChild, at: path)

                child = newChild
            }

            for callback in callbacks {
                callback()
            }

            if let access, access.shouldPropagateToChildren {
                ModelAccess.$current.withValue(access) {
                    context[path].context?.onActivate()
                }
            } else {
                _ = context[path].context?.onActivate()
            }
        }
    }

    subscript<T: ModelContainer>(model model: M, path path: WritableKeyPath<M, T>&Sendable) -> T {
        _read {
            if let access, access.shouldPropagateToChildren {
                yield self[model, path].withDeepAccess(access)
            } else {
                yield self[model, path]
            }
        }
        nonmutating set {
            guard let context = modifyContext else {
                if let initial {
                    guard newValue.isAllInitial else {
                        reportIssue("It is not allowed to add an already anchored or frozen model, instead create new instance instead.")
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
                    context.removeChild(oldContext, callbacks: &postLockCallbacks)
                }
            }

            for callback in postLockCallbacks {
                callback()
            }

            if let access, access.shouldPropagateToChildren {
                ModelAccess.$current.withValue(access) {
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

