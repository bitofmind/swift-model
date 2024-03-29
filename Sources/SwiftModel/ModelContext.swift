import Foundation
import Dependencies

public struct ModelContext<M: Model> {
    var source: Source = .initial(Initial())
    var _access: ModelAccess.Reference?

    var access: ModelAccess? {
        get { _access?.access ?? ModelAccess.current  }
        set { _access = newValue?.reference }
    }

    class Initial: @unchecked Sendable {
        let id: ModelID
        private var _model: M?

        public init(id: ModelID = .generate()) {
            self.id = id
        }

        subscript (fallback fallback: M) -> M {
            _read {
                initialLock.lock()
                yield _model?.withAccess(fallback.access) ?? fallback
                initialLock.unlock()
            }
            _modify {
                initialLock.lock()
                var model = _model?.withAccess(fallback.access) ?? fallback
                yield &model
                _model = model
                initialLock.unlock()
            }
        }
    }

    enum Source {
        case initial(Initial)
        case reference(Context<M>.Reference)
        case frozenCopy(id: ModelID)
        case lastSeen(id: ModelID)
    }

    public init() {}
}

private let initialLock = NSRecursiveLock()

extension ModelContext: Sendable where M: Sendable {}

extension ModelContext: Hashable {
    public static func == (lhs: ModelContext<M>, rhs: ModelContext<M>) -> Bool {
        return switch (lhs.source, rhs.source) {
        case let (.initial(lhs), .initial(rhs)): lhs === rhs
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
    subscript<T>(model model: M, path path: WritableKeyPath<M, T>) -> T {
        _read {
            yield self[model, path]
        }
        nonmutating _modify {
            yield &self[model, path]
        }
    }

    subscript<T: Model>(model model: M, path path: WritableKeyPath<M, T>) -> T {
        _read {
            if let access, access.shouldPropagateToChildren {
                yield self[model, path].withAccess(access)
            } else {
                yield self[model, path]
            }
        }

        nonmutating set {
            guard let context = modifyContext else {
                if case let .initial(initial) = source {
                    guard newValue.isInitial else {
                        XCTFail("It is not allowed to add an already anchored or frozen model, instead create new instance instead.")
                        return
                    }

                    initial[fallback: model][keyPath: path] = newValue
                }

                return
            }

            guard context[path].context !== newValue.context else {
                return
            }

            guard newValue.isInitial else {
                XCTFail("It is not allowed to add an already anchored or frozen model, instead create new instance instead.")
                return
            }

            var callbacks: [() -> Void] = []
            transaction(with: model, at: path) { child in
                var newChild = newValue
                context[path].context?.onRemoval(callbacks: &callbacks)
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

    subscript<T: ModelContainer>(model model: M, path path: WritableKeyPath<M, T>) -> T {
        _read {
            if let access, access.shouldPropagateToChildren {
                yield self[model, path].withDeepAccess(access)
            } else {
                yield self[model, path]
            }
        }
        nonmutating set {
            guard let context = modifyContext else {
                if case let .initial(initial) = source {
                    guard newValue.isAllInitial else {
                        XCTFail("It is not allowed to add an already anchored or frozen model, instead create new instance instead.")
                        return
                    }

                    initial[fallback: model][keyPath: path] = newValue
                }

                return
            }

            var postLockCallbacks: [() -> Void] = []
            transaction(with: model, at: path) { container in
                var newContainer = newValue

                var didReplaceModelWithAnchoredModel = false
                let oldContexts = threadLocals.withValue({
                    didReplaceModelWithAnchoredModel = true
                }, at: \.didReplaceModelWithAnchoredModel) {
                    context.updateContext(for: &newContainer, at: path)
                }

                if didReplaceModelWithAnchoredModel {
                    XCTFail("It is not allowed to add an already anchored model, instead create new unanchored instance.")
                    return
                }

                container = newContainer

                for context in oldContexts {
                    context.onRemoval(callbacks: &postLockCallbacks)
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
}





